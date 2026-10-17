import 'dart:js_interop';

import '../enums.dart';
import '../models/usb_bridge_info.dart';
import '../models/usb_capabilities.dart';
import '../models/usb_printer.dart';
import '../models/usb_printer_note.dart';
import '../models/usb_write_options.dart';
import '../transport/printer_transport.dart';
import '../transport/web/bridge.dart';
import '../transport/web/bridge_protocol.dart';
import '../transport/web/web_env.dart';
import '../transport/web/webusb_bindings.dart';
import '../transport/web/webusb_transport.dart';
import '../utils/printer_identity.dart';
import 'usb_platform.dart';

/// Chromium browsers (Chrome, Edge, Opera, Brave). Two routes, picked by the
/// system the browser runs on:
/// - macOS and ChromeOS: WebUSB opens USB printers directly, no install. The
///   user picks the printer once in the browser's chooser.
/// - Windows and Linux: the system's own printer driver holds USB printers, so
///   WebUSB can't open them; the Local TCP bridge prints instead, and lists
///   the printers without a chooser.
/// The bridge is used on macOS too when it is installed. Firefox and Safari
/// have no WebUSB and need the bridge.
class WebUsbPlatform implements UsbPlatform {
  WebUsbPlatform._();

  static final WebUsbPlatform instance = WebUsbPlatform._();

  final BrowserOs _os = browserOs;
  final LocalTcpBridge _bridge = LocalTcpBridge.instance;

  bool get _hasWebUsb => navigatorUsb != null;

  /// Whether WebUSB can open printers here. Windows' usbprint.sys refuses it.
  bool get _webUsbWorks => _hasWebUsb && _os != BrowserOs.windows && _os != BrowserOs.android;

  /// Whether this system needs the bridge for USB printers.
  bool get _needsBridge => _os == BrowserOs.windows || _os == BrowserOs.linux || !_hasWebUsb;

  @override
  UsbCapabilities get capabilities =>
      UsbCapabilities(list: true, chooser: _webUsbWorks, bridge: true, queues: true);

  @override
  Future<UsbBridgeInfo> checkBridge() => _bridge.check();

  @override
  Future<UsbPrinterListing> listPrinters({required bool includeVirtual}) async {
    final notes = <UsbPrinterNote>[];
    final info = await _bridge.check();
    var bridged = const <UsbPrinter>[];
    if (info.isReady) {
      final listed = await _bridge.list(includeVirtual: includeVirtual);
      bridged = listed.printers;
      notes.addAll(listed.notes);
    } else if (_needsBridge || info.status == UsbBridgeStatus.outdated) {
      notes.add(bridgeNote(info.status));
    }

    var granted = const <UsbPrinter>[];
    if (_webUsbWorks) {
      try {
        granted = [for (final g in await grantedWebUsbPrinters()) g.$2];
      } catch (_) {
        // WebUSB blocked by a permissions policy: the bridge still lists.
      }
    } else if (!_hasWebUsb && !info.isReady) {
      notes.add(
        const UsbPrinterNote(
          code: 'webUsbUnavailable',
          message:
              'This browser cannot reach USB printers. Use Chrome or Edge, or install the '
              'Local TCP extension.',
        ),
      );
    } else if (_os == BrowserOs.windows && !info.isReady) {
      notes.add(
        const UsbPrinterNote(
          code: 'webUsbBlocked',
          message:
              'Windows keeps USB printers for its own printer driver, so the browser cannot open '
              'them. The Local TCP extension prints on them instead.',
        ),
      );
    }

    // One printer can show up both ways. On Linux the system driver holds it,
    // so the bridge copy works; elsewhere WebUSB is the faster, direct path.
    bool same(UsbPrinter a, UsbPrinter b) =>
        a.isDevice &&
        b.isDevice &&
        a.vendorId != null &&
        a.vendorId == b.vendorId &&
        a.productId == b.productId &&
        a.serialNumber != null &&
        a.serialNumber == b.serialNumber;
    final preferBridge = _os == BrowserOs.linux;
    final printers = [
      for (final g in granted)
        if (!preferBridge || !bridged.any((b) => same(b, g))) g,
      for (final b in bridged)
        if (preferBridge || !granted.any((g) => same(g, b))) b,
    ];
    return (printers: sortReceiptFirst(printers), notes: notes);
  }

  @override
  Future<UsbPrinter?> requestPrinter() async {
    final usb = navigatorUsb;
    if (usb == null) {
      throw const PrinterTransportException(
        PosPrintResult.bridgeRequired,
        UsbPlatformError('webUsbUnavailable', 'This browser has no WebUSB'),
      );
    }
    if (!_webUsbWorks) {
      throw const PrinterTransportException(
        PosPrintResult.bridgeRequired,
        UsbPlatformError('webUsbBlocked', 'Windows keeps USB printers from the browser'),
      );
    }
    final UsbDevice device;
    try {
      device = await usb
          .requestDevice(UsbDeviceRequestOptions(filters: [UsbDeviceFilter(classCode: 7)].toJS))
          .toDart;
    } catch (e) {
      if (isDomError(e, 'NotFoundError')) return null; // Chooser closed.
      if (isDomError(e, 'SecurityError')) {
        throw PrinterTransportException(PosPrintResult.permissionDenied, e);
      }
      rethrow;
    }
    // Listed again to number identical printers without serial numbers the
    // same way every time.
    for (final (d, printer) in await grantedWebUsbPrinters()) {
      if ((d as JSAny).strictEquals(device).toDart) return printer;
    }
    return webUsbPrinter(device, 0);
  }

  @override
  PrinterTransport createTransport(UsbPrinter printer, UsbWriteOptions options) {
    return switch (printer.route) {
      UsbPrinterRoute.bridge => BridgeUsbTransport(printer, options),
      UsbPrinterRoute.webUsb => WebUsbTransport(printer, options),
      _ => UnsupportedTransport(
        printer,
        'This printer was set up in an app. Choose a printer in this browser.',
      ),
    };
  }
}

UsbPlatform createUsbPlatform() => WebUsbPlatform.instance;
