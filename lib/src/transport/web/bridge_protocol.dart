// The Local TCP bridge's USB protocol, as plain Dart: what its replies mean.
// Kept apart from the postMessage code so it can be tested off the web.

import 'dart:math' as math;

import '../../enums.dart';
import '../../models/usb_printer.dart';
import '../../models/usb_printer_note.dart';
import '../printer_transport.dart';

/// Prefix of the ids of printers reached through the bridge.
const bridgeIdPrefix = 'bridge:';

/// What to tell the user when the bridge is not [UsbBridgeStatus.ready].
UsbPrinterNote bridgeNote(UsbBridgeStatus status) => switch (status) {
  UsbBridgeStatus.notInstalled => const UsbPrinterNote(
    code: 'bridgeNotInstalled',
    message:
        'USB printing in this browser needs the Local TCP extension. Install it from the '
        'Chrome Web Store, then run the installer it offers.',
  ),
  UsbBridgeStatus.notLinked => const UsbPrinterNote(
    code: 'bridgeNotLinked',
    message:
        'The Local TCP extension is installed, but its bridge is not. Open the extension and '
        'run the installer it offers.',
  ),
  UsbBridgeStatus.outdated => const UsbPrinterNote(
    code: 'bridgeOutdated',
    message:
        'USB printing needs a newer Local TCP bridge. Open the extension, download the Setup '
        'Kit and run the installer again.',
  ),
  _ => const UsbPrinterNote(
    code: 'bridgeReady',
    message: 'The Local TCP bridge is ready.',
    isWarning: false,
  ),
};

/// A printer from the bridge's USB_LIST reply.
UsbPrinter bridgePrinterFromJson(Map<String, Object?> p) {
  int? number(Object? v) => v is num ? v.toInt() : null;
  String? text(Object? v) => v is String && v.isNotEmpty ? v : null;
  final device = text(p['devicePrinterId']);
  return UsbPrinter(
    id: '$bridgeIdPrefix${p['id']}',
    kind: p['kind'] == 'queue' ? UsbPrinterKind.queue : UsbPrinterKind.device,
    name: text(p['name']),
    manufacturer: text(p['manufacturer']),
    model: text(p['model']),
    vendorId: number(p['vendorId']),
    productId: number(p['productId']),
    serialNumber: text(p['serialNumber']),
    category: UsbPrinterCategory.values.firstWhere(
      (c) => c.name == p['category'],
      orElse: () => UsbPrinterCategory.unknown,
    ),
    paperWidthMm: number(p['paperWidthMm']),
    commandSet: text(p['commandSet']),
    port: text(p['port']),
    queueStatus: p['kind'] == 'queue'
        ? UsbQueueStatus.values.firstWhere(
            (s) => s.name == p['status'],
            orElse: () => UsbQueueStatus.unknown,
          )
        : null,
    devicePrinterId: device == null ? null : '$bridgeIdPrefix$device',
    isDefault: p['isDefault'] == true,
    isAccessible: p['accessible'] != false,
    isBusy: p['busy'] == true,
  );
}

/// The result for a failed bridge reply.
PosPrintResult bridgeFailure(Map<String, Object?>? res) {
  if (res == null) return PosPrintResult.bridgeRequired;
  final code = res['code'];
  if (code is String) return resultForCode(code);
  final error = '${res['error'] ?? ''}';
  if (error.contains('Origin not allowed')) return PosPrintResult.permissionDenied;
  if (error.contains('Bridge timeout')) return PosPrintResult.timeout;
  if (error.contains('Bridge not available') || error.contains('Bridge disconnected')) {
    return PosPrintResult.bridgeRequired;
  }
  return PosPrintResult.writeFailed;
}

/// How long the host may take for a job of [bytes]: the stall timeout plus a
/// millisecond a byte (1 kB/s, far below any receipt printer), within the
/// host's 3 s to 120 s range. Unlike the native transports, the host times the
/// whole job, not each piece.
int bridgeBudgetMs(int stallMs, int bytes) => math.max(3000, math.min(120000, stallMs + bytes));
