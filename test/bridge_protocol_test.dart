import 'package:flutter_esc_pos_usb_universal/flutter_esc_pos_usb_universal.dart';
import 'package:flutter_esc_pos_usb_universal/src/transport/web/bridge_protocol.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('reads a USB_LIST device (numbers arrive as doubles from the browser)', () {
    final p = bridgePrinterFromJson({
      'id':
          r'win-usb:\\?\usb#vid_1fc9&pid_2016#716D086D3537#{28d78fad-5a12-11d1-ae5b-0000f803a8c2}',
      'kind': 'device',
      'connection': 'usb',
      'name': 'Printer POS-80',
      'manufacturer': 'Printer',
      'model': 'POS-80',
      'commandSet': 'ESC/POS',
      'vendorId': 8137.0,
      'productId': 8214.0,
      'serialNumber': '716D086D3537',
      'port': 'USB001',
      'queues': ['POS-80'],
      'busy': false,
      'category': 'receipt',
      'paperWidthMm': 80.0,
    });
    expect(p.id, startsWith('bridge:win-usb:'));
    expect(p.route, UsbPrinterRoute.bridge);
    expect(p.isDevice, isTrue);
    expect(p.vendorId, 0x1fc9);
    expect(p.paperWidthMm, 80);
    expect(p.category, UsbPrinterCategory.receipt);
    expect(p.queueStatus, isNull);
    expect(p.isAccessible, isTrue);
  });

  test('reads a USB_LIST queue', () {
    final p = bridgePrinterFromJson({
      'id': 'cups:POS_80',
      'kind': 'queue',
      'connection': 'usb',
      'name': 'POS 80',
      'status': 'paperOut',
      'isDefault': true,
      'devicePrinterId': 'linux-usb:1fc9:2016:sn=716D086D3537',
      'category': 'unknown',
    });
    expect(p.isQueue, isTrue);
    expect(p.queueStatus, UsbQueueStatus.paperOut);
    expect(p.isDefault, isTrue);
    expect(p.devicePrinterId, 'bridge:linux-usb:1fc9:2016:sn=716D086D3537');
    final unknown = bridgePrinterFromJson({'id': 'cups:X', 'kind': 'queue', 'status': 'new-state'});
    expect(unknown.queueStatus, UsbQueueStatus.unknown);
    final locked = bridgePrinterFromJson({'id': 'linux-usb:lp0', 'accessible': false});
    expect(locked.isAccessible, isFalse);
  });

  test('failures map to results', () {
    expect(bridgeFailure(null), PosPrintResult.bridgeRequired);
    expect(bridgeFailure({'success': false, 'code': 'busy'}), PosPrintResult.printerBusy);
    expect(bridgeFailure({'success': false, 'code': 'notFound'}), PosPrintResult.printerNotFound);
    expect(
      bridgeFailure({'success': false, 'code': 'bridgeOutdated'}),
      PosPrintResult.bridgeOutdated,
    );
    expect(
      bridgeFailure({'success': false, 'code': 'noPrinter'}),
      PosPrintResult.printerNotSelected,
    );
    expect(
      bridgeFailure({'success': false, 'error': 'Origin not allowed. Add this origin ...'}),
      PosPrintResult.permissionDenied,
    );
    expect(
      bridgeFailure({
        'success': false,
        'error': 'Bridge not available. Please install the native host.',
      }),
      PosPrintResult.bridgeRequired,
    );
    expect(
      bridgeFailure({'success': false, 'error': 'Bridge timeout: no response within 80000ms'}),
      PosPrintResult.timeout,
    );
  });

  test('job budget stays within the host limits', () {
    expect(bridgeBudgetMs(10000, 50000), 60000);
    expect(bridgeBudgetMs(0, 10), 3000);
    expect(bridgeBudgetMs(10000, 5000000), 120000);
  });

  test('every bridge status but ready has a note to show', () {
    for (final s in [
      UsbBridgeStatus.notInstalled,
      UsbBridgeStatus.notLinked,
      UsbBridgeStatus.outdated,
    ]) {
      final note = bridgeNote(s);
      expect(note.isWarning, isTrue);
      expect(note.message, contains('Local TCP'));
    }
  });
}
