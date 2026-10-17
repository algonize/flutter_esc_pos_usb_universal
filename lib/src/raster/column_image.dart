import 'dart:typed_data';

/// Dots per `ESC *` band at double density ("ESC * 33").
const int _bandHeight = 24;

/// The `ESC *` column bands that flutter_esc_pos_utils' `Generator.image`
/// prints, and so what `flutter_esc_pos_network_universal` and
/// `flutter_esc_pos_bluetooth_universal` send, for an 8-bit RGBA picture: the
/// same dots in the same places, in fewer bytes.
///
/// The bands are bracketed by `ESC 3 0` and `ESC 2`. With the line spacing at
/// zero, the line feed after each band moves the paper exactly the band's 24
/// rows, so the bands butt together with no white line between them, however
/// long the printer pauses between two of them.
///
/// Each band holds 3 bytes per pixel column, the topmost dot in the high bit,
/// and a dot is printed where the pixel is darker than mid grey. One blank
/// band always follows the picture, as with `Generator.image`. Each band stops
/// at its last printed column ([trim]) and a blank band keeps one column, so
/// the paper still moves a band's height; such bands are meant for left
/// alignment, and [leftPad] blank columns in front of every band put a picture
/// narrower than the head where centring would have put it.
///
/// Bytes that spell an ESC/POS real-time command (DLE EOT, DLE ENQ, DLE DC4)
/// are not allowed in the image data, because printers execute them even
/// inside another command's data, which at best transmits a status and at
/// worst clears the buffer and prints the rest of the picture as text. Where
/// a byte 0x10 is followed by 0x04, 0x05 or 0x14, that single dot is dropped
/// ([scrubRealTime]); nothing visible changes.
Uint8List columnImageBands(
  Uint8List rgba,
  int width,
  int height, {
  int leftPad = 0,
  bool trim = true,
  bool scrubRealTime = true,
}) {
  assert(rgba.length >= width * height * 4);
  assert(leftPad >= 0);
  final dots = _darkDots(rgba, width * height);
  final columns = leftPad + width;

  // Rounded up to whole bands, plus the extra band Generator.image adds when
  // the height is already a whole number of bands.
  final bands = height ~/ _bandHeight + 1;
  final out = BytesBuilder(copy: false);
  // Reused from band to band: the first leftPad * 3 bytes are never written
  // and stay blank, the rest is rewritten every time.
  final data = Uint8List(columns * 3);

  // ESC 3 0: no extra line spacing, so the bands touch.
  out.add(const [0x1b, 0x33, 0]);
  for (var band = 0; band < bands; band++) {
    final top = band * _bandHeight;
    var last = -1;
    var i = leftPad * 3;
    for (var x = 0; x < width; x++) {
      for (var byte = 0; byte < 3; byte++) {
        var value = 0;
        for (var bit = 0; bit < 8; bit++) {
          final y = top + byte * 8 + bit;
          value <<= 1;
          if (y < height && dots[y * width + x] == 1) value |= 1;
        }
        data[i++] = value;
        if (value != 0) last = leftPad + x;
      }
    }
    final count = trim ? (last < 0 ? 1 : last + 1) : columns;
    final length = count * 3;
    if (scrubRealTime) _scrub(data, length);

    // ESC * 33 nL nH: 24-dot double density, count columns.
    out.add([0x1b, 0x2a, 33, count & 0xff, count >> 8]);
    // A copy: the builder keeps what it is given, and data is reused.
    out.add(Uint8List.fromList(Uint8List.sublistView(data, 0, length)));
    out.addByte(0x0a);
  }
  // ESC 2: default line spacing.
  out.add(const [0x1b, 0x32]);
  return out.takeBytes();
}

/// Drops the dot of a 0x10 byte that is followed by the second byte of a
/// real-time command, inside `data[0..length)`.
void _scrub(Uint8List data, int length) {
  for (var i = 0; i + 1 < length; i++) {
    if (data[i] != 0x10) continue;
    final next = data[i + 1];
    if (next == 0x04 || next == 0x05 || next == 0x14) data[i] = 0;
  }
}

/// Whether each grey level prints, after the image package takes the
/// luminance of the grey once more to keep a single channel. Floating point
/// rounds a few levels down there (128 becomes 127), right at the threshold.
final Uint8List _printsGrey = Uint8List.fromList([
  for (var grey = 0; grey < 256; grey++)
    (0.299 * grey + 0.587 * grey + 0.114 * grey).toInt() > 127 ? 1 : 0,
]);

/// 1 for every pixel printed as a dot, in row order.
///
/// Matches the image package, as `Generator.image` uses it: the colour is
/// inverted, flattened onto black (its alpha blend), turned grey with
/// 0.299 R + 0.587 G + 0.114 B truncated to an integer, then reduced to one
/// channel (see [_printsGrey]).
Uint8List _darkDots(Uint8List rgba, int pixels) {
  final dots = Uint8List(pixels);
  for (var p = 0, o = 0; p < pixels; p++, o += 4) {
    var r = 255 - rgba[o];
    var g = 255 - rgba[o + 1];
    var b = 255 - rgba[o + 2];
    final a = rgba[o + 3];
    if (a != 255) {
      r = r * a ~/ 255;
      g = g * a ~/ 255;
      b = b * a ~/ 255;
    }
    dots[p] = _printsGrey[(0.299 * r + 0.587 * g + 0.114 * b).toInt()];
  }
  return dots;
}
