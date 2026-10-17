import 'package:flutter/material.dart';
import 'package:flutter_esc_pos_usb_universal/flutter_esc_pos_usb_universal.dart';
import 'package:flutter_esc_pos_usb_universal/src/raster/widget_raster.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:screenshot/screenshot.dart';

import 'helpers/escpos_decode.dart';

const _receipt = Padding(
  padding: EdgeInsets.all(8),
  child: Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      Text('ALGORAMMING CAFE', style: TextStyle(color: Colors.black, fontSize: 30)),
      Divider(color: Colors.black),
      Row(
        children: [
          Expanded(
            child: Text('Latte', style: TextStyle(color: Colors.black, fontSize: 22)),
          ),
          Text('4.20', style: TextStyle(color: Colors.black, fontSize: 22)),
        ],
      ),
      SizedBox(height: 8),
      ColoredBox(color: Color(0xFF7F7F7F), child: SizedBox(width: 120, height: 30)),
    ],
  ),
);

// One capturing test per file: a second one in the same file stalls the test
// renderer (as in flutter_esc_pos_bluetooth_universal).

void main() {
  testWidgets('a widget prints the dots the network package prints, in fewer bytes', (
    tester,
  ) async {
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
    final profile = await CapabilityProfile.load();

    for (final paperSize in ThermalPosPrinterPageSize.values) {
      final (ours, reference) = (await tester.runAsync(
        () async => (
          await buildWidgetTicket(
            context,
            _receipt,
            paperSize: paperSize,
            profile: profile,
            scrubRealTime: false,
          ),
          await () async {
            // flutter_esc_pos_network_universal: a PNG capture through Generator.image.
            final png = await ScreenshotController().captureFromLongWidget(
              InheritedTheme.captureAll(
                context,
                const Material(color: Colors.white, child: _receipt),
              ),
              delay: const Duration(milliseconds: 200),
              context: context,
              constraints: BoxConstraints(maxWidth: paperSize.widthPx),
            );
            var image = img.decodeImage(png)!;
            if (image.format != img.Format.uint8) image = image.convert(format: img.Format.uint8);
            final generator = Generator(paperSize.toPaperSize, profile);
            return [...generator.image(image), ...generator.feed(2), ...generator.cut()];
          }(),
        ),
      ))!;
      final head = paperSize.widthPx.toInt();
      expect(ours.length, greaterThan(1000), reason: paperSize.title);
      expect(ours.length, lessThan(reference.length), reason: paperSize.title);
      final a = decodePaper(ours, headWidth: head);
      final b = decodePaper(reference, headWidth: head);
      expect(a.sameAs(b), isTrue, reason: '${paperSize.title}: ${a.diff(b)}');
      // Left alignment first (no ESC @), and a feed and a cut at the end.
      expect(ours.sublist(0, 3), [0x1b, 0x61, 0x30]);
      expect(ours.sublist(ours.length - 3, ours.length - 1), [0x1d, 0x56]);
    }
  });
}
