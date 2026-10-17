import 'package:flutter/foundation.dart';

/// Something worth telling the user after [PrinterUsbManager.listPrinters],
/// such as a missing permission that hides a printer. Show [message] as is.
@immutable
class UsbPrinterNote {
  const UsbPrinterNote({required this.code, required this.message, this.isWarning = true});

  /// A stable code to branch on:
  ///
  /// - `permissionDenied`: Linux does not let this app write to a USB printer.
  ///   [message] has the command that fixes it.
  /// - `usblpMissing`: Linux has not loaded its USB printer driver (`usblp`).
  /// - `queuesUnavailable`: installed Windows printers could not be listed.
  /// - `cupsUnavailable`: the bridge could not list installed (CUPS) printers.
  /// - `bridgeNotInstalled`, `bridgeNotLinked`, `bridgeOutdated`: the Local TCP
  ///   bridge needs installing, starting or updating.
  /// - `webUsbBlocked`: this browser's system keeps WebUSB from opening USB
  ///   printers (Windows); printing needs the bridge.
  /// - `webUsbUnavailable`: the browser has no WebUSB (Firefox, Safari).
  /// - `unsupported`: no USB printing on this platform.
  ///
  /// Other codes may come from newer versions of the Local TCP bridge.
  final String code;

  final String message;

  /// False for information, true for something that blocks printing.
  final bool isWarning;

  @override
  bool operator ==(Object other) =>
      other is UsbPrinterNote && other.code == code && other.message == message;

  @override
  int get hashCode => Object.hash(code, message);

  @override
  String toString() => 'UsbPrinterNote($code: $message)';
}
