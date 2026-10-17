// Runs against a real USB printer on this Mac. Skipped unless USB_LIVE=1;
// USB_LIVE_PRINT=1 also prints a short slip.
@TestOn('mac-os')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_esc_pos_usb_universal/src/models/usb_write_options.dart';
import 'package:flutter_esc_pos_usb_universal/src/transport/io/macos_usb.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final live = Platform.environment['USB_LIVE'] == '1';
  final print = Platform.environment['USB_LIVE_PRINT'] == '1';

  test('lists USB printers through IOKit', () async {
    final result = await listMacUsbPrinters();
    for (final p in result.printers) {
      // ignore: avoid_print
      stdout.writeln(
        '$p ${p.category} ${p.commandSet} vid=${p.vendorId} pid=${p.productId} sn=${p.serialNumber} busy=${p.isBusy}',
      );
    }
    expect(result.printers, isNotEmpty);
  }, skip: !live);

  test('prints a short slip', () async {
    final printers = (await listMacUsbPrinters()).printers;
    final transport = MacUsbTransport(printers.first, const UsbWriteOptions());
    await transport.connect(const Duration(seconds: 5));
    final watch = Stopwatch()..start();
    await transport.write(
      Uint8List.fromList(
        'Dart FFI IOKit test\nflutter_esc_pos_usb_universal\n\n\n\n'.codeUnits +
            [0x1d, 0x56, 0x42, 0x00],
      ),
    );
    stdout.writeln('written in ${watch.elapsedMilliseconds} ms');
    await transport.disconnect();
    // Opens again right away: the interface was released.
    await transport.connect(const Duration(seconds: 5));
    await transport.disconnect();
  }, skip: !(live && print));
}
