import 'dart:async';
import 'dart:js_interop';
import 'dart:math' as math;
import 'dart:typed_data';

import '../../enums.dart';
import '../../models/usb_printer.dart';
import '../../models/usb_write_options.dart';
import '../../utils/printer_identity.dart';
import '../printer_transport.dart';
import 'web_env.dart';
import 'webusb_bindings.dart';

const _printerClass = 7;

/// The printer for a WebUSB [device]. [twin] counts the devices before it with
/// the same vendor and product ids and no serial number, to tell them apart.
UsbPrinter webUsbPrinter(UsbDevice device, int twin) {
  final serial = device.serialNumber;
  final hasSerial = serial != null && serial.isNotEmpty;
  final ids = '${hex4(device.vendorId)}:${hex4(device.productId)}';
  final printer = UsbPrinter(
    id: 'webusb:$ids:${hasSerial ? 'sn=$serial' : '#${twin + 1}'}',
    name: usbDisplayName(
      const Ieee1284Id(),
      [
        device.manufacturerName,
        device.productName,
      ].whereType<String>().where((s) => s.isNotEmpty).join(' '),
      device.vendorId,
      device.productId,
    ),
    manufacturer: device.manufacturerName,
    model: device.productName,
    vendorId: device.vendorId,
    productId: device.productId,
    serialNumber: hasSerial ? serial : null,
  );
  final c = classifyPrinter(printer);
  return printer.copyWith(category: c.category, paperWidthMm: c.paperWidthMm);
}

/// The devices this page may use, each with its printer.
Future<List<(UsbDevice, UsbPrinter)>> grantedWebUsbPrinters() async {
  final usb = navigatorUsb;
  if (usb == null) return const [];
  final devices = (await usb.getDevices().toDart).toDart;
  final seen = <String, int>{};
  return [
    for (final d in devices)
      () {
        final key = '${d.vendorId}:${d.productId}';
        final serial = d.serialNumber;
        final twin = serial == null || serial.isEmpty ? (seen[key] ?? 0) : 0;
        if (serial == null || serial.isEmpty) seen[key] = twin + 1;
        return (d, webUsbPrinter(d, twin));
      }(),
  ];
}

/// Where to write on a device: the printer interface and its bulk OUT endpoint.
typedef _Target = ({int interface, int alternate, int endpoint});

_Target? _findTarget(UsbDevice device) {
  final configuration = device.configuration ?? device.configurations.toDart.firstOrNull;
  if (configuration == null) return null;
  _Target? fallback;
  for (final iface in configuration.interfaces.toDart) {
    for (final alt in iface.alternates.toDart) {
      for (final ep in alt.endpoints.toDart) {
        if (ep.direction != 'out' || ep.type != 'bulk') continue;
        final target = (
          interface: iface.interfaceNumber,
          alternate: alt.alternateSetting,
          endpoint: ep.endpointNumber,
        );
        if (alt.interfaceClass == _printerClass) return target;
        // A vendor-specific interface, for printers the user picked by hand.
        fallback ??= target;
      }
    }
  }
  return fallback;
}

/// Chromium browsers on macOS, ChromeOS and Linux: straight to the printer
/// through WebUSB. No install, but the user picks the printer once in the
/// browser's chooser ([PrinterUsbManager.requestPrinter]).
class WebUsbTransport implements PrinterTransport {
  WebUsbTransport(this._printer, this._options);

  UsbPrinter _printer;
  final UsbWriteOptions _options;
  UsbDevice? _device;
  _Target? _target;

  @override
  UsbPrinter get printer => _printer;

  @override
  bool get isConnected => _device != null;

  @override
  Future<void> connect(Duration timeout) async {
    if (_device != null) return;
    final granted = await grantedWebUsbPrinters();
    final match = _printer.findIn([for (final g in granted) g.$2]);
    if (match == null) {
      // The browser forgets printers without a serial number once the page
      // or the printer restarts, so the user has to pick it again.
      throw const PrinterTransportException(
        PosPrintResult.printerAccessRequired,
        UsbPlatformError('notFound', 'This page may not use the printer, or it is unplugged'),
      );
    }
    final device = granted.firstWhere((g) => g.$2 == match).$1;
    try {
      if (!device.opened) await device.open().toDart.timeout(timeout);
      if (device.configuration == null) {
        final first = device.configurations.toDart.firstOrNull;
        if (first != null) await device.selectConfiguration(first.configurationValue).toDart;
      }
      final target = _findTarget(device);
      if (target == null) {
        throw const PrinterTransportException(
          PosPrintResult.unsupported,
          UsbPlatformError('unsupported', 'The device has no printer interface'),
        );
      }
      await device.claimInterface(target.interface).toDart.timeout(timeout);
      if (target.alternate != 0) {
        await device.selectAlternateInterface(target.interface, target.alternate).toDart;
      }
      _device = device;
      _target = target;
      if (match.id != _printer.id) _printer = _printer.copyWith(id: match.id);
    } on PrinterTransportException {
      await _close(device);
      rethrow;
    } on TimeoutException catch (e) {
      await _close(device);
      throw PrinterTransportException(PosPrintResult.timeout, e);
    } catch (e) {
      await _close(device);
      throw PrinterTransportException(_openFailure(e), e);
    }
  }

  /// Why opening or claiming failed.
  static PosPrintResult _openFailure(Object e) {
    if (isDomError(e, 'SecurityError')) return PosPrintResult.permissionDenied;
    if (isDomError(e, 'NotFoundError')) return PosPrintResult.printerNotFound;
    // "Access denied" (open) or "Unable to claim interface": the system's own
    // printer driver holds the printer. On Windows (usbprint.sys) and Linux
    // (usblp) that is always so, and the Local TCP bridge prints instead; on
    // macOS it means the system print queue is printing on it right now.
    if (isDomError(e, 'NetworkError') || isDomError(e, 'InvalidStateError')) {
      return switch (browserOs) {
        BrowserOs.windows || BrowserOs.linux => PosPrintResult.bridgeRequired,
        _ => PosPrintResult.printerBusy,
      };
    }
    return PosPrintResult.connectionFailed;
  }

  @override
  Future<void> write(Uint8List data) async {
    final device = _device;
    final target = _target;
    if (device == null || target == null) {
      throw const PrinterTransportException(PosPrintResult.printerNotConnected);
    }
    var offset = 0;
    try {
      while (offset < data.length) {
        final end = math.min(offset + _options.chunkSize, data.length);
        // transferOut resolves once the printer has taken the bytes: USB flow
        // control does the pacing.
        final result = await device
            .transferOut(target.endpoint, Uint8List.sublistView(data, offset, end).toJS)
            .toDart
            .timeout(_options.stallTimeout);
        if (result.status == 'stall') {
          try {
            await device.clearHalt('out', target.endpoint).toDart;
          } catch (_) {}
          throw const PrinterTransportException(
            PosPrintResult.writeFailed,
            UsbPlatformError('ioError', 'The printer stopped the transfer (endpoint stall)'),
          );
        }
        if (result.bytesWritten <= 0) {
          throw const PrinterTransportException(
            PosPrintResult.writeFailed,
            UsbPlatformError('ioError', 'The printer accepted no data'),
          );
        }
        offset += result.bytesWritten;
      }
    } on PrinterTransportException {
      rethrow;
    } on TimeoutException catch (e) {
      // Closing the device cancels the transfer still waiting on the printer.
      await disconnect();
      throw PrinterTransportException(PosPrintResult.timeout, e);
    } catch (e) {
      await disconnect();
      throw PrinterTransportException(
        isDomError(e, 'NotFoundError')
            ? PosPrintResult.printerNotFound
            : PosPrintResult.writeFailed,
        e,
      );
    }
  }

  @override
  Future<void> disconnect() async {
    final device = _device;
    final target = _target;
    _device = null;
    _target = null;
    if (device == null) return;
    if (target != null) {
      try {
        await device.releaseInterface(target.interface).toDart.timeout(const Duration(seconds: 3));
      } catch (_) {}
    }
    await _close(device);
  }

  static Future<void> _close(UsbDevice device) async {
    try {
      if (device.opened) await device.close().toDart.timeout(const Duration(seconds: 3));
    } catch (_) {
      // Already closed, or the device went away.
    }
  }
}
