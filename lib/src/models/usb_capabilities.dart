import 'package:flutter/foundation.dart';

/// What the current platform can do, so an app can show the right buttons.
@immutable
class UsbCapabilities {
  const UsbCapabilities({
    required this.list,
    required this.chooser,
    required this.bridge,
    required this.queues,
  });

  /// [PrinterUsbManager.listPrinters] can find printers without asking the user.
  /// Native apps list connected printers; browsers list what the Local TCP
  /// bridge finds plus the WebUSB printers this site was already allowed to use.
  final bool list;

  /// [PrinterUsbManager.requestPrinter] opens the browser's USB chooser (WebUSB).
  /// True in Chromium browsers on macOS, ChromeOS and Linux. False on Windows,
  /// where the system's own USB printer driver keeps WebUSB from opening
  /// printers, so the bridge is used instead.
  final bool chooser;

  /// Printing can go through the Local TCP bridge. True on the web only.
  final bool bridge;

  /// Printers installed in the operating system are listed too (Windows apps,
  /// and browsers through the bridge).
  final bool queues;

  static const none = UsbCapabilities(list: false, chooser: false, bridge: false, queues: false);

  @override
  String toString() =>
      'UsbCapabilities(list: $list, chooser: $chooser, bridge: $bridge, queues: $queues)';
}
