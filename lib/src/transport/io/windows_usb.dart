// Windows: USB printers two ways, both through dart:ffi.
//
// - Straight to the device. Windows loads its own "USB Printing Support"
//   driver (usbprint.sys) for every USB printer-class device, no vendor driver
//   needed. SetupAPI finds the devices, and CreateFile + WriteFile print on
//   them. Overlapped writes give a clean timeout when the printer stops taking
//   data (out of paper, cover open, switched off).
// - Through an installed Windows printer (the spooler), for printers that need
//   their vendor driver. The job goes RAW, or XPS_PASS for v4 / XPS drivers,
//   which turn RAW jobs into empty spool files.
//
// The same logic as the Local TCP bridge's Windows helper, so a printer is
// listed and written the same way in an app and in a browser.
//
// Own bindings rather than package:win32, to stay out of version conflicts
// with the many plugins that pin it.

import 'dart:async';
import 'dart:ffi';
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

// ─── Structures ──────────────────────────────────────────────────────────────

final class _Guid extends Struct {
  @Uint32()
  external int data1;
  @Uint16()
  external int data2;
  @Uint16()
  external int data3;
  @Array(8)
  external Array<Uint8> data4;
}

final class _SpDeviceInterfaceData extends Struct {
  @Uint32()
  external int cbSize;
  external _Guid interfaceClassGuid;
  @Uint32()
  external int flags;
  @IntPtr()
  external int reserved;
}

final class _SpDevinfoData extends Struct {
  @Uint32()
  external int cbSize;
  external _Guid classGuid;
  @Uint32()
  external int devInst;
  @IntPtr()
  external int reserved;
}

final class _DevPropKey extends Struct {
  external _Guid fmtid;
  @Uint32()
  external int pid;
}

final class _Overlapped extends Struct {
  @IntPtr()
  external int internal;
  @IntPtr()
  external int internalHigh;
  @Uint32()
  external int offset;
  @Uint32()
  external int offsetHigh;
  @IntPtr()
  external int hEvent;
}

final class _PrinterInfo2 extends Struct {
  external Pointer<Utf16> pServerName;
  external Pointer<Utf16> pPrinterName;
  external Pointer<Utf16> pShareName;
  external Pointer<Utf16> pPortName;
  external Pointer<Utf16> pDriverName;
  external Pointer<Utf16> pComment;
  external Pointer<Utf16> pLocation;
  external Pointer<Void> pDevMode;
  external Pointer<Utf16> pSepFile;
  external Pointer<Utf16> pPrintProcessor;
  external Pointer<Utf16> pDatatype;
  external Pointer<Utf16> pParameters;
  external Pointer<Void> pSecurityDescriptor;
  @Uint32()
  external int attributes;
  @Uint32()
  external int priority;
  @Uint32()
  external int defaultPriority;
  @Uint32()
  external int startTime;
  @Uint32()
  external int untilTime;
  @Uint32()
  external int status;
  @Uint32()
  external int cJobs;
  @Uint32()
  external int averagePpm;
}

final class _DocInfo1 extends Struct {
  external Pointer<Utf16> pDocName;
  external Pointer<Utf16> pOutputFile;
  external Pointer<Utf16> pDatatype;
}

/// DRIVER_INFO_8W. Only [cVersion] and [printerDriverAttributes] are read; the
/// rest is layout. FILETIMEs are two DWORDs, DWORDLONGs are 8-byte aligned.
final class _DriverInfo8 extends Struct {
  @Uint32()
  external int cVersion;
  external Pointer<Utf16> pName;
  external Pointer<Utf16> pEnvironment;
  external Pointer<Utf16> pDriverPath;
  external Pointer<Utf16> pDataFile;
  external Pointer<Utf16> pConfigFile;
  external Pointer<Utf16> pHelpFile;
  external Pointer<Utf16> pDependentFiles;
  external Pointer<Utf16> pMonitorName;
  external Pointer<Utf16> pDefaultDataType;
  external Pointer<Utf16> pszzPreviousNames;
  @Uint32()
  external int ftDriverDateLow;
  @Uint32()
  external int ftDriverDateHigh;
  @Uint64()
  external int dwlDriverVersion;
  external Pointer<Utf16> pszMfgName;
  external Pointer<Utf16> pszOemUrl;
  external Pointer<Utf16> pszHardwareId;
  external Pointer<Utf16> pszProvider;
  external Pointer<Utf16> pszPrintProcessor;
  external Pointer<Utf16> pszVendorSetup;
  external Pointer<Utf16> pszzColorProfiles;
  external Pointer<Utf16> pszInfPath;
  @Uint32()
  external int printerDriverAttributes;
  external Pointer<Utf16> pszzCoreDriverDependencies;
  @Uint32()
  external int ftMinInboxDriverVerDateLow;
  @Uint32()
  external int ftMinInboxDriverVerDateHigh;
  @Uint64()
  external int dwlMinInboxDriverVerVersion;
}

// ─── Constants ───────────────────────────────────────────────────────────────

const _digcfPresent = 0x02;
const _digcfDeviceInterface = 0x10;
const _errorFileNotFound = 2;
const _errorNoMoreItems = 259;
const _errorIoPending = 997;
const _errorInvalidDatatype = 1804;
const _genericWrite = 0x40000000;
const _fileShareRead = 0x1;
const _fileShareWrite = 0x2;
const _openExisting = 3;
const _fileFlagOverlapped = 0x40000000;
const _ioctlUsbprintGet1284Id = 0x220034;
const _keyRead = 0x20019;
const _regDword = 4;
const _regSz = 1;
const _printerEnumLocal = 0x2;
const _printerEnumConnections = 0x4;
const _printerDriverXps = 0x2;
const _waitTimeout = 0x102;
const _invalidHandle = -1;

final _virtualPorts = RegExp(r'^(PORTPROMPT:|FILE:|NUL:?|SHRFAX:|XPSPORT:)$', caseSensitive: false);
final _virtualDrivers = RegExp(
  r'Print To PDF|XPS Document Writer|Shared Fax|OneNote',
  caseSensitive: false,
);

/// The interface usbprint.sys registers for every USB printer-class device:
/// {28d78fad-5a12-11d1-ae5b-0000f803a8c2}.
void _setUsbPrintGuid(_Guid g) {
  g
    ..data1 = 0x28d78fad
    ..data2 = 0x5a12
    ..data3 = 0x11d1;
  const tail = [0xae, 0x5b, 0x00, 0x00, 0xf8, 0x03, 0xa8, 0xc2];
  for (var i = 0; i < 8; i++) {
    g.data4[i] = tail[i];
  }
}

/// DEVPKEY_Device_BusReportedDeviceDesc: the product string the printer reports.
void _setBusReportedDescKey(_DevPropKey k) {
  k.fmtid
    ..data1 = 0x540b947e
    ..data2 = 0x8b40
    ..data3 = 0x45bc;
  const tail = [0xa8, 0xa2, 0x6a, 0x0b, 0x89, 0x4c, 0xbd, 0xa2];
  for (var i = 0; i < 8; i++) {
    k.fmtid.data4[i] = tail[i];
  }
  k.pid = 4;
}

// ─── Bindings ────────────────────────────────────────────────────────────────

/// The Win32 functions used here. One per isolate.
///
/// GetLastError is looked up here, before any other call, so looking it up
/// later cannot overwrite the error it is meant to read. Every other function
/// is looked up when first read, which is before it runs.
class _Win32 {
  _Win32()
    : _kernel32 = DynamicLibrary.open('kernel32.dll'),
      _setupapi = DynamicLibrary.open('setupapi.dll'),
      _advapi32 = DynamicLibrary.open('advapi32.dll'),
      _winspool = DynamicLibrary.open('winspool.drv'),
      getLastError = DynamicLibrary.open(
        'kernel32.dll',
      ).lookupFunction<Uint32 Function(), int Function()>('GetLastError');

  final DynamicLibrary _kernel32;
  final DynamicLibrary _setupapi;
  final DynamicLibrary _advapi32;
  final DynamicLibrary _winspool;
  final int Function() getLastError;

  late final createFile = _kernel32
      .lookupFunction<
        IntPtr Function(Pointer<Utf16>, Uint32, Uint32, Pointer<Void>, Uint32, Uint32, IntPtr),
        int Function(Pointer<Utf16>, int, int, Pointer<Void>, int, int, int)
      >('CreateFileW');
  late final writeFile = _kernel32
      .lookupFunction<
        Int32 Function(IntPtr, Pointer<Uint8>, Uint32, Pointer<Uint32>, Pointer<_Overlapped>),
        int Function(int, Pointer<Uint8>, int, Pointer<Uint32>, Pointer<_Overlapped>)
      >('WriteFile');
  late final getOverlappedResult = _kernel32
      .lookupFunction<
        Int32 Function(IntPtr, Pointer<_Overlapped>, Pointer<Uint32>, Int32),
        int Function(int, Pointer<_Overlapped>, Pointer<Uint32>, int)
      >('GetOverlappedResult');
  late final cancelIoEx = _kernel32
      .lookupFunction<
        Int32 Function(IntPtr, Pointer<_Overlapped>),
        int Function(int, Pointer<_Overlapped>)
      >('CancelIoEx');
  late final deviceIoControl = _kernel32
      .lookupFunction<
        Int32 Function(
          IntPtr,
          Uint32,
          Pointer<Void>,
          Uint32,
          Pointer<Uint8>,
          Uint32,
          Pointer<Uint32>,
          Pointer<Void>,
        ),
        int Function(
          int,
          int,
          Pointer<Void>,
          int,
          Pointer<Uint8>,
          int,
          Pointer<Uint32>,
          Pointer<Void>,
        )
      >('DeviceIoControl');
  late final closeHandle = _kernel32.lookupFunction<Int32 Function(IntPtr), int Function(int)>(
    'CloseHandle',
  );
  late final createEvent = _kernel32
      .lookupFunction<
        IntPtr Function(Pointer<Void>, Int32, Int32, Pointer<Utf16>),
        int Function(Pointer<Void>, int, int, Pointer<Utf16>)
      >('CreateEventW');
  late final resetEvent = _kernel32.lookupFunction<Int32 Function(IntPtr), int Function(int)>(
    'ResetEvent',
  );
  late final waitForSingleObject = _kernel32
      .lookupFunction<Uint32 Function(IntPtr, Uint32), int Function(int, int)>(
        'WaitForSingleObject',
      );

  late final getClassDevs = _setupapi
      .lookupFunction<
        IntPtr Function(Pointer<_Guid>, Pointer<Utf16>, IntPtr, Uint32),
        int Function(Pointer<_Guid>, Pointer<Utf16>, int, int)
      >('SetupDiGetClassDevsW');
  late final enumDeviceInterfaces = _setupapi
      .lookupFunction<
        Int32 Function(
          IntPtr,
          Pointer<_SpDevinfoData>,
          Pointer<_Guid>,
          Uint32,
          Pointer<_SpDeviceInterfaceData>,
        ),
        int Function(
          int,
          Pointer<_SpDevinfoData>,
          Pointer<_Guid>,
          int,
          Pointer<_SpDeviceInterfaceData>,
        )
      >('SetupDiEnumDeviceInterfaces');
  late final getDeviceInterfaceDetail = _setupapi
      .lookupFunction<
        Int32 Function(
          IntPtr,
          Pointer<_SpDeviceInterfaceData>,
          Pointer<Uint8>,
          Uint32,
          Pointer<Uint32>,
          Pointer<_SpDevinfoData>,
        ),
        int Function(
          int,
          Pointer<_SpDeviceInterfaceData>,
          Pointer<Uint8>,
          int,
          Pointer<Uint32>,
          Pointer<_SpDevinfoData>,
        )
      >('SetupDiGetDeviceInterfaceDetailW');
  late final getDeviceInstanceId = _setupapi
      .lookupFunction<
        Int32 Function(IntPtr, Pointer<_SpDevinfoData>, Pointer<Utf16>, Uint32, Pointer<Uint32>),
        int Function(int, Pointer<_SpDevinfoData>, Pointer<Utf16>, int, Pointer<Uint32>)
      >('SetupDiGetDeviceInstanceIdW');
  late final getDeviceProperty = _setupapi
      .lookupFunction<
        Int32 Function(
          IntPtr,
          Pointer<_SpDevinfoData>,
          Pointer<_DevPropKey>,
          Pointer<Uint32>,
          Pointer<Uint8>,
          Uint32,
          Pointer<Uint32>,
          Uint32,
        ),
        int Function(
          int,
          Pointer<_SpDevinfoData>,
          Pointer<_DevPropKey>,
          Pointer<Uint32>,
          Pointer<Uint8>,
          int,
          Pointer<Uint32>,
          int,
        )
      >('SetupDiGetDevicePropertyW');
  late final openDeviceInterfaceRegKey = _setupapi
      .lookupFunction<
        IntPtr Function(IntPtr, Pointer<_SpDeviceInterfaceData>, Uint32, Uint32),
        int Function(int, Pointer<_SpDeviceInterfaceData>, int, int)
      >('SetupDiOpenDeviceInterfaceRegKey');
  late final destroyDeviceInfoList = _setupapi
      .lookupFunction<Int32 Function(IntPtr), int Function(int)>('SetupDiDestroyDeviceInfoList');

  late final regQueryValueEx = _advapi32
      .lookupFunction<
        Int32 Function(
          IntPtr,
          Pointer<Utf16>,
          Pointer<Uint32>,
          Pointer<Uint32>,
          Pointer<Uint8>,
          Pointer<Uint32>,
        ),
        int Function(
          int,
          Pointer<Utf16>,
          Pointer<Uint32>,
          Pointer<Uint32>,
          Pointer<Uint8>,
          Pointer<Uint32>,
        )
      >('RegQueryValueExW');
  late final regCloseKey = _advapi32.lookupFunction<Int32 Function(IntPtr), int Function(int)>(
    'RegCloseKey',
  );

  late final enumPrinters = _winspool
      .lookupFunction<
        Int32 Function(
          Uint32,
          Pointer<Utf16>,
          Uint32,
          Pointer<Uint8>,
          Uint32,
          Pointer<Uint32>,
          Pointer<Uint32>,
        ),
        int Function(
          int,
          Pointer<Utf16>,
          int,
          Pointer<Uint8>,
          int,
          Pointer<Uint32>,
          Pointer<Uint32>,
        )
      >('EnumPrintersW');
  late final getDefaultPrinter = _winspool
      .lookupFunction<
        Int32 Function(Pointer<Utf16>, Pointer<Uint32>),
        int Function(Pointer<Utf16>, Pointer<Uint32>)
      >('GetDefaultPrinterW');
  late final openPrinter = _winspool
      .lookupFunction<
        Int32 Function(Pointer<Utf16>, Pointer<IntPtr>, Pointer<Void>),
        int Function(Pointer<Utf16>, Pointer<IntPtr>, Pointer<Void>)
      >('OpenPrinterW');
  late final closePrinter = _winspool.lookupFunction<Int32 Function(IntPtr), int Function(int)>(
    'ClosePrinter',
  );
  late final getPrinterDriver = _winspool
      .lookupFunction<
        Int32 Function(IntPtr, Pointer<Utf16>, Uint32, Pointer<Uint8>, Uint32, Pointer<Uint32>),
        int Function(int, Pointer<Utf16>, int, Pointer<Uint8>, int, Pointer<Uint32>)
      >('GetPrinterDriverW');
  late final startDocPrinter = _winspool
      .lookupFunction<
        Uint32 Function(IntPtr, Uint32, Pointer<_DocInfo1>),
        int Function(int, int, Pointer<_DocInfo1>)
      >('StartDocPrinterW');
  late final startPagePrinter = _winspool.lookupFunction<Int32 Function(IntPtr), int Function(int)>(
    'StartPagePrinter',
  );
  late final writePrinter = _winspool
      .lookupFunction<
        Int32 Function(IntPtr, Pointer<Uint8>, Uint32, Pointer<Uint32>),
        int Function(int, Pointer<Uint8>, int, Pointer<Uint32>)
      >('WritePrinter');
  late final endPagePrinter = _winspool.lookupFunction<Int32 Function(IntPtr), int Function(int)>(
    'EndPagePrinter',
  );
  late final endDocPrinter = _winspool.lookupFunction<Int32 Function(IntPtr), int Function(int)>(
    'EndDocPrinter',
  );
  late final abortPrinter = _winspool.lookupFunction<Int32 Function(IntPtr), int Function(int)>(
    'AbortPrinter',
  );
}

// ─── Errors ──────────────────────────────────────────────────────────────────

/// The package's code for a Win32 error.
String windowsErrorCode(int error) => switch (error) {
  // FILE_NOT_FOUND, PATH_NOT_FOUND, NOT_READY, NO_SUCH_DEVICE,
  // DEVICE_NOT_CONNECTED, INVALID_PRINTER_NAME
  2 || 3 || 21 || 433 || 1167 || 1801 => 'notFound',
  // ACCESS_DENIED (held by the spooler during a job), SHARING_VIOLATION, BUSY
  5 || 32 || 170 => 'busy',
  995 || 1460 => 'timeout', // OPERATION_ABORTED, TIMEOUT
  _ => 'ioError',
};

UsbPlatformError _win32Error(int error, String what) {
  final code = windowsErrorCode(error);
  final message = switch (code) {
    'busy' =>
      '$what: another program is using the printer (for example the Windows '
          'print queue). Try again in a moment',
    'notFound' => '$what: the printer is not connected',
    _ => what,
  };
  return UsbPlatformError(code, message, detail: 'Win32 error $error');
}

// ─── Listing ─────────────────────────────────────────────────────────────────

/// Lists the USB printers (straight to the device) and the installed Windows
/// printers, in a background isolate.
Future<({List<UsbPrinter> printers, List<UsbPrinterNote> notes})> listWindowsPrinters({
  bool includeVirtual = false,
}) {
  return Isolate.run(() => _listSync(includeVirtual));
}

({List<UsbPrinter> printers, List<UsbPrinterNote> notes}) _listSync(bool includeVirtual) {
  final w = _Win32();
  final devices = _listDevices(w);
  final notes = <UsbPrinterNote>[];
  List<_Queue> queues;
  try {
    queues = _listQueues(w);
  } on UsbPlatformError {
    queues = const [];
    notes.add(
      const UsbPrinterNote(
        code: 'queuesUnavailable',
        message:
            'Installed Windows printers could not be listed (is the Print Spooler service running?).',
      ),
    );
  }
  String? defaultQueue;
  try {
    defaultQueue = _defaultPrinter(w);
  } catch (_) {}

  final printers = <UsbPrinter>[...devices];
  final drivers = <String, String>{};
  for (final q in queues) {
    final virtual =
        _virtualPorts.hasMatch(q.port ?? '') || _virtualDrivers.hasMatch(q.driver ?? '');
    if (virtual && !includeVirtual) continue;
    final device = q.port == null
        ? null
        : devices.where((d) => _sameText(d.port, q.port)).firstOrNull;
    final id = 'win-queue:${q.name}';
    if (q.driver != null) drivers[id] = q.driver!;
    printers.add(
      UsbPrinter(
        id: id,
        kind: UsbPrinterKind.queue,
        name: q.name,
        port: q.port,
        queueStatus: windowsQueueStatus(q.status, q.attributes),
        isDefault: _sameText(q.name, defaultQueue),
        devicePrinterId: device?.id,
      ),
    );
  }
  return (printers: classifyPrinters(printers, drivers: drivers), notes: notes);
}

List<UsbPrinter> _listDevices(_Win32 w) {
  final guid = calloc<_Guid>();
  final iface = calloc<_SpDeviceInterfaceData>();
  final printers = <UsbPrinter>[];
  _setUsbPrintGuid(guid.ref);
  final set = w.getClassDevs(guid, nullptr, 0, _digcfPresent | _digcfDeviceInterface);
  try {
    if (set == _invalidHandle) throw _win32Error(w.getLastError(), 'Could not list USB printers');
    for (var i = 0; ; i++) {
      iface.ref.cbSize = sizeOf<_SpDeviceInterfaceData>();
      if (w.enumDeviceInterfaces(set, nullptr, guid, i, iface) == 0) {
        if (w.getLastError() == _errorNoMoreItems) break;
        continue;
      }
      try {
        final device = _describeDevice(w, set, iface);
        if (device != null) printers.add(device);
      } catch (_) {
        // One odd device must not hide the others.
      }
    }
  } finally {
    if (set != _invalidHandle) w.destroyDeviceInfoList(set);
    calloc.free(guid);
    calloc.free(iface);
  }
  return printers;
}

UsbPrinter? _describeDevice(_Win32 w, int set, Pointer<_SpDeviceInterfaceData> iface) {
  final dev = calloc<_SpDevinfoData>();
  final required = calloc<Uint32>();
  try {
    dev.ref.cbSize = sizeOf<_SpDevinfoData>();
    w.getDeviceInterfaceDetail(set, iface, nullptr, 0, required, dev);
    if (required.value <= 0) return null;

    final String path;
    final detail = calloc<Uint8>(required.value);
    try {
      // SP_DEVICE_INTERFACE_DETAIL_DATA_W is a DWORD cbSize, then the path.
      // cbSize is the fixed part with padding: 8 on 64-bit, 6 on 32-bit. The
      // path always starts at offset 4.
      detail.cast<Uint32>().value = sizeOf<IntPtr>() == 8 ? 8 : 6;
      if (w.getDeviceInterfaceDetail(set, iface, detail, required.value, required, dev) == 0) {
        return null;
      }
      path = (detail + 4).cast<Utf16>().toDartString();
    } finally {
      calloc.free(detail);
    }
    if (path.isEmpty) return null;

    final (ieee1284, busy) = _read1284Id(w, path);
    final info = Ieee1284Id.parse(ieee1284);
    final instanceId = _instanceId(w, set, dev);
    final busName = _busReportedName(w, set, dev);
    final ids = windowsUsbIds(instanceId ?? path);
    return UsbPrinter(
      id: 'win-usb:$path',
      name: usbDisplayName(info, busName, ids.vendorId, ids.productId),
      manufacturer: info.manufacturer,
      model: info.model ?? busName,
      vendorId: ids.vendorId,
      productId: ids.productId,
      serialNumber: ids.serialNumber ?? info.serialNumber,
      commandSet: info.commandSet,
      port: _portName(w, set, iface),
      isBusy: busy,
    );
  } finally {
    calloc.free(dev);
    calloc.free(required);
  }
}

String? _instanceId(_Win32 w, int set, Pointer<_SpDevinfoData> dev) {
  final buffer = calloc<Uint16>(512);
  final required = calloc<Uint32>();
  try {
    if (w.getDeviceInstanceId(set, dev, buffer.cast(), 512, required) == 0) return null;
    return buffer.cast<Utf16>().toDartString();
  } finally {
    calloc.free(buffer);
    calloc.free(required);
  }
}

String? _busReportedName(_Win32 w, int set, Pointer<_SpDevinfoData> dev) {
  final key = calloc<_DevPropKey>();
  final type = calloc<Uint32>();
  final buffer = calloc<Uint8>(1024);
  final required = calloc<Uint32>();
  try {
    _setBusReportedDescKey(key.ref);
    if (w.getDeviceProperty(set, dev, key, type, buffer, 1024, required, 0) == 0) return null;
    final name = buffer.cast<Utf16>().toDartString().trim();
    return name.isEmpty ? null : name;
  } finally {
    calloc.free(key);
    calloc.free(type);
    calloc.free(buffer);
    calloc.free(required);
  }
}

/// The spooler port (USB001, USB002, ...) usbprint.sys gave the device, from
/// the interface's "Device Parameters" key. Ties an installed Windows printer
/// to the USB device it prints on.
String? _portName(_Win32 w, int set, Pointer<_SpDeviceInterfaceData> iface) {
  final key = w.openDeviceInterfaceRegKey(set, iface, 0, _keyRead);
  if (key == _invalidHandle || key == 0) return null;
  final type = calloc<Uint32>();
  final size = calloc<Uint32>();
  final buffer = calloc<Uint8>(512);
  final portNumber = 'Port Number'.toNativeUtf16();
  final baseName = 'Base Name'.toNativeUtf16();
  try {
    size.value = 4;
    if (w.regQueryValueEx(key, portNumber, nullptr, type, buffer, size) != 0 ||
        type.value != _regDword) {
      return null;
    }
    final number = buffer.cast<Uint32>().value;
    size.value = 510;
    var prefix = 'USB';
    if (w.regQueryValueEx(key, baseName, nullptr, type, buffer, size) == 0 &&
        type.value == _regSz) {
      buffer[size.value] = 0;
      buffer[size.value + 1] = 0;
      final name = buffer.cast<Utf16>().toDartString();
      if (name.isNotEmpty) prefix = name;
    }
    return '$prefix${number.toString().padLeft(3, '0')}';
  } finally {
    w.regCloseKey(key);
    calloc.free(type);
    calloc.free(size);
    calloc.free(buffer);
    malloc.free(portNumber);
    malloc.free(baseName);
  }
}

/// The printer's IEEE 1284 Device ID. Opened with no read or write access and
/// closed at once, so it never holds the printer. Busy when another program
/// has it open.
(String?, bool) _read1284Id(_Win32 w, String path) {
  final p = path.toNativeUtf16();
  final handle = w.createFile(p, 0, _fileShareRead | _fileShareWrite, nullptr, _openExisting, 0, 0);
  final error = w.getLastError();
  malloc.free(p);
  if (handle == _invalidHandle) return (null, error == 5 || error == 32 || error == 170);
  // Kept well under 4 KB: some devices fail the request with larger buffers.
  final buffer = calloc<Uint8>(1024);
  final got = calloc<Uint32>();
  try {
    final ok = w.deviceIoControl(
      handle,
      _ioctlUsbprintGet1284Id,
      nullptr,
      0,
      buffer,
      1024,
      got,
      nullptr,
    );
    if (ok == 0 || got.value <= 2) return (null, false);
    return (decode1284Reply(buffer.asTypedList(got.value)), false);
  } finally {
    w.closeHandle(handle);
    calloc.free(buffer);
    calloc.free(got);
  }
}

class _Queue {
  const _Queue(this.name, this.port, this.driver, this.status, this.attributes);

  final String name;
  final String? port;
  final String? driver;
  final int status;
  final int attributes;
}

List<_Queue> _listQueues(_Win32 w) {
  const flags = _printerEnumLocal | _printerEnumConnections;
  final needed = calloc<Uint32>();
  final returned = calloc<Uint32>();
  try {
    w.enumPrinters(flags, nullptr, 2, nullptr, 0, needed, returned);
    if (needed.value <= 0) return const [];
    final buffer = calloc<Uint8>(needed.value);
    try {
      if (w.enumPrinters(flags, nullptr, 2, buffer, needed.value, needed, returned) == 0) {
        throw _win32Error(w.getLastError(), 'Could not list Windows printers');
      }
      final infos = buffer.cast<_PrinterInfo2>();
      return [
        for (var i = 0; i < returned.value; i++)
          if (infos[i].pPrinterName != nullptr)
            _Queue(
              infos[i].pPrinterName.toDartString(),
              _string(infos[i].pPortName),
              _string(infos[i].pDriverName),
              infos[i].status,
              infos[i].attributes,
            ),
      ];
    } finally {
      calloc.free(buffer);
    }
  } finally {
    calloc.free(needed);
    calloc.free(returned);
  }
}

String? _defaultPrinter(_Win32 w) {
  final size = calloc<Uint32>();
  try {
    w.getDefaultPrinter(nullptr, size);
    if (size.value <= 0) return null;
    final buffer = calloc<Uint16>(size.value);
    try {
      return w.getDefaultPrinter(buffer.cast(), size) == 0
          ? null
          : buffer.cast<Utf16>().toDartString();
    } finally {
      calloc.free(buffer);
    }
  } finally {
    calloc.free(size);
  }
}

String? _string(Pointer<Utf16> p) => p == nullptr ? null : p.toDartString();

bool _sameText(String? a, String? b) =>
    a != null && b != null && a.isNotEmpty && a.toLowerCase() == b.toLowerCase();

/// USB\VID_0416&PID_5011\<instance>: the instance is the device's serial
/// number when it has one (no '&'), otherwise a Windows-made, port-based id.
({int? vendorId, int? productId, String? serialNumber}) windowsUsbIds(String text) {
  final m = RegExp(r'VID_([0-9A-F]{4})&PID_([0-9A-F]{4})', caseSensitive: false).firstMatch(text);
  final parts = text.split(RegExp(r'[\\#]'));
  final vidIndex = parts.indexWhere(
    (p) => RegExp(r'VID_[0-9A-F]{4}&PID_[0-9A-F]{4}', caseSensitive: false).hasMatch(p),
  );
  final instance = vidIndex >= 0 && vidIndex + 1 < parts.length ? parts[vidIndex + 1] : null;
  final hasSerial =
      instance != null &&
      instance.isNotEmpty &&
      !instance.contains('&') &&
      !RegExp(r'MI_\d+', caseSensitive: false).hasMatch(parts[vidIndex]);
  return (
    vendorId: m == null ? null : int.parse(m.group(1)!, radix: 16),
    productId: m == null ? null : int.parse(m.group(2)!, radix: 16),
    serialNumber: hasSerial ? instance : null,
  );
}

/// PRINTER_INFO_2 Status and Attributes bits.
UsbQueueStatus windowsQueueStatus(int status, int attributes) {
  if (attributes & 0x400 != 0 || status & 0x80 != 0) return UsbQueueStatus.offline;
  if (status & 0x10 != 0) return UsbQueueStatus.paperOut;
  if (status & 0x1 != 0) return UsbQueueStatus.paused;
  if (status & 0x2 != 0) return UsbQueueStatus.error;
  if (status & 0x400 != 0) return UsbQueueStatus.printing;
  return UsbQueueStatus.ready;
}

// ─── Straight to the device ──────────────────────────────────────────────────

/// Writes [data] with overlapped WriteFile in [chunkSize] pieces. Returns 0,
/// -1 when a piece was not taken within [stallMs], -2 when the printer took
/// nothing, or a Win32 error.
int _writeDeviceSync(int handle, Uint8List data, int chunkSize, int stallMs) {
  final w = _Win32();
  final buffer = calloc<Uint8>(chunkSize);
  final overlapped = calloc<_Overlapped>();
  final transferred = calloc<Uint32>();
  final event = w.createEvent(nullptr, 1, 0, nullptr);
  try {
    if (event == 0) return w.getLastError();
    var offset = 0;
    while (offset < data.length) {
      final n = math.min(chunkSize, data.length - offset);
      buffer.asTypedList(n).setRange(0, n, data, offset);
      w.resetEvent(event);
      overlapped.ref
        ..internal = 0
        ..internalHigh = 0
        ..offset = 0
        ..offsetHigh = 0
        ..hEvent = event;
      if (w.writeFile(handle, buffer, n, nullptr, overlapped) == 0) {
        final error = w.getLastError();
        if (error != _errorIoPending) return error;
        if (w.waitForSingleObject(event, stallMs) == _waitTimeout) {
          w.cancelIoEx(handle, overlapped);
          // Wait for the cancellation to land before the buffers are freed.
          w.getOverlappedResult(handle, overlapped, transferred, 1);
          return -1;
        }
      }
      if (w.getOverlappedResult(handle, overlapped, transferred, 1) == 0) return w.getLastError();
      if (transferred.value <= 0) return -2;
      offset += transferred.value;
    }
    return 0;
  } finally {
    if (event != 0) w.closeHandle(event);
    calloc.free(buffer);
    calloc.free(overlapped);
    calloc.free(transferred);
  }
}

/// Windows app, straight to a USB printer through usbprint.sys.
class WindowsDeviceTransport implements PrinterTransport {
  WindowsDeviceTransport(this._printer, this._options);

  UsbPrinter _printer;
  final UsbWriteOptions _options;
  int? _handle;

  @override
  UsbPrinter get printer => _printer;

  @override
  bool get isConnected => _handle != null;

  static (int, int) _open(String path) {
    final w = _Win32();
    final p = path.toNativeUtf16();
    try {
      final handle = w.createFile(
        p,
        _genericWrite,
        _fileShareRead | _fileShareWrite,
        nullptr,
        _openExisting,
        _fileFlagOverlapped,
        0,
      );
      return (handle, handle == _invalidHandle ? w.getLastError() : 0);
    } finally {
      malloc.free(p);
    }
  }

  @override
  Future<void> connect(Duration timeout) async {
    if (_handle != null) return;
    var (handle, error) = _open(_path(_printer.id));
    if (handle == _invalidHandle && windowsErrorCode(error) == 'notFound') {
      // Plugged into another port, so another device path: find it again by
      // vendor id, product id and serial number.
      final listing = await listWindowsPrinters().timeout(timeout);
      final match = _printer.findIn(listing.printers);
      if (match != null && match.id != _printer.id) {
        (handle, error) = _open(_path(match.id));
        if (handle != _invalidHandle) _printer = _printer.copyWith(id: match.id);
      }
    }
    if (handle == _invalidHandle) {
      final e = _win32Error(error, 'Could not open the USB printer');
      throw PrinterTransportException(resultForCode(e.code, connecting: true), e);
    }
    _handle = handle;
  }

  static String _path(String id) => id.substring('win-usb:'.length);

  @override
  Future<void> write(Uint8List data) async {
    final handle = _handle;
    if (handle == null) throw const PrinterTransportException(PosPrintResult.printerNotConnected);
    final chunk = _options.chunkSize;
    final stall = _options.stallTimeout.inMilliseconds;
    final result = await Isolate.run(() => _writeDeviceSync(handle, data, chunk, stall));
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
    if (result == -2) {
      throw const PrinterTransportException(
        PosPrintResult.writeFailed,
        UsbPlatformError('ioError', 'The printer accepted no data'),
      );
    }
    final error = _win32Error(result, 'The printer did not take the data');
    throw PrinterTransportException(resultForCode(error.code), error);
  }

  @override
  Future<void> disconnect() async {
    final handle = _handle;
    _handle = null;
    if (handle != null) _Win32().closeHandle(handle);
  }
}

// ─── Through the spooler ─────────────────────────────────────────────────────

/// Sends [data] as one RAW (or XPS_PASS) job. Returns the job id, or throws.
int _writeQueueSync(int printer, Uint8List data, String jobName) {
  final w = _Win32();
  final doc = calloc<_DocInfo1>();
  final docName = (jobName.isEmpty ? 'Receipt' : jobName).toNativeUtf16();
  final raw = 'RAW'.toNativeUtf16();
  final xpsPass = 'XPS_PASS'.toNativeUtf16();
  final buffer = calloc<Uint8>(data.length);
  final written = calloc<Uint32>();
  try {
    // v4 and XPS-based drivers turn a RAW job into an empty spool file; they
    // pass bytes through only with the XPS_PASS data type.
    var useXps = _usesXpsDriver(w, printer);
    doc.ref
      ..pDocName = docName
      ..pOutputFile = nullptr
      ..pDatatype = useXps ? xpsPass : raw;
    var job = w.startDocPrinter(printer, 1, doc);
    if (job == 0) {
      final error = w.getLastError();
      if (error != _errorInvalidDatatype || useXps) {
        throw _win32Error(error, 'Could not start the print job');
      }
      useXps = true;
      doc.ref.pDatatype = xpsPass;
      job = w.startDocPrinter(printer, 1, doc);
      if (job == 0) throw _win32Error(w.getLastError(), 'Could not start the print job');
    }
    var ended = false;
    try {
      if (w.startPagePrinter(printer) == 0) {
        throw _win32Error(w.getLastError(), 'Could not start the print job');
      }
      buffer.asTypedList(data.length).setAll(0, data);
      var offset = 0;
      while (offset < data.length) {
        if (w.writePrinter(printer, buffer + offset, data.length - offset, written) == 0) {
          throw _win32Error(w.getLastError(), 'Could not send data to the printer');
        }
        if (written.value <= 0) {
          throw const UsbPlatformError('ioError', 'The print queue accepted no data');
        }
        offset += written.value;
      }
      w.endPagePrinter(printer);
      if (w.endDocPrinter(printer) == 0) {
        throw _win32Error(w.getLastError(), 'Could not finish the print job');
      }
      ended = true;
    } finally {
      // A half-written job must not print: drop it instead of ending it.
      if (!ended) w.abortPrinter(printer);
    }
    return job;
  } finally {
    calloc.free(doc);
    malloc.free(docName);
    malloc.free(raw);
    malloc.free(xpsPass);
    calloc.free(buffer);
    calloc.free(written);
  }
}

bool _usesXpsDriver(_Win32 w, int printer) {
  final needed = calloc<Uint32>();
  try {
    w.getPrinterDriver(printer, nullptr, 8, nullptr, 0, needed);
    if (needed.value < sizeOf<_DriverInfo8>()) return false;
    final buffer = calloc<Uint8>(needed.value);
    try {
      if (w.getPrinterDriver(printer, nullptr, 8, buffer, needed.value, needed) == 0) return false;
      final info = buffer.cast<_DriverInfo8>().ref;
      return info.cVersion >= 4 || info.printerDriverAttributes & _printerDriverXps != 0;
    } finally {
      calloc.free(buffer);
    }
  } finally {
    calloc.free(needed);
  }
}

/// Windows app, through an installed Windows printer.
class WindowsQueueTransport implements PrinterTransport {
  WindowsQueueTransport(this._printer, this._options);

  final UsbPrinter _printer;
  final UsbWriteOptions _options;
  int? _handle;

  /// The spooler's id for the last job.
  int? lastJobId;

  @override
  UsbPrinter get printer => _printer;

  @override
  bool get isConnected => _handle != null;

  @override
  Future<void> connect(Duration timeout) async {
    if (_handle != null) return;
    final w = _Win32();
    final name = _printer.id.substring('win-queue:'.length).toNativeUtf16();
    final out = calloc<IntPtr>();
    try {
      if (w.openPrinter(name, out, nullptr) == 0) {
        final error = w.getLastError();
        final e = error == _errorFileNotFound || error == 1801
            ? const UsbPlatformError(
                'notFound',
                'This printer is no longer installed on the computer',
              )
            : _win32Error(error, 'Could not open the Windows printer');
        throw PrinterTransportException(resultForCode(e.code, connecting: true), e);
      }
      _handle = out.value;
    } finally {
      malloc.free(name);
      calloc.free(out);
    }
  }

  @override
  Future<void> write(Uint8List data) async {
    final handle = _handle;
    if (handle == null) throw const PrinterTransportException(PosPrintResult.printerNotConnected);
    final jobName = _options.jobName;
    try {
      // The spooler takes the job into a spool file, so this is quick; the
      // limit is only a safety net against a hung spooler.
      lastJobId = await Isolate.run(
        () => _writeQueueSync(handle, data, jobName),
      ).timeout(_options.stallTimeout + const Duration(seconds: 30));
    } on TimeoutException catch (e) {
      throw PrinterTransportException(PosPrintResult.timeout, e);
    } on UsbPlatformError catch (e) {
      throw PrinterTransportException(resultForCode(e.code), e);
    }
  }

  @override
  Future<void> disconnect() async {
    final handle = _handle;
    _handle = null;
    if (handle != null) _Win32().closePrinter(handle);
  }
}
