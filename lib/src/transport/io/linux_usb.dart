// Linux: USB printers through the kernel's own printer driver, usblp, which
// creates /dev/usb/lp0, lp1, ... for every USB printer-class device. No
// printer driver to install; the user only needs write access to the device
// (the `lp` group, or a udev rule).
//
// The device is opened non-blocking and written with poll() in a background
// isolate. A blocking write to a printer that is out of paper or switched off
// waits forever and cannot be cancelled from Dart; non-blocking writes give a
// clean timeout, and closing the device then cancels what is still queued.

import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../../enums.dart';
import '../../models/usb_printer.dart';
import '../../models/usb_printer_note.dart';
import '../../models/usb_write_options.dart';
import '../../utils/printer_identity.dart';
import '../printer_transport.dart';

// Linux values, the same on x86-64 and arm64.
const _oWronly = 0x1;
const _oNonblock = 0x800;
const _oCloexec = 0x80000;
const _wOk = 2;
const _pollOut = 0x4;
const _pollErr = 0x8;
const _pollHup = 0x10;
const _eintr = 4;
const _eagain = 11;

final class _PollFd extends Struct {
  @Int32()
  external int fd;
  @Int16()
  external int events;
  @Int16()
  external int revents;
}

/// The libc functions used here. One per isolate.
class _Libc {
  _Libc() : _lib = DynamicLibrary.process();

  final DynamicLibrary _lib;

  late final open = _lib
      .lookupFunction<Int32 Function(Pointer<Utf8>, Int32), int Function(Pointer<Utf8>, int)>(
        'open',
      );
  late final write = _lib
      .lookupFunction<
        IntPtr Function(Int32, Pointer<Void>, IntPtr),
        int Function(int, Pointer<Void>, int)
      >('write');
  late final poll = _lib
      .lookupFunction<
        Int32 Function(Pointer<_PollFd>, Uint64, Int32),
        int Function(Pointer<_PollFd>, int, int)
      >('poll');
  late final close = _lib.lookupFunction<Int32 Function(Int32), int Function(int)>('close');
  late final access = _lib
      .lookupFunction<Int32 Function(Pointer<Utf8>, Int32), int Function(Pointer<Utf8>, int)>(
        'access',
      );
  late final _errnoLocation = _lib
      .lookupFunction<Pointer<Int32> Function(), Pointer<Int32> Function()>('__errno_location');

  int get errno => _errnoLocation().value;
}

/// The package's code for an errno.
String linuxErrorCode(int errno) => switch (errno) {
  13 || 1 => 'permissionDenied', // EACCES, EPERM
  2 || 19 || 6 => 'notFound', // ENOENT, ENODEV, ENXIO
  16 => 'busy', // EBUSY
  _ => 'ioError',
};

UsbPlatformError _errnoError(int errno, String what) {
  final code = linuxErrorCode(errno);
  final message = switch (code) {
    'permissionDenied' =>
      '$what: Linux did not allow access to the USB printer. $linuxPermissionHint',
    'busy' => '$what: another program is using the printer (for example the system print queue)',
    'notFound' => '$what: the printer is not connected',
    _ => what,
  };
  return UsbPlatformError(code, message, detail: 'errno $errno');
}

/// How to give the user write access to USB printers.
const linuxPermissionHint =
    'Add yourself to the "lp" group with "sudo usermod -aG lp \$USER", then log out and back in.';

// ─── Listing ─────────────────────────────────────────────────────────────────

/// Lists `/dev/usb/lp*` with ids from sysfs. [devRoot] and [sysRoot] are for
/// tests; [canWrite] tells whether this process may write to a device.
class LinuxUsbLister {
  LinuxUsbLister({
    this.devRoot = '/dev/usb',
    this.sysRoot = '/sys',
    bool Function(String path)? canWrite,
  }) : _canWrite = canWrite ?? _accessWritable;

  final String devRoot;
  final String sysRoot;
  final bool Function(String path) _canWrite;

  /// The printers, with the device path of each by id.
  ({List<UsbPrinter> printers, Map<String, String> paths, List<UsbPrinterNote> notes}) list() {
    final names = <String>[];
    try {
      for (final entry in Directory(devRoot).listSync(followLinks: false)) {
        final name = entry.uri.pathSegments.lastWhere((s) => s.isNotEmpty);
        if (RegExp(r'^lp\d+$').hasMatch(name)) names.add(name);
      }
    } on FileSystemException {
      // No /dev/usb: no USB printers (or usblp is not loaded).
    }
    names.sort((a, b) => int.parse(a.substring(2)).compareTo(int.parse(b.substring(2))));

    final printers = <UsbPrinter>[];
    final paths = <String, String>{};
    for (final n in names) {
      final devPath = '$devRoot/$n';
      String? ifaceDir;
      try {
        ifaceDir = Directory('$sysRoot/class/usbmisc/$n/device').resolveSymbolicLinksSync();
      } on FileSystemException {
        ifaceDir = null;
      }
      // ifaceDir is the USB interface (…/1-2:1.0); its parent is the device (…/1-2).
      final devDir = ifaceDir == null ? null : Directory(ifaceDir).parent.path;
      final info = Ieee1284Id.parse(ifaceDir == null ? null : _read(ifaceDir, 'ieee1284_id'));
      final vendorId = _hex(devDir == null ? null : _read(devDir, 'idVendor'));
      final productId = _hex(devDir == null ? null : _read(devDir, 'idProduct'));
      final serial = (devDir == null ? null : _read(devDir, 'serial')) ?? info.serialNumber;
      final product = devDir == null ? null : _read(devDir, 'product');
      final port = devDir?.split('/').last; // "1-2.3": the physical port path
      final hasIds = vendorId != null && productId != null;
      // Named by serial number or physical port, never by lpN, which changes on replug.
      final id = hasIds
          ? 'linux-usb:${hex4(vendorId)}:${hex4(productId)}:${serial != null ? 'sn=$serial' : 'port=${port ?? n}'}'
          : 'linux-usb:$n';
      paths[id] = devPath;
      printers.add(
        UsbPrinter(
          id: id,
          name: usbDisplayName(info, product, vendorId, productId),
          manufacturer:
              info.manufacturer ?? (devDir == null ? null : _read(devDir, 'manufacturer')),
          model: info.model ?? product,
          vendorId: vendorId,
          productId: productId,
          serialNumber: serial,
          commandSet: info.commandSet,
          port: port,
          isAccessible: _canWrite(devPath),
        ),
      );
    }

    final notes = <UsbPrinterNote>[
      if (printers.any((p) => !p.isAccessible))
        const UsbPrinterNote(
          code: 'permissionDenied',
          message: 'Linux does not let this app use the USB printer. $linuxPermissionHint',
        ),
      if (printers.isEmpty && _hasUnboundPrinter())
        const UsbPrinterNote(
          code: 'usblpMissing',
          message:
              'A USB printer is connected, but Linux has not created /dev/usb/lp0 for it. '
              'Load the USB printer driver with "sudo modprobe usblp", then list again.',
        ),
    ];
    return (printers: classifyPrinters(printers), paths: paths, notes: notes);
  }

  /// A printer-class (07) USB interface with no lp device means usblp is not
  /// loaded (or is blacklisted). Worth saying, as the fix is one command.
  bool _hasUnboundPrinter() {
    try {
      return Directory('$sysRoot/bus/usb/devices')
          .listSync()
          .where((e) => e.path.split('/').last.contains(':'))
          .any((e) => _read(e.path, 'bInterfaceClass') == '07');
    } on FileSystemException {
      return false;
    }
  }

  static String? _read(String dir, String file) {
    try {
      final v = File('$dir/$file').readAsStringSync().replaceAll('\u0000', '').trim();
      return v.isEmpty ? null : v;
    } on FileSystemException {
      return null;
    }
  }

  static int? _hex(String? s) => s == null ? null : int.tryParse(s, radix: 16);

  static bool _accessWritable(String path) {
    final c = path.toNativeUtf8();
    try {
      return _Libc().access(c, _wOk) == 0;
    } finally {
      malloc.free(c);
    }
  }
}

// ─── Writing ─────────────────────────────────────────────────────────────────

/// Opens [path] for non-blocking writes. Returns the fd, or throws.
int _openDevice(String path) {
  final libc = _Libc();
  final c = path.toNativeUtf8();
  try {
    final fd = libc.open(c, _oWronly | _oNonblock | _oCloexec);
    if (fd < 0) throw _errnoError(libc.errno, 'Could not open the USB printer');
    return fd;
  } finally {
    malloc.free(c);
  }
}

/// Writes [data] to [fd], waiting with poll() whenever the printer is not
/// ready. Returns 0, -1 when the printer stalled for [stallMs], or an errno.
///
/// usblp takes up to 8 KB per write and returns at once on a non-blocking fd;
/// the next write fails with EAGAIN until the printer has taken the previous
/// one. Closing the device cancels a transfer still in flight, so the last
/// one is waited for too.
int _writeAll(int fd, Uint8List data, int chunkSize, int stallMs) {
  final libc = _Libc();
  final buffer = malloc<Uint8>(chunkSize);
  final pfd = calloc<_PollFd>();
  try {
    pfd.ref
      ..fd = fd
      ..events = _pollOut;

    // 0 when the printer has room, -1 when it stalled, otherwise an errno.
    int waitWritable() {
      final deadline = DateTime.now().add(Duration(milliseconds: stallMs));
      while (true) {
        final left = deadline.difference(DateTime.now()).inMilliseconds;
        if (left <= 0) return -1;
        pfd.ref.revents = 0;
        final r = libc.poll(pfd, 1, math.min(left, 1000));
        if (r < 0) {
          final e = libc.errno;
          if (e == _eintr) continue;
          return e;
        }
        if (r == 0) continue;
        if (pfd.ref.revents & _pollHup != 0) return 19; // ENODEV: unplugged
        if (pfd.ref.revents & (_pollOut | _pollErr) != 0) return 0;
      }
    }

    var offset = 0;
    while (offset < data.length) {
      final n = math.min(chunkSize, data.length - offset);
      buffer.asTypedList(n).setRange(0, n, data, offset);
      final written = libc.write(fd, buffer.cast(), n);
      if (written > 0) {
        offset += written;
        continue;
      }
      final e = written < 0 ? libc.errno : _eagain;
      if (e == _eintr) continue;
      if (e != _eagain) return e;
      final ready = waitWritable();
      if (ready != 0) return ready;
    }
    // The last transfer is still in flight: wait for it before closing.
    return waitWritable();
  } finally {
    malloc.free(buffer);
    calloc.free(pfd);
  }
}

/// Linux app, straight to `/dev/usb/lp*`.
class LinuxUsbTransport implements PrinterTransport {
  LinuxUsbTransport(this._printer, this._options, {LinuxUsbLister? lister})
    : _lister = lister ?? LinuxUsbLister();

  UsbPrinter _printer;
  final UsbWriteOptions _options;
  final LinuxUsbLister _lister;
  int? _fd;

  @override
  UsbPrinter get printer => _printer;

  @override
  bool get isConnected => _fd != null;

  @override
  Future<void> connect(Duration timeout) async {
    if (_fd != null) return;
    // Listed again on every connect: lpN numbers change when printers are
    // plugged in or out, and the printer may be on another port now.
    final listing = _lister.list();
    final match = _printer.findIn(listing.printers);
    if (match == null) {
      throw const PrinterTransportException(
        PosPrintResult.printerNotFound,
        UsbPlatformError('notFound', 'The USB printer is not connected'),
      );
    }
    try {
      _fd = _openDevice(listing.paths[match.id]!);
    } on UsbPlatformError catch (e) {
      throw PrinterTransportException(resultForCode(e.code, connecting: true), e);
    }
    if (match.id != _printer.id) _printer = _printer.copyWith(id: match.id);
  }

  @override
  Future<void> write(Uint8List data) async {
    final fd = _fd;
    if (fd == null) throw const PrinterTransportException(PosPrintResult.printerNotConnected);
    final chunk = _options.chunkSize;
    final stall = _options.stallTimeout.inMilliseconds;
    final result = await Isolate.run(() => _writeAll(fd, data, chunk, stall));
    if (result == 0) return;
    if (result == -1) {
      throw const PrinterTransportException(
        PosPrintResult.timeout,
        UsbPlatformError(
          'timeout',
          'The printer did not take the data in time. Check that it has paper, '
              'the cover is closed and it is online.',
        ),
      );
    }
    final error = _errnoError(result, 'The printer did not take the data');
    throw PrinterTransportException(resultForCode(error.code), error);
  }

  @override
  Future<void> disconnect() async {
    final fd = _fd;
    _fd = null;
    if (fd != null) _Libc().close(fd);
  }
}
