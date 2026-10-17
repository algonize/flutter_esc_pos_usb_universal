// The Local TCP bridge: a Chrome extension and a small native host
// (https://github.com/algoramming/local_tcp) that print on the computer's USB
// printers for a web page. Windows and Linux keep USB printers for their own
// printer drivers, so a browser can't open them with WebUSB there; the bridge's
// host writes to them the way an app would, and to installed printers too.
//
// The page talks to the extension with window.postMessage, the same channel
// flutter_esc_pos_network_universal uses for Wi-Fi printers:
//   CHECK_BRIDGE → { success, connected, version, features: ['tcp','usb'], ... }
//   USB_LIST     → { success, platform, printers: [...], notes: [...] }
//   USB_PRINT    → { success, printerId, resolvedPrinterId?, bytesSent }
// Failures carry a stable `code` (notFound, busy, permissionDenied, timeout,
// ioError, ..., noPrinter, bridgeOutdated) next to `error`.

import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import '../../enums.dart';
import '../../models/usb_bridge_info.dart';
import '../../models/usb_printer.dart';
import '../../models/usb_printer_note.dart';
import '../../models/usb_write_options.dart';
import '../printer_transport.dart';
import 'bridge_protocol.dart';

/// How long the extension has to answer CHECK_BRIDGE. No answer at all means
/// it is not installed (or disabled for this site).
const _checkTimeout = Duration(seconds: 3);

/// Above the extension's own 75 s budget for USB_LIST, so its specific error
/// reaches the page rather than this timeout.
const _listTimeout = Duration(seconds: 80);

/// The extension allows the write budget plus 60 s for USB_PRINT (the Windows
/// helper may have to start first); this stays above that.
const _printAllowance = Duration(seconds: 65);

/// Request/response over window.postMessage, correlated by message id.
class LocalTcpBridge {
  LocalTcpBridge._();

  static final LocalTcpBridge instance = LocalTcpBridge._();

  StreamSubscription<web.MessageEvent>? _subscription;
  final Map<String, Completer<Map<String, Object?>>> _pending = {};
  int _counter = 0;

  /// Sends [payload] and waits for the reply. Null when the extension did
  /// not answer within [timeout].
  Future<Map<String, Object?>?> request(Map<String, Object?> payload, Duration timeout) async {
    _subscription ??= web.EventStreamProviders.messageEvent
        .forTarget(web.window)
        .listen(_onMessage);
    final id = 'usb_${DateTime.now().microsecondsSinceEpoch}_${++_counter}';
    final completer = Completer<Map<String, Object?>>();
    _pending[id] = completer;
    final origin = web.window.location.origin;
    web.window.postMessage(
      {'source': 'localtcp_req', 'messageId': id, ...payload}.jsify(),
      (origin.isEmpty || origin == 'null' ? '*' : origin).toJS,
    );
    try {
      return await completer.future.timeout(timeout);
    } on TimeoutException {
      return null;
    } finally {
      _pending.remove(id);
    }
  }

  void _onMessage(web.MessageEvent event) {
    final Object? data;
    try {
      data = event.data.dartify();
    } catch (_) {
      return;
    }
    if (data is! Map || data['source'] != 'localtcp_res') return;
    final completer = _pending.remove(data['messageId']);
    if (completer == null || completer.isCompleted) return;
    final response = data['response'];
    completer.complete(
      response is Map
          ? {for (final e in response.entries) '${e.key}': e.value}
          : {'success': false, 'error': 'The Local TCP extension sent an unexpected reply.'},
    );
  }

  /// Whether the bridge is installed, running and able to print on USB.
  Future<UsbBridgeInfo> check() async {
    final res = await request({'action': 'CHECK_BRIDGE'}, _checkTimeout);
    if (res == null) return const UsbBridgeInfo(status: UsbBridgeStatus.notInstalled);
    final features = res['features'];
    final linked = res['success'] == true && res['connected'] == true;
    final status = !linked
        ? UsbBridgeStatus.notLinked
        : features is List && features.contains('usb')
        ? UsbBridgeStatus.ready
        : UsbBridgeStatus.outdated;
    return UsbBridgeInfo(
      status: status,
      hostVersion: res['version'] as String?,
      extensionVersion: res['extensionVersion'] as String?,
      platform: res['platform'] as String?,
      error: res['error'] as String?,
    );
  }

  /// The printers the bridge's host finds on this computer.
  Future<({List<UsbPrinter> printers, List<UsbPrinterNote> notes})> list({
    required bool includeVirtual,
  }) async {
    final res = await request({
      'action': 'USB_LIST',
      'includeVirtual': includeVirtual,
    }, _listTimeout);
    if (res == null) {
      return (printers: const <UsbPrinter>[], notes: [bridgeNote(UsbBridgeStatus.notInstalled)]);
    }
    if (res['success'] != true) {
      final code = res['code'] as String? ?? 'ioError';
      return (
        printers: const <UsbPrinter>[],
        notes: [
          code == 'bridgeOutdated'
              ? bridgeNote(UsbBridgeStatus.outdated)
              : UsbPrinterNote(
                  code: code,
                  message: '${res['error'] ?? 'The bridge could not list printers.'}',
                ),
        ],
      );
    }
    final printers = [
      for (final p in (res['printers'] as List? ?? const []))
        if (p is Map) bridgePrinterFromJson({for (final e in p.entries) '${e.key}': e.value}),
    ];
    final notes = [
      for (final n in (res['notes'] as List? ?? const []))
        if (n is Map && n['message'] is String)
          UsbPrinterNote(
            code: '${n['code'] ?? 'note'}',
            message: n['message'] as String,
            isWarning: n['level'] != 'info',
          ),
    ];
    return (printers: printers, notes: notes);
  }
}

/// Chromium browsers on Windows and Linux (and any other, when the user picks
/// a bridge printer): printing through the Local TCP bridge. One ticket is one
/// job, which the host serialises per printer.
class BridgeUsbTransport implements PrinterTransport {
  BridgeUsbTransport(this._printer, this._options, {LocalTcpBridge? bridge})
    : _bridge = bridge ?? LocalTcpBridge.instance;

  UsbPrinter _printer;
  final UsbWriteOptions _options;
  final LocalTcpBridge _bridge;
  bool _connected = false;

  @override
  UsbPrinter get printer => _printer;

  @override
  bool get isConnected => _connected;

  @override
  Future<void> connect(Duration timeout) async {
    if (_connected) return;
    // Nothing to open: every job is a self-contained USB_PRINT. Checking the
    // bridge first gives a clear error before a receipt is rendered.
    final info = await _bridge.check();
    if (!info.isReady) {
      throw PrinterTransportException(
        info.status == UsbBridgeStatus.outdated
            ? PosPrintResult.bridgeOutdated
            : PosPrintResult.bridgeRequired,
        UsbPlatformError(info.status.name, bridgeNote(info.status).message, detail: info.error),
      );
    }
    _connected = true;
  }

  @override
  Future<void> write(Uint8List data) async {
    if (!_connected) throw const PrinterTransportException(PosPrintResult.printerNotConnected);
    final p = _printer;
    final budgetMs = bridgeBudgetMs(_options.stallTimeout.inMilliseconds, data.length);
    final res = await _bridge.request({
      'action': 'USB_PRINT',
      'printerId': p.id.substring(bridgeIdPrefix.length),
      if (p.isDevice && p.vendorId != null && p.productId != null)
        'match': {
          'vendorId': p.vendorId,
          'productId': p.productId,
          if (p.serialNumber != null) 'serialNumber': p.serialNumber,
        },
      'dataB64': base64Encode(data),
      'timeoutMs': budgetMs,
      'jobName': _options.jobName,
    }, Duration(milliseconds: budgetMs) + _printAllowance);
    if (res != null && res['success'] == true) {
      final resolved = res['resolvedPrinterId'];
      if (resolved is String && resolved.isNotEmpty) {
        _printer = _printer.copyWith(id: '$bridgeIdPrefix$resolved');
      }
      return;
    }
    throw PrinterTransportException(
      bridgeFailure(res),
      UsbPlatformError(
        '${res?['code'] ?? (res == null ? 'noResponse' : 'ioError')}',
        '${res?['error'] ?? 'The Local TCP extension did not answer.'}',
        detail: res?['detail'] as String?,
      ),
    );
  }

  @override
  Future<void> disconnect() async {
    _connected = false;
  }
}
