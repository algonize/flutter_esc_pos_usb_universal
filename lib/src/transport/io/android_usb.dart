// Android: USB printers through Android's USB host API (the package's Kotlin
// part, over a method channel). Android has no driver for USB printers, so
// the app opens the printer itself. Android asks the user once per printer
// whether the app may use it; connecting asks when needed.

import 'dart:async';

import 'package:flutter/services.dart';

import '../../enums.dart';
import '../../models/usb_printer.dart';
import '../../models/usb_printer_note.dart';
import '../../models/usb_write_options.dart';
import '../../utils/printer_identity.dart';
import '../printer_transport.dart';

const MethodChannel androidUsbChannel = MethodChannel('flutter_esc_pos_usb_universal');

/// Lists the connected USB printers, with Android's device name for each id.
Future<({List<UsbPrinter> printers, Map<String, String> deviceNames, List<UsbPrinterNote> notes})>
listAndroidUsbPrinters() async {
  final List<Object?> raw;
  try {
    raw = await androidUsbChannel.invokeListMethod<Object?>('list') ?? const [];
  } on PlatformException catch (e) {
    throw UsbPlatformError(e.code, e.message ?? 'Could not list USB printers');
  }
  final printers = <UsbPrinter>[];
  final deviceNames = <String, String>{};
  for (final entry in raw) {
    if (entry is! Map) continue;
    final deviceName = entry['deviceName'] as String?;
    if (deviceName == null) continue;
    final printer = androidUsbPrinterFromMap(entry);
    printers.add(printer);
    deviceNames[printer.id] = deviceName;
  }
  final notes = [
    if (printers.any((p) => !p.isAccessible))
      const UsbPrinterNote(
        code: 'permissionRequired',
        message:
            'Android asks once for permission to use each USB printer. It asks when you print '
            'or test print; choose "Allow" (and "Always open" if offered).',
        isWarning: false,
      ),
  ];
  return (printers: classifyPrinters(printers), deviceNames: deviceNames, notes: notes);
}

/// A printer from the Kotlin side's `list` reply.
UsbPrinter androidUsbPrinterFromMap(Map<Object?, Object?> m) {
  final vendorId = (m['vendorId'] as num?)?.toInt();
  final productId = (m['productId'] as num?)?.toInt();
  final serial = m['serialNumber'] as String?;
  final hasSerial = serial != null && serial.isNotEmpty;
  final raw1284 = m['ieee1284'];
  final info = Ieee1284Id.parse(raw1284 is Uint8List ? decode1284Reply(raw1284) : null);
  final product = [
    m['manufacturerName'],
    m['productName'],
  ].whereType<String>().where((s) => s.trim().isNotEmpty).join(' ');
  final interfaceNumber = (m['interfaceNumber'] as num?)?.toInt() ?? 0;
  // Named by serial number when Android shows it (only once the app may use
  // the printer), otherwise by its device node, which changes on replug; the
  // vendor and product ids find it again then (see UsbPrinter.findIn).
  final where = hasSerial ? 'sn=$serial' : 'dev=${m['deviceName']}';
  return UsbPrinter(
    id:
        'android-usb:${hex4(vendorId ?? 0)}:${hex4(productId ?? 0)}:$where'
        '${interfaceNumber == 0 ? '' : '#$interfaceNumber'}',
    name: usbDisplayName(info, product.isEmpty ? null : product, vendorId, productId),
    manufacturer: info.manufacturer ?? m['manufacturerName'] as String?,
    model: info.model ?? m['productName'] as String?,
    vendorId: vendorId,
    productId: productId,
    serialNumber: hasSerial ? serial : info.serialNumber,
    commandSet: info.commandSet,
    isAccessible: m['hasPermission'] == true,
    isBusy: m['busy'] == true,
  );
}

UsbPlatformError _fromPlatform(PlatformException e) =>
    UsbPlatformError(e.code, e.message ?? e.code, detail: e.details?.toString());

/// Android app, straight to a USB printer through the USB host API.
class AndroidUsbTransport implements PrinterTransport {
  AndroidUsbTransport(this._printer, this._options);

  UsbPrinter _printer;
  final UsbWriteOptions _options;
  int? _handle;

  @override
  UsbPrinter get printer => _printer;

  @override
  bool get isConnected => _handle != null;

  @override
  Future<void> connect(Duration timeout) async {
    if (_handle != null) return;
    try {
      var listing = await listAndroidUsbPrinters();
      var match = _printer.findIn(listing.printers);
      if (match == null) {
        throw const UsbPlatformError('notFound', 'The USB printer is not connected');
      }
      if (!match.isAccessible) {
        // Android's own dialog. Not under the connect timeout: the user may
        // take a while to answer.
        final granted =
            await androidUsbChannel.invokeMethod<bool>('requestPermission', {
              'deviceName': listing.deviceNames[match.id],
            }) ??
            false;
        if (!granted) {
          throw const UsbPlatformError(
            'permissionDenied',
            'Android did not allow this app to use the USB printer. Print again and choose "Allow".',
          );
        }
        // Allowed now: Android shows the serial number, which names the printer.
        listing = await listAndroidUsbPrinters();
        match = _printer.findIn(listing.printers) ?? match;
      }
      final deviceName = listing.deviceNames[match.id];
      _handle = await androidUsbChannel
          .invokeMethod<int>('open', {'deviceName': deviceName})
          .timeout(timeout);
      if (match.id != _printer.id) _printer = _printer.copyWith(id: match.id);
    } on TimeoutException catch (e) {
      throw PrinterTransportException(PosPrintResult.timeout, e);
    } on PlatformException catch (e) {
      throw PrinterTransportException(resultForCode(e.code, connecting: true), _fromPlatform(e));
    } on UsbPlatformError catch (e) {
      throw PrinterTransportException(resultForCode(e.code, connecting: true), e);
    }
  }

  @override
  Future<void> write(Uint8List data) async {
    final handle = _handle;
    if (handle == null) throw const PrinterTransportException(PosPrintResult.printerNotConnected);
    try {
      await androidUsbChannel.invokeMethod<int>('write', {
        'handle': handle,
        'data': data,
        'chunkSize': _options.chunkSize,
        'timeoutMs': _options.stallTimeout.inMilliseconds,
      });
    } on PlatformException catch (e) {
      throw PrinterTransportException(resultForCode(e.code), _fromPlatform(e));
    }
  }

  @override
  Future<void> disconnect() async {
    final handle = _handle;
    _handle = null;
    if (handle == null) return;
    try {
      await androidUsbChannel.invokeMethod<void>('close', {'handle': handle});
    } catch (_) {
      // Already gone with the device.
    }
  }
}
