// Prints a widget receipt on a real USB printer through the public API.
// Skipped unless USB_LIVE_PRINT=1. Desktop only.
@TestOn('mac-os || linux || windows')
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_esc_pos_usb_universal/flutter_esc_pos_usb_universal.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final enabled = Platform.environment['USB_LIVE_PRINT'] == '1';

  testWidgets('prints a widget receipt through PrinterUsbManager', (tester) async {
    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (c) {
            context = c;
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    final result = await tester.runAsync(() async {
      final manager = PrinterUsbManager();
      final printers = await manager.listPrinters();
      stdout.writeln('printers: $printers notes: ${manager.notes}');
      await manager.selectPrinter(printers.firstWhere((p) => p.isReceiptPrinter));
      final result = await manager.printWidget(
        context,
        child: const Padding(
          padding: EdgeInsets.all(8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'flutter_esc_pos_usb_universal',
                style: TextStyle(color: Colors.black, fontSize: 26),
              ),
              Divider(color: Colors.black, thickness: 2),
              Text(
                'printWidget over USB (Dart FFI)',
                style: TextStyle(color: Colors.black, fontSize: 22),
              ),
            ],
          ),
        ),
      );
      stdout.writeln('result: $result ${manager.lastPrint} ${manager.lastError ?? ''}');
      return result;
    });
    expect(result, PosPrintResult.success);
  }, skip: !enabled);
}
