import 'package:flutter/foundation.dart';

import '../enums.dart';

/// How one ticket was sent, for logs and bug reports.
@immutable
class PrintOutcome {
  const PrintOutcome({required this.bytes, required this.elapsed, required this.route});

  /// Bytes the printer (or the system print queue) took.
  final int bytes;

  /// From the first byte sent until the last one was taken.
  final Duration elapsed;

  final UsbPrinterRoute route;

  /// The average rate, in kB/s.
  double get kilobytesPerSecond => elapsed.inMilliseconds == 0 ? 0 : bytes / elapsed.inMilliseconds;

  @override
  String toString() =>
      'PrintOutcome($bytes B in ${elapsed.inMilliseconds} ms, '
      '${kilobytesPerSecond.toStringAsFixed(1)} kB/s, ${route.name})';
}
