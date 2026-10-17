import 'package:flutter/material.dart';
import 'package:flutter_esc_pos_usb_universal/flutter_esc_pos_usb_universal.dart';

/// Test tickets, the same as the network package's example.
class UsbPrinterTickets {
  static Future<List<int>> testTicket(
    ThermalPosPrinterPageSize paperSize,
  ) async {
    final profile = await CapabilityProfile.load();
    final generator = Generator(paperSize.toPaperSize, profile);
    List<int> bytes = [];

    bytes += generator.text(
      'Regular: aA bB cC dD eE fF gG hH iI jJ kK lL mM nN oO pP qQ rR sS tT uU vV wW xX yY zZ',
    );
    bytes += generator.text(
      'Special 1: àÀ èÈ éÉ ûÛ üÜ çÇ ôÔ',
      styles: const PosStyles(codeTable: 'CP1252'),
    );
    bytes += generator.text('Bold text', styles: const PosStyles(bold: true));
    bytes += generator.text(
      'Reverse text',
      styles: const PosStyles(reverse: true),
    );
    bytes += generator.text(
      'Underlined text',
      styles: const PosStyles(underline: true),
      linesAfter: 1,
    );
    bytes += generator.text(
      'Align left',
      styles: const PosStyles(align: PosAlign.left),
    );
    bytes += generator.text(
      'Align center',
      styles: const PosStyles(align: PosAlign.center),
    );
    bytes += generator.text(
      'Align right',
      styles: const PosStyles(align: PosAlign.right),
      linesAfter: 1,
    );
    bytes += generator.row([
      PosColumn(
        text: 'col3',
        width: 3,
        styles: const PosStyles(align: PosAlign.center),
      ),
      PosColumn(
        text: 'col6',
        width: 6,
        styles: const PosStyles(align: PosAlign.center),
      ),
      PosColumn(
        text: 'col3',
        width: 3,
        styles: const PosStyles(align: PosAlign.center),
      ),
    ]);
    bytes += generator.text(
      'Text size 200%',
      styles: const PosStyles(
        height: PosTextSize.size2,
        width: PosTextSize.size2,
      ),
    );
    bytes += generator.barcode(Barcode.upcA([1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 4]));
    bytes += generator.feed(2);
    bytes += generator.cut();
    return bytes;
  }
}

/// A receipt to print as an image with `printWidget`.
class TestReceiptWidget extends StatelessWidget {
  const TestReceiptWidget({super.key, required this.paperSize});

  final ThermalPosPrinterPageSize paperSize;

  @override
  Widget build(BuildContext context) {
    const style = TextStyle(color: Colors.black, fontSize: 22);
    return Padding(
      padding: const EdgeInsets.all(8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'USB Receipt Test ${paperSize.title}',
            textAlign: TextAlign.center,
            style: style.copyWith(fontSize: 28, fontWeight: FontWeight.bold),
          ),
          const Divider(color: Colors.black, thickness: 2),
          const Row(
            children: [
              Expanded(child: Text('Latte', style: style)),
              Text('4.20', style: style),
            ],
          ),
          const Row(
            children: [
              Expanded(child: Text('Croissant', style: style)),
              Text('2.80', style: style),
            ],
          ),
          const Divider(color: Colors.black, thickness: 2),
          Row(
            children: [
              Expanded(
                child: Text(
                  'TOTAL',
                  style: style.copyWith(fontWeight: FontWeight.bold),
                ),
              ),
              Text('7.00', style: style.copyWith(fontWeight: FontWeight.bold)),
            ],
          ),
          const SizedBox(height: 12),
          const Text(
            'Printed over USB, no printer driver needed. Thank you!',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.black, fontSize: 18),
          ),
        ],
      ),
    );
  }
}
