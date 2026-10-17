import 'package:flutter/material.dart';
import 'package:flutter_esc_pos_usb_universal/flutter_esc_pos_usb_universal.dart';
import 'package:flutter_esc_pos_usb_universal/src/raster/widget_raster.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/escpos_decode.dart';

// In its own file: a second capturing test after another one in the same
// file stalls the test renderer.

const _receipt = Padding(
  padding: EdgeInsets.all(8),
  child: Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      Text('ALGORAMMING CAFE', style: TextStyle(color: Colors.black, fontSize: 30)),
      Divider(color: Colors.black),
      Text('Latte 4.20', style: TextStyle(color: Colors.black, fontSize: 22)),
    ],
  ),
);

void main() {
  testWidgets('gapMm adds blank paper below the receipt', (tester) async {
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
    const paper = ThermalPosPrinterPageSize.size58mm;
    // One capture per async scope: a second capture in the same scope stalls
    // the test renderer.
    final plain = (await tester.runAsync(
      () => buildWidgetTicket(context, _receipt, paperSize: paper, profile: profile),
    ))!;
    final gapped = (await tester.runAsync(
      () => buildWidgetTicket(context, _receipt, paperSize: paper, profile: profile, gapMm: 20),
    ))!;
    final before = decodePaper(plain, headWidth: 384);
    final after = decodePaper(gapped, headWidth: 384);
    // 20 mm is 160 rows: six or seven more bands, all blank.
    expect(after.height - before.height, inInclusiveRange(144, 168));
    for (var y = before.height; y < after.height; y++) {
      expect(after.dotsIn(y), 0, reason: 'row $y of the gap');
    }
    // Blank bands cost next to nothing: 9 bytes each.
    expect(gapped.length - plain.length, lessThan(7 * 9 + 1));
  });
}
