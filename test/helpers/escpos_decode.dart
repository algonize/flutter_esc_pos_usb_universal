import 'dart:typed_data';

/// What a printer puts on paper for a stream of ESC * bands: a bitmap
/// [headWidth] dots wide, one byte per dot (1 = printed), 24 rows per band.
///
/// Understands what the tickets under test contain: `ESC a n` alignment,
/// `ESC * 33` bands printed on the line feed that follows, and the style,
/// feed and cut commands `Generator` emits around them, which it skips.
/// A band is placed by the current alignment, as a printer places it.
class DecodedPaper {
  DecodedPaper(this.headWidth, this.rows);

  final int headWidth;

  /// Rows of [headWidth] bytes.
  final List<Uint8List> rows;

  int get height => rows.length;

  int dotsIn(int row) => rows[row].fold(0, (n, d) => n + d);

  /// The last printed column of [row], or -1.
  int lastDot(int row) => rows[row].lastIndexWhere((d) => d == 1);

  bool sameAs(DecodedPaper other) {
    if (other.headWidth != headWidth || other.height != height) return false;
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < headWidth; x++) {
        if (rows[y][x] != other.rows[y][x]) return false;
      }
    }
    return true;
  }

  /// The first row that differs from [other], for test messages.
  String diff(DecodedPaper other) {
    if (other.headWidth != headWidth) return 'head width $headWidth vs ${other.headWidth}';
    if (other.height != height) return 'height $height vs ${other.height}';
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < headWidth; x++) {
        if (rows[y][x] != other.rows[y][x]) {
          return 'row $y column $x: ${rows[y][x]} vs ${other.rows[y][x]}';
        }
      }
    }
    return 'identical';
  }
}

DecodedPaper decodePaper(List<int> bytes, {required int headWidth}) {
  final rows = <Uint8List>[];
  var align = 0; // 0 left, 1 centre, 2 right
  List<Uint8List>? pending; // the band waiting for its line feed
  var i = 0;
  final n = bytes.length;

  void flush() {
    final band = pending;
    pending = null;
    if (band == null) return;
    rows.addAll(band);
  }

  while (i < n) {
    final b = bytes[i];
    if (b == 0x1b) {
      final c = i + 1 < n ? bytes[i + 1] : -1;
      if (c == 0x2a) {
        // ESC * m nL nH
        final m = bytes[i + 2];
        if (m != 33) throw StateError('only ESC * 33 is decoded, got $m');
        final columns = bytes[i + 3] | (bytes[i + 4] << 8);
        final start = i + 5;
        final x0 = switch (align) {
          1 => (headWidth - columns) ~/ 2,
          2 => headWidth - columns,
          _ => 0,
        };
        final band = [for (var r = 0; r < 24; r++) Uint8List(headWidth)];
        for (var col = 0; col < columns; col++) {
          final x = x0 + col;
          for (var byte = 0; byte < 3; byte++) {
            final v = bytes[start + col * 3 + byte];
            for (var bit = 0; bit < 8; bit++) {
              if ((v >> (7 - bit)) & 1 == 1 && x >= 0 && x < headWidth) band[byte * 8 + bit][x] = 1;
            }
          }
        }
        flush();
        pending = band;
        i = start + columns * 3;
        continue;
      }
      if (c == 0x61) {
        // ESC a n: n is 0..2, or the digit '0'..'2' as Generator writes it.
        final n = bytes[i + 2];
        align = n >= 48 ? n - 48 : n;
        i += 3;
        continue;
      }
      // ESC 2, ESC @ take no parameter; the rest the generator emits take one.
      i += (c == 0x32 || c == 0x40) ? 2 : 3;
      continue;
    }
    if (b == 0x1d) {
      final c = bytes[i + 1];
      if (c == 0x76 && bytes[i + 2] == 0x30) {
        // GS v 0 m xL xH yL yH: printed at once, rows as they are.
        final xBytes = bytes[i + 4] | (bytes[i + 5] << 8);
        final yRows = bytes[i + 6] | (bytes[i + 7] << 8);
        final start = i + 8;
        final x0 = switch (align) {
          1 => (headWidth - xBytes * 8) ~/ 2,
          2 => headWidth - xBytes * 8,
          _ => 0,
        };
        flush();
        for (var r = 0; r < yRows; r++) {
          final row = Uint8List(headWidth);
          for (var bx = 0; bx < xBytes; bx++) {
            final v = bytes[start + r * xBytes + bx];
            for (var bit = 0; bit < 8; bit++) {
              final x = x0 + bx * 8 + bit;
              if ((v >> (7 - bit)) & 1 == 1 && x >= 0 && x < headWidth) row[x] = 1;
            }
          }
          rows.add(row);
        }
        i = start + xBytes * yRows;
        continue;
      }
      if (c == 0x56) {
        // GS V m [n]
        i += bytes[i + 2] >= 65 ? 4 : 3;
        continue;
      }
      i += 3; // GS x n
      continue;
    }
    if (b == 0x1c) {
      i += 2; // FS x
      continue;
    }
    if (b == 0x0a) {
      flush();
      i++;
      continue;
    }
    i++;
  }
  flush();
  return DecodedPaper(headWidth, rows);
}
