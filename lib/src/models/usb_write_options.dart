import 'package:flutter/foundation.dart';

/// How tickets are sent to a USB printer.
///
/// USB needs no pacing: a printer with a full buffer refuses more data until it
/// has room, and the write simply waits. So the defaults suit every printer;
/// change them only to work around a specific one.
@immutable
class UsbWriteOptions {
  const UsbWriteOptions({
    this.chunkSize = 16 * 1024,
    this.stallTimeout = const Duration(seconds: 10),
    this.jobName = 'Receipt',
  }) : assert(chunkSize >= 64);

  /// Bytes handed to the USB stack per write.
  final int chunkSize;

  /// How long the printer may go without taking any data before the print
  /// fails with [PosPrintResult.timeout]. A printer that is out of paper, has
  /// its cover open or is switched off stops taking data, so a write would
  /// otherwise wait forever. A long receipt is fine: only a stall counts.
  final Duration stallTimeout;

  /// The job title the system print queue shows, for installed printers and
  /// the Local TCP bridge.
  final String jobName;

  UsbWriteOptions copyWith({int? chunkSize, Duration? stallTimeout, String? jobName}) {
    return UsbWriteOptions(
      chunkSize: chunkSize ?? this.chunkSize,
      stallTimeout: stallTimeout ?? this.stallTimeout,
      jobName: jobName ?? this.jobName,
    );
  }

  @override
  String toString() =>
      'UsbWriteOptions(chunk: $chunkSize B, stall: ${stallTimeout.inMilliseconds} ms, job: $jobName)';
}
