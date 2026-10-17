import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_esc_pos_usb_universal/flutter_esc_pos_usb_universal.dart';
import 'package:flutter_esc_pos_usb_universal/src/raster/column_image.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'helpers/escpos_decode.dart';

/// White pixels, with the given (x, y) dots black.
Uint8List _picture(int width, int height, Iterable<(int, int)> black) {
  final rgba = Uint8List(width * height * 4)..fillRange(0, width * height * 4, 255);
  for (final (x, y) in black) {
    final o = (y * width + x) * 4;
    rgba[o] = rgba[o + 1] = rgba[o + 2] = 0;
  }
  return rgba;
}

Uint8List _randomRgba(Random random, int width, int height) {
  final rgba = Uint8List(width * height * 4);
  for (var i = 0; i < rgba.length; i += 4) {
    // Mostly black and white with grey edges, like rendered text, plus noise
    // around the 127/128 threshold.
    final v = switch (random.nextInt(4)) {
      0 => 0,
      1 => 255,
      2 => 120 + random.nextInt(16),
      _ => random.nextInt(256),
    };
    rgba[i] = v;
    rgba[i + 1] = v;
    rgba[i + 2] = v;
    rgba[i + 3] = 255;
  }
  return rgba;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('column bands print exactly the dots Generator.image prints', () async {
    final profile = await CapabilityProfile.load();
    final random = Random(7);
    const head = 384;
    for (final (width, height) in [(384, 24), (300, 50), (17, 1), (384, 97)]) {
      final rgba = _randomRgba(random, width, height);
      final reference = Generator(PaperSize.mm58, profile).image(
        img.Image.fromBytes(width: width, height: height, bytes: rgba.buffer, numChannels: 4),
      );
      // Scrubbing off: Generator.image prints every dot.
      final ours = [
        0x1b, 0x61, 0x30, // ESC a 0: left, as the ticket builder sends
        ...columnImageBands(
          rgba,
          width,
          height,
          leftPad: (head - width) ~/ 2,
          scrubRealTime: false,
        ),
      ];
      final a = decodePaper(ours, headWidth: head);
      final b = decodePaper(reference, headWidth: head);
      expect(a.sameAs(b), isTrue, reason: '${width}x$height: ${a.diff(b)}');
    }
  });

  test('bands touch: zero line spacing around them, default after', () {
    final bytes = columnImageBands(_picture(8, 30, [(0, 0), (7, 29)]), 8, 30);
    expect(bytes.sublist(0, 3), [0x1b, 0x33, 0]);
    expect(bytes.sublist(bytes.length - 2), [0x1b, 0x32]);
  });

  test('drops the dot that would spell a real-time command', () {
    bool hasDleEot(List<int> b) {
      for (var i = 0; i + 1 < b.length; i++) {
        if (b[i] == 0x10 && b[i + 1] == 0x04) return true;
      }
      return false;
    }

    // One column: row 3 makes the first byte 0x10 and row 13 the second 0x04,
    // which together spell DLE EOT.
    final rgba = _picture(1, 24, [(0, 3), (0, 13)]);
    final raw = columnImageBands(rgba, 1, 24, scrubRealTime: false);
    final safe = columnImageBands(rgba, 1, 24);
    expect(hasDleEot(raw), isTrue);
    expect(hasDleEot(safe), isFalse);
    expect(safe.length, raw.length);
  });
}
