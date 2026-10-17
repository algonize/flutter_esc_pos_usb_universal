// Runs inside the real (sandboxed) example app:
//   flutter test integration_test -d macos      (or windows, linux)
// Lists the USB printers and opens the first one without printing, which is
// what a missing entitlement or permission would break.
import 'package:flutter/foundation.dart';
import 'package:flutter_esc_pos_usb_universal/flutter_esc_pos_usb_universal.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('lists USB printers and opens the first one', (tester) async {
    final manager = PrinterUsbManager();
    final printers = await manager.listPrinters();
    for (final p in printers) {
      debugPrint(
        'printer: $p ${p.category.name} ${p.commandSet ?? ''} busy=${p.isBusy}',
      );
    }
    for (final n in manager.notes) {
      debugPrint('note: $n');
    }
    expect(manager.notes.where((n) => n.code == 'listFailed'), isEmpty);
    if (printers.isEmpty) {
      markTestSkipped('No USB printer connected');
      return;
    }
    await manager.selectPrinter(printers.first);
    final result = await manager.connect();
    debugPrint('connect: $result ${manager.lastError ?? ''}');
    expect(result, PosPrintResult.success);
    expect(await manager.disconnect(), PosPrintResult.success);
  });
}
