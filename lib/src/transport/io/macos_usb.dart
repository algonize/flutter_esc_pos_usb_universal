// macOS: USB printers straight through IOKit, from Dart.
//
// macOS has no driver for USB printer-class interfaces (printing is done by
// the CUPS `usb` backend in user space, only while a job runs), so an app can
// open the printer's interface itself and write to its bulk OUT endpoint. No
// printer driver, nothing to add in System Settings.
//
// This uses IOKit's C plugin interface (IOUSBLib, `IOUSBInterfaceInterface182`)
// through dart:ffi, the same interface the CUPS backend uses. The vtable slots
// and struct layouts below were read from the macOS SDK headers with
// `offsetof`, not written by hand.
//
// Sandboxed apps need the `com.apple.security.device.usb` entitlement.

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

/// A COM-style IOKit object: a pointer to a pointer to its vtable.
typedef _ComObject = Pointer<Pointer<Pointer<Void>>>;

final class _CFUUIDBytes extends Struct {
  @Array(16)
  external Array<Uint8> bytes;
}

/// `IOUSBDevRequestTO`: 32 bytes, pData at offset 8.
final class _DevRequestTO extends Struct {
  @Uint8()
  external int bmRequestType;
  @Uint8()
  external int bRequest;
  @Uint16()
  external int wValue;
  @Uint16()
  external int wIndex;
  @Uint16()
  external int wLength;
  external Pointer<Void> pData;
  @Uint32()
  external int wLenDone;
  @Uint32()
  external int noDataTimeout;
  @Uint32()
  external int completionTimeout;
}

// Slots in the IOCFPlugInInterface and IOUSBInterfaceInterface182 vtables.
const _slotQueryInterface = 1;
const _slotRelease = 3;
const _slotOpen = 8;
const _slotClose = 9;
const _slotGetInterfaceNumber = 17;
const _slotGetAlternateSetting = 18;
const _slotGetNumEndpoints = 19;
const _slotGetPipeProperties = 26;
const _slotControlRequestTO = 37;
const _slotWritePipeTO = 40;

// 2D9786C6-9EF3-11D4-AD51-000A27052861
const _interfaceUserClientTypeId = [
  0x2D,
  0x97,
  0x86,
  0xC6,
  0x9E,
  0xF3,
  0x11,
  0xD4,
  0xAD,
  0x51,
  0x00,
  0x0A,
  0x27,
  0x05,
  0x28,
  0x61,
];
// C244E858-109C-11D4-91D4-0050E4C6426F
const _cfPlugInInterfaceId = [
  0xC2,
  0x44,
  0xE8,
  0x58,
  0x10,
  0x9C,
  0x11,
  0xD4,
  0x91,
  0xD4,
  0x00,
  0x50,
  0xE4,
  0xC6,
  0x42,
  0x6F,
];
// 4923AC4C-4896-11D5-9208-000A27801E86
const _interfaceInterfaceId182 = [
  0x49,
  0x23,
  0xAC,
  0x4C,
  0x48,
  0x96,
  0x11,
  0xD5,
  0x92,
  0x08,
  0x00,
  0x0A,
  0x27,
  0x80,
  0x1E,
  0x86,
];

const _kCFStringEncodingUTF8 = 0x08000100;
const _kCFNumberSInt64Type = 4;
const _kUSBOut = 0;
const _kUSBBulk = 2;
const _printerClass = 7;

/// The IOKit and CoreFoundation functions used here. One per isolate.
class _IOKit {
  _IOKit()
    : _iokit = DynamicLibrary.open('/System/Library/Frameworks/IOKit.framework/IOKit'),
      _cf = DynamicLibrary.open(
        '/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation',
      );

  final DynamicLibrary _iokit;
  final DynamicLibrary _cf;

  late final serviceMatching = _iokit
      .lookupFunction<Pointer<Void> Function(Pointer<Utf8>), Pointer<Void> Function(Pointer<Utf8>)>(
        'IOServiceMatching',
      );
  late final getMatchingServices = _iokit
      .lookupFunction<
        Int32 Function(Uint32, Pointer<Void>, Pointer<Uint32>),
        int Function(int, Pointer<Void>, Pointer<Uint32>)
      >('IOServiceGetMatchingServices');
  late final iteratorNext = _iokit.lookupFunction<Uint32 Function(Uint32), int Function(int)>(
    'IOIteratorNext',
  );
  late final objectRelease = _iokit.lookupFunction<Int32 Function(Uint32), int Function(int)>(
    'IOObjectRelease',
  );
  late final createCFProperty = _iokit
      .lookupFunction<
        Pointer<Void> Function(Uint32, Pointer<Void>, Pointer<Void>, Uint32),
        Pointer<Void> Function(int, Pointer<Void>, Pointer<Void>, int)
      >('IORegistryEntryCreateCFProperty');
  late final getRegistryEntryId = _iokit
      .lookupFunction<Int32 Function(Uint32, Pointer<Uint64>), int Function(int, Pointer<Uint64>)>(
        'IORegistryEntryGetRegistryEntryID',
      );
  late final createPlugIn = _iokit
      .lookupFunction<
        Int32 Function(Uint32, Pointer<Void>, Pointer<Void>, Pointer<_ComObject>, Pointer<Int32>),
        int Function(int, Pointer<Void>, Pointer<Void>, Pointer<_ComObject>, Pointer<Int32>)
      >('IOCreatePlugInInterfaceForService');

  late final _uuidCreate = _cf
      .lookupFunction<
        Pointer<Void> Function(Pointer<Void>, _CFUUIDBytes),
        Pointer<Void> Function(Pointer<Void>, _CFUUIDBytes)
      >('CFUUIDCreateFromUUIDBytes');
  late final _stringCreate = _cf
      .lookupFunction<
        Pointer<Void> Function(Pointer<Void>, Pointer<Utf8>, Uint32),
        Pointer<Void> Function(Pointer<Void>, Pointer<Utf8>, int)
      >('CFStringCreateWithCString');
  late final release = _cf
      .lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>('CFRelease');
  late final _getTypeId = _cf
      .lookupFunction<UnsignedLong Function(Pointer<Void>), int Function(Pointer<Void>)>(
        'CFGetTypeID',
      );
  late final _numberTypeId = _cf.lookupFunction<UnsignedLong Function(), int Function()>(
    'CFNumberGetTypeID',
  )();
  late final _stringTypeId = _cf.lookupFunction<UnsignedLong Function(), int Function()>(
    'CFStringGetTypeID',
  )();
  late final _numberGetValue = _cf
      .lookupFunction<
        Uint8 Function(Pointer<Void>, Long, Pointer<Void>),
        int Function(Pointer<Void>, int, Pointer<Void>)
      >('CFNumberGetValue');
  late final _stringGetCString = _cf
      .lookupFunction<
        Uint8 Function(Pointer<Void>, Pointer<Utf8>, Long, Uint32),
        int Function(Pointer<Void>, Pointer<Utf8>, int, int)
      >('CFStringGetCString');

  /// A CFUUID for [bytes]. Release it with [release].
  Pointer<Void> uuid(List<int> bytes) {
    final b = calloc<_CFUUIDBytes>();
    try {
      for (var i = 0; i < 16; i++) {
        b.ref.bytes[i] = bytes[i];
      }
      return _uuidCreate(nullptr, b.ref);
    } finally {
      calloc.free(b);
    }
  }

  /// A CFString for [s]. Release it with [release].
  Pointer<Void> string(String s) {
    final c = s.toNativeUtf8();
    try {
      return _stringCreate(nullptr, c, _kCFStringEncodingUTF8);
    } finally {
      malloc.free(c);
    }
  }

  /// A registry property of [entry] as an int or a String, or null.
  Object? property(int entry, Pointer<Void> key) {
    final ref = createCFProperty(entry, key, nullptr, 0);
    if (ref == nullptr) return null;
    try {
      final type = _getTypeId(ref);
      if (type == _numberTypeId) {
        final out = calloc<Int64>();
        try {
          return _numberGetValue(ref, _kCFNumberSInt64Type, out.cast()) != 0 ? out.value : null;
        } finally {
          calloc.free(out);
        }
      }
      if (type == _stringTypeId) {
        final buffer = calloc<Uint8>(1024);
        try {
          if (_stringGetCString(ref, buffer.cast(), 1024, _kCFStringEncodingUTF8) == 0) return null;
          return buffer.cast<Utf8>().toDartString().trim();
        } finally {
          calloc.free(buffer);
        }
      }
      return null;
    } finally {
      release(ref);
    }
  }
}

// ─── Vtable calls ────────────────────────────────────────────────────────────

Pointer<NativeFunction<T>> _slot<T extends Function>(_ComObject o, int slot) =>
    o.value[slot].cast<NativeFunction<T>>();

int _call0(_ComObject o, int slot) => _slot<Int32 Function(Pointer<Void>)>(
  o,
  slot,
).asFunction<int Function(Pointer<Void>)>()(o.cast());

int _callU8Out(_ComObject o, int slot, Pointer<Uint8> out) =>
    _slot<Int32 Function(Pointer<Void>, Pointer<Uint8>)>(
      o,
      slot,
    ).asFunction<int Function(Pointer<Void>, Pointer<Uint8>)>()(o.cast(), out);

void _releaseObject(_ComObject o) => _slot<Uint32 Function(Pointer<Void>)>(
  o,
  _slotRelease,
).asFunction<int Function(Pointer<Void>)>()(o.cast());

int _queryInterface(_ComObject o, _CFUUIDBytes iid, Pointer<Pointer<Void>> out) =>
    _slot<Int32 Function(Pointer<Void>, _CFUUIDBytes, Pointer<Pointer<Void>>)>(
      o,
      _slotQueryInterface,
    ).asFunction<int Function(Pointer<Void>, _CFUUIDBytes, Pointer<Pointer<Void>>)>()(
      o.cast(),
      iid,
      out,
    );

int _getPipeProperties(
  _ComObject o,
  int pipeRef,
  Pointer<Uint8> direction,
  Pointer<Uint8> number,
  Pointer<Uint8> transferType,
  Pointer<Uint16> maxPacketSize,
  Pointer<Uint8> interval,
) =>
    _slot<
          Int32 Function(
            Pointer<Void>,
            Uint8,
            Pointer<Uint8>,
            Pointer<Uint8>,
            Pointer<Uint8>,
            Pointer<Uint16>,
            Pointer<Uint8>,
          )
        >(o, _slotGetPipeProperties)
        .asFunction<
          int Function(
            Pointer<Void>,
            int,
            Pointer<Uint8>,
            Pointer<Uint8>,
            Pointer<Uint8>,
            Pointer<Uint16>,
            Pointer<Uint8>,
          )
        >()(o.cast(), pipeRef, direction, number, transferType, maxPacketSize, interval);

int _controlRequestTO(_ComObject o, Pointer<_DevRequestTO> request) =>
    _slot<Int32 Function(Pointer<Void>, Uint8, Pointer<_DevRequestTO>)>(
      o,
      _slotControlRequestTO,
    ).asFunction<int Function(Pointer<Void>, int, Pointer<_DevRequestTO>)>()(o.cast(), 0, request);

int _writePipeTO(
  _ComObject o,
  int pipeRef,
  Pointer<Uint8> buffer,
  int size,
  int noDataTimeoutMs,
  int completionTimeoutMs,
) =>
    _slot<Int32 Function(Pointer<Void>, Uint8, Pointer<Void>, Uint32, Uint32, Uint32)>(
      o,
      _slotWritePipeTO,
    ).asFunction<int Function(Pointer<Void>, int, Pointer<Void>, int, int, int)>()(
      o.cast(),
      pipeRef,
      buffer.cast(),
      size,
      noDataTimeoutMs,
      completionTimeoutMs,
    );

// ─── Errors ──────────────────────────────────────────────────────────────────

/// The package's code for an IOReturn.
String macErrorCode(int ioReturn) => switch (ioReturn & 0xffffffff) {
  0xe00002c5 || 0xe00002d5 => 'busy', // exclusive access, busy
  0xe00002e2 || 0xe00002c1 => 'permissionDenied', // not permitted, not privileged
  0xe00002c0 ||
  0xe00002d9 ||
  0xe00002ed ||
  0xe00002d7 ||
  0xe00002d8 => 'notFound', // no device, not attached, not responding, offline, not ready
  0xe00002d6 || 0xe0004051 => 'timeout',
  _ => 'ioError',
};

UsbPlatformError _ioError(int ioReturn, String what) {
  final code = macErrorCode(ioReturn);
  final hex = '0x${(ioReturn & 0xffffffff).toRadixString(16)}';
  final message = switch (code) {
    'permissionDenied' =>
      '$what: macOS did not allow USB access. Sandboxed apps need the '
          'com.apple.security.device.usb entitlement',
    'busy' => '$what: another program is using the printer',
    _ => what,
  };
  return UsbPlatformError(code, message, detail: 'IOReturn $hex');
}

// ─── Listing ─────────────────────────────────────────────────────────────────

/// One printer-class USB interface in the IORegistry.
class _MacInterface {
  _MacInterface({
    required this.service,
    required this.entryId,
    required this.vendorId,
    required this.productId,
    required this.interfaceNumber,
    this.product,
    this.vendor,
    this.serial,
    this.location,
  });

  final int service;
  final int entryId;
  final int? vendorId;
  final int? productId;
  final int interfaceNumber;
  final String? product;
  final String? vendor;
  final String? serial;
  final int? location;

  /// Named by serial number when there is one, so the id survives a move to
  /// another port; otherwise by port (locationID).
  String get id {
    final ids = '${hex4(vendorId ?? 0)}:${hex4(productId ?? 0)}';
    final where = serial != null && serial!.isNotEmpty
        ? 'sn=$serial'
        : 'loc=${(location ?? 0).toRadixString(16).padLeft(8, '0')}';
    final iface = interfaceNumber == 0 ? '' : '#$interfaceNumber';
    return 'mac-usb:$ids:$where$iface';
  }
}

/// The printer-class USB interfaces now connected. Release each [service].
List<_MacInterface> _interfaces(_IOKit k) {
  final keys = {
    for (final key in [
      'bInterfaceClass',
      'bInterfaceNumber',
      'idVendor',
      'idProduct',
      'USB Product Name',
      'USB Vendor Name',
      'USB Serial Number',
      'kUSBSerialNumberString',
      'locationID',
    ])
      key: k.string(key),
  };
  final iterator = calloc<Uint32>();
  final entryId = calloc<Uint64>();
  final found = <_MacInterface>[];
  try {
    final name = 'IOUSBHostInterface'.toNativeUtf8();
    // The matching dictionary is consumed by the call.
    final matching = k.serviceMatching(name);
    malloc.free(name);
    if (matching == nullptr) return found;
    final kr = k.getMatchingServices(0, matching, iterator);
    if (kr != 0) throw _ioError(kr, 'Could not list USB devices');
    for (
      var service = k.iteratorNext(iterator.value);
      service != 0;
      service = k.iteratorNext(iterator.value)
    ) {
      Object? prop(String key) => k.property(service, keys[key]!);
      if (prop('bInterfaceClass') != _printerClass) {
        k.objectRelease(service);
        continue;
      }
      k.getRegistryEntryId(service, entryId);
      final serial = (prop('USB Serial Number') ?? prop('kUSBSerialNumberString')) as String?;
      found.add(
        _MacInterface(
          service: service,
          entryId: entryId.value,
          vendorId: prop('idVendor') as int?,
          productId: prop('idProduct') as int?,
          interfaceNumber: prop('bInterfaceNumber') as int? ?? 0,
          product: prop('USB Product Name') as String?,
          vendor: prop('USB Vendor Name') as String?,
          serial: serial == null || serial.isEmpty ? null : serial,
          location: prop('locationID') as int?,
        ),
      );
    }
    k.objectRelease(iterator.value);
  } finally {
    for (final key in keys.values) {
      k.release(key);
    }
    calloc.free(iterator);
    calloc.free(entryId);
  }
  return found;
}

/// Lists the connected USB printers. [known1284] holds the IEEE 1284 ids read
/// before, by registry entry id, and [inUse] the entries this app holds open:
/// those are not opened again (macOS would refuse, as the open is exclusive).
Future<({List<UsbPrinter> printers, Map<int, String?> ids, List<UsbPrinterNote> notes})>
listMacUsbPrinters({Map<int, String?> known1284 = const {}, Set<int> inUse = const {}}) {
  return Isolate.run(() => _listSync(known1284, inUse));
}

({List<UsbPrinter> printers, Map<int, String?> ids, List<UsbPrinterNote> notes}) _listSync(
  Map<int, String?> known1284,
  Set<int> inUse,
) {
  final k = _IOKit();
  final printers = <UsbPrinter>[];
  final ids = <int, String?>{};
  var denied = false;
  for (final i in _interfaces(k)) {
    var busy = false;
    String? ieee1284 = known1284[i.entryId];
    if (!known1284.containsKey(i.entryId) && !inUse.contains(i.entryId)) {
      try {
        final intf = _openInterface(k, i.service);
        try {
          ieee1284 = _read1284(intf);
          // Only kept once read: a printer that refused this time is asked again.
          ids[i.entryId] = ieee1284;
        } finally {
          _closeInterface(intf);
        }
      } on UsbPlatformError catch (e) {
        busy = e.code == 'busy';
        denied = denied || e.code == 'permissionDenied';
      }
    } else {
      ids[i.entryId] = ieee1284;
    }
    k.objectRelease(i.service);
    final info = Ieee1284Id.parse(ieee1284);
    printers.add(
      UsbPrinter(
        id: i.id,
        name: usbDisplayName(info, i.product, i.vendorId, i.productId),
        manufacturer: info.manufacturer ?? i.vendor,
        model: info.model ?? i.product,
        vendorId: i.vendorId,
        productId: i.productId,
        serialNumber: i.serial ?? info.serialNumber,
        commandSet: info.commandSet,
        port: i.location?.toRadixString(16).padLeft(8, '0'),
        isBusy: busy,
      ),
    );
  }
  return (
    printers: classifyPrinters(printers),
    ids: ids,
    notes: [
      if (denied) const UsbPrinterNote(code: 'permissionDenied', message: macEntitlementMessage),
    ],
  );
}

/// Why a sandboxed app can't open USB printers.
const macEntitlementMessage =
    'macOS did not let this app use USB printers. Sandboxed apps need the '
    '"com.apple.security.device.usb" entitlement in macos/Runner/DebugProfile.entitlements '
    'and Release.entitlements.';

/// Whether this app runs in the App Sandbox.
bool get _sandboxed => Platform.environment.containsKey('APP_SANDBOX_CONTAINER_ID');

// ─── Opening and writing ─────────────────────────────────────────────────────

/// Opens the interface of [service] for exclusive use.
_ComObject _openInterface(_IOKit k, int service) {
  final plugin = calloc<_ComObject>();
  final score = calloc<Int32>();
  final out = calloc<Pointer<Void>>();
  final iid = calloc<_CFUUIDBytes>();
  final userClientType = k.uuid(_interfaceUserClientTypeId);
  final plugInInterface = k.uuid(_cfPlugInInterfaceId);
  try {
    final kr = k.createPlugIn(service, userClientType, plugInInterface, plugin, score);
    if (kr != 0 || plugin.value == nullptr) {
      final error = _ioError(kr, 'Could not reach the USB printer');
      // The sandbox refuses the USB user client without the entitlement, with
      // kIOReturnNoResources rather than a permission error.
      if (_sandboxed && error.code == 'ioError') {
        throw UsbPlatformError('permissionDenied', macEntitlementMessage, detail: error.detail);
      }
      throw error;
    }
    final p = plugin.value;
    for (var i = 0; i < 16; i++) {
      iid.ref.bytes[i] = _interfaceInterfaceId182[i];
    }
    final hr = _queryInterface(p, iid.ref, out);
    _releaseObject(p);
    if (hr != 0 || out.value == nullptr) {
      throw const UsbPlatformError('ioError', 'macOS has no USB interface access for this printer');
    }
    final intf = out.value.cast<Pointer<Pointer<Void>>>();
    final opened = _call0(intf, _slotOpen);
    if (opened != 0) {
      _releaseObject(intf);
      throw _ioError(opened, 'Could not open the USB printer');
    }
    return intf;
  } finally {
    k.release(userClientType);
    k.release(plugInInterface);
    calloc.free(plugin);
    calloc.free(score);
    calloc.free(out);
    calloc.free(iid);
  }
}

void _closeInterface(_ComObject intf) {
  _call0(intf, _slotClose);
  _releaseObject(intf);
}

/// The pipe of the interface's bulk OUT endpoint, or 0 when it has none.
int _bulkOutPipe(_ComObject intf) {
  final count = calloc<Uint8>();
  final direction = calloc<Uint8>();
  final number = calloc<Uint8>();
  final type = calloc<Uint8>();
  final maxPacket = calloc<Uint16>();
  final interval = calloc<Uint8>();
  try {
    if (_callU8Out(intf, _slotGetNumEndpoints, count) != 0) return 0;
    for (var pipe = 1; pipe <= count.value; pipe++) {
      final kr = _getPipeProperties(intf, pipe, direction, number, type, maxPacket, interval);
      if (kr == 0 && direction.value == _kUSBOut && type.value == _kUSBBulk) return pipe;
    }
    return 0;
  } finally {
    for (final p in [count, direction, number, type, interval]) {
      calloc.free(p);
    }
    calloc.free(maxPacket);
  }
}

/// The printer's IEEE 1284 Device ID (printer class request GET_DEVICE_ID).
String? _read1284(_ComObject intf) {
  final ifNumber = calloc<Uint8>();
  final alt = calloc<Uint8>();
  final request = calloc<_DevRequestTO>();
  final buffer = calloc<Uint8>(1024);
  try {
    _callU8Out(intf, _slotGetInterfaceNumber, ifNumber);
    _callU8Out(intf, _slotGetAlternateSetting, alt);
    request.ref
      ..bmRequestType =
          0xA1 // device to host, class, interface
      ..bRequest = 0
      ..wValue = 0
      ..wIndex = (ifNumber.value << 8) | alt.value
      ..wLength = 1023
      ..pData = buffer.cast()
      ..noDataTimeout = 1000
      ..completionTimeout = 2000;
    if (_controlRequestTO(intf, request) != 0) return null;
    return decode1284Reply(buffer.asTypedList(request.ref.wLenDone));
  } finally {
    calloc.free(ifNumber);
    calloc.free(alt);
    calloc.free(request);
    calloc.free(buffer);
  }
}

/// An opened printer: the interface's address and its bulk OUT pipe.
typedef _MacSession = ({int address, int pipe, int entryId, UsbPrinter? resolved});

_MacSession _openSync(UsbPrinter wanted) {
  final k = _IOKit();
  final interfaces = _interfaces(k);
  try {
    final printers = [
      for (final i in interfaces)
        UsbPrinter(id: i.id, vendorId: i.vendorId, productId: i.productId, serialNumber: i.serial),
    ];
    final match = wanted.findIn(printers);
    if (match == null) {
      throw const UsbPlatformError('notFound', 'The USB printer is not connected');
    }
    final target = interfaces[printers.indexOf(match)];
    final intf = _openInterface(k, target.service);
    final pipe = _bulkOutPipe(intf);
    if (pipe == 0) {
      _closeInterface(intf);
      throw const UsbPlatformError('unsupported', 'The printer has no bulk OUT endpoint');
    }
    return (
      address: intf.address,
      pipe: pipe,
      entryId: target.entryId,
      resolved: match.id == wanted.id ? null : wanted.copyWith(id: match.id),
    );
  } finally {
    for (final i in interfaces) {
      k.objectRelease(i.service);
    }
  }
}

/// Writes [data] in chunks; returns 0 or the failing IOReturn.
int _writeSync(int address, int pipe, Uint8List data, int chunkSize, int stallMs) {
  final intf = _ComObject.fromAddress(address);
  final buffer = malloc<Uint8>(chunkSize);
  try {
    for (var offset = 0; offset < data.length; offset += chunkSize) {
      final n = math.min(chunkSize, data.length - offset);
      buffer.asTypedList(n).setRange(0, n, data, offset);
      // noDataTimeout: the printer took nothing for stallMs. No completion
      // timeout, so a slow printer working through a long image is fine.
      final kr = _writePipeTO(intf, pipe, buffer, n, stallMs, 0);
      if (kr != 0) return kr;
    }
    return 0;
  } finally {
    malloc.free(buffer);
  }
}

/// Entries this app holds open, so listing does not try to open them too.
final Set<int> macEntriesInUse = {};

/// IEEE 1284 ids read so far, by registry entry id.
final Map<int, String?> mac1284Cache = {};

/// macOS app, straight to a USB printer through IOKit.
class MacUsbTransport implements PrinterTransport {
  MacUsbTransport(this._printer, this._options);

  UsbPrinter _printer;
  final UsbWriteOptions _options;
  _MacSession? _session;

  @override
  UsbPrinter get printer => _printer;

  @override
  bool get isConnected => _session != null;

  @override
  Future<void> connect(Duration timeout) async {
    if (_session != null) return;
    final wanted = _printer;
    final opening = Isolate.run(() => _openSync(wanted));
    try {
      final session = await opening.timeout(timeout);
      _session = session;
      macEntriesInUse.add(session.entryId);
      if (session.resolved != null) _printer = session.resolved!;
    } on TimeoutException catch (e) {
      // Close it if it opens after all.
      unawaited(opening.then((s) => _closeSync(s.address), onError: (_) {}));
      throw PrinterTransportException(PosPrintResult.timeout, e);
    } on UsbPlatformError catch (e) {
      throw PrinterTransportException(resultForCode(e.code, connecting: true), e);
    } catch (e) {
      throw PrinterTransportException(PosPrintResult.connectionFailed, e);
    }
  }

  @override
  Future<void> write(Uint8List data) async {
    final session = _session;
    if (session == null) throw const PrinterTransportException(PosPrintResult.printerNotConnected);
    final chunk = _options.chunkSize;
    final stall = _options.stallTimeout.inMilliseconds;
    final kr = await Isolate.run(
      () => _writeSync(session.address, session.pipe, data, chunk, stall),
    );
    if (kr != 0) {
      final error = _ioError(kr, 'The printer did not take the data');
      throw PrinterTransportException(resultForCode(error.code), error);
    }
  }

  @override
  Future<void> disconnect() async {
    final session = _session;
    _session = null;
    if (session == null) return;
    macEntriesInUse.remove(session.entryId);
    try {
      _closeSync(session.address);
    } catch (_) {
      // Already gone with the device.
    }
  }
}

void _closeSync(int address) => _closeInterface(_ComObject.fromAddress(address));
