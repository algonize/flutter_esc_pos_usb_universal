import 'dart:typed_data';

import '../enums.dart';
import '../models/usb_printer.dart';

/// Moves bytes to one printer over one route (a USB device, a system print
/// queue, WebUSB or the Local TCP bridge). The manager owns exactly one
/// transport per connected printer.
abstract interface class PrinterTransport {
  /// The printer, updated by [connect] when it was found again under another
  /// id (plugged into another USB port).
  UsbPrinter get printer;

  bool get isConnected;

  /// Opens the printer. Throws [PrinterTransportException] on failure.
  Future<void> connect(Duration timeout);

  /// Sends [data] as one job, split for the link as needed. Completes once the
  /// printer (or the system print queue) has taken every byte, so closing the
  /// printer afterwards cannot cut the end off. Throws
  /// [PrinterTransportException] on failure.
  Future<void> write(Uint8List data);

  /// Closes the printer. Never throws.
  Future<void> disconnect();
}

/// A transport failure, already translated into a [PosPrintResult].
class PrinterTransportException implements Exception {
  const PrinterTransportException(this.result, [this.cause]);

  final PosPrintResult result;

  /// The underlying error, for logging.
  final Object? cause;

  @override
  String toString() =>
      'PrinterTransportException(${result.name}${cause == null ? '' : ': $cause'})';
}

/// A transport for a printer this platform cannot reach.
class UnsupportedTransport implements PrinterTransport {
  UnsupportedTransport(this.printer, [this.reason]);

  @override
  final UsbPrinter printer;

  /// Why, for [PrinterTransportException.cause].
  final String? reason;

  @override
  bool get isConnected => false;

  @override
  Future<void> connect(Duration timeout) =>
      throw PrinterTransportException(PosPrintResult.unsupported, reason);

  @override
  Future<void> write(Uint8List data) =>
      throw PrinterTransportException(PosPrintResult.unsupported, reason);

  @override
  Future<void> disconnect() async {}
}

/// Thrown by [PrinterTransport]s with a code from the operating system or the
/// bridge, kept for [PrinterTransportException.cause].
class UsbPlatformError implements Exception {
  const UsbPlatformError(this.code, this.message, {this.detail});

  /// `notFound`, `busy`, `permissionDenied`, `timeout`, `ioError`, ... or an
  /// operating-system error number.
  final String code;
  final String message;
  final String? detail;

  @override
  String toString() => 'UsbPlatformError($code: $message${detail == null ? '' : ' ($detail)'})';
}

/// The [PosPrintResult] for a [UsbPlatformError.code]. The codes are the Local
/// TCP bridge's, which the native transports use too. An unexplained error is
/// [PosPrintResult.connectionFailed] while [connecting], otherwise
/// [PosPrintResult.writeFailed].
PosPrintResult resultForCode(String code, {bool connecting = false}) => switch (code) {
  'notFound' => PosPrintResult.printerNotFound,
  'busy' => PosPrintResult.printerBusy,
  'permissionDenied' => PosPrintResult.permissionDenied,
  'timeout' => PosPrintResult.timeout,
  'unsupported' => PosPrintResult.unsupported,
  'invalidRequest' => PosPrintResult.ticketEmpty,
  'noPrinter' => PosPrintResult.printerNotSelected,
  'bridgeOutdated' || 'helperMissing' => PosPrintResult.bridgeOutdated,
  'helperFailed' => PosPrintResult.connectionFailed,
  _ => connecting ? PosPrintResult.connectionFailed : PosPrintResult.writeFailed,
};
