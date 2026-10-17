import 'package:flutter_esc_pos_utils/flutter_esc_pos_utils.dart';

/// The outcome of a printer operation.
///
/// The shared values ([success], [timeout], [ticketEmpty], [printInProgress],
/// [scanInProgress], [disconnectError], [unknown]) match
/// `flutter_esc_pos_network_universal` and `flutter_esc_pos_bluetooth_universal`,
/// so apps can handle all three packages alike.
enum PosPrintResult {
  success('Success'),
  timeout('Error. The printer did not take the data in time'),
  printerNotSelected('Error. No printer selected'),
  printerNotConnected('Error. Printer not connected'),
  ticketEmpty('Error. Ticket is empty'),
  printInProgress('Error. Another print in progress'),
  scanInProgress('Error. Printer scanning in progress'),
  connectionFailed('Error. Could not connect to the printer'),
  writeFailed('Error. Failed to send data to the printer'),
  disconnectError('Error. Failed to disconnect'),
  printerNotFound('Error. The USB printer is not connected. Check the cable and that it is on'),
  printerBusy('Error. The printer is busy with another program. Try again in a moment'),
  permissionDenied('Error. The system did not allow access to the USB printer'),
  printerAccessRequired('Error. Choose the printer again to give this page access'),
  bridgeRequired('Error. USB printing in this browser needs the Local TCP extension'),
  bridgeOutdated('Error. Update the Local TCP bridge to print on USB printers'),
  unsupported('Error. USB printing is not supported here'),
  userCancelled('Cancelled. No printer was chosen'),
  unknown('Unknown error');

  const PosPrintResult(this.msg);

  /// A short, human-readable description of the result.
  final String msg;

  bool get isSuccess => this == PosPrintResult.success;
}

/// How the bytes reach a printer.
enum UsbPrinterKind {
  /// A USB printer written to directly: Windows `usbprint.sys`, Linux
  /// `/dev/usb/lp*`, macOS IOKit, Android USB host or WebUSB. No printer
  /// driver needed.
  device,

  /// A printer installed in the operating system (a Windows printer or a CUPS
  /// queue). The bytes go through the spooler untouched (RAW), so they still
  /// reach the printer as ESC/POS.
  queue,
}

/// The path a print job takes to the printer. Set by where the printer was
/// listed, and read from its [UsbPrinter.id].
enum UsbPrinterRoute {
  /// Windows app, straight to the USB device through `usbprint.sys`.
  windowsDevice,

  /// Windows app, through an installed Windows printer (the spooler).
  windowsQueue,

  /// Linux app, straight to `/dev/usb/lp*`.
  linuxDevice,

  /// macOS app, straight to the USB device through IOKit.
  macosDevice,

  /// Android app, straight to the USB device through Android's USB host API.
  androidDevice,

  /// Browser, straight to the USB device through WebUSB.
  webUsb,

  /// Browser, through the Local TCP extension and its native host.
  bridge,

  /// Not a printer id this package made.
  unknown,
}

/// What kind of printer it looks like, so apps can lead with receipt printers.
enum UsbPrinterCategory {
  /// Reports ESC/POS in its IEEE 1284 Device ID, or has a receipt-printer name.
  receipt,

  /// Reports an office or label command set (PCL, PostScript, ZPL, ...), or
  /// has such a name. Raw ESC/POS sent to these prints pages of symbols.
  other,

  /// Nothing to go on. Many unbranded receipt printers look like this.
  unknown,
}

/// The state the operating system reports for an installed printer.
enum UsbQueueStatus { ready, printing, paused, offline, paperOut, error, unknown }

/// Whether the Local TCP bridge (extension + native host) can print on USB
/// printers from this browser.
enum UsbBridgeStatus {
  /// Not a browser: native apps reach USB printers directly.
  notNeeded,

  /// The Local TCP extension did not answer: not installed, or disabled.
  notInstalled,

  /// The extension answered, but its native host is not installed or not running.
  notLinked,

  /// The native host predates USB printing. Run the Local TCP installer again.
  outdated,

  /// Ready for USB printing.
  ready,
}

/// Thermal paper widths.
enum ThermalPosPrinterPageSize {
  size58mm('58mm'),
  size72mm('72mm'),
  size80mm('80mm');

  const ThermalPosPrinterPageSize(this.title);
  final String title;
}

extension ThermalPosPrinterPageSizeStringExt on String {
  ThermalPosPrinterPageSize get toThermalPosPrinterPageSize => switch (this) {
    '58mm' => ThermalPosPrinterPageSize.size58mm,
    '72mm' => ThermalPosPrinterPageSize.size72mm,
    _ => ThermalPosPrinterPageSize.size80mm,
  };
}

extension ThermalPosPrinterPageSizeExt on ThermalPosPrinterPageSize {
  /// Printable width of the print head in dots.
  double get widthPx => switch (this) {
    ThermalPosPrinterPageSize.size58mm => 384.0,
    ThermalPosPrinterPageSize.size72mm => 512.0,
    ThermalPosPrinterPageSize.size80mm => 576.0,
  };

  /// The [PaperSize] used by the ESC/POS [Generator].
  PaperSize get toPaperSize => switch (this) {
    ThermalPosPrinterPageSize.size58mm => PaperSize.mm58,
    ThermalPosPrinterPageSize.size72mm => PaperSize.mm80,
    ThermalPosPrinterPageSize.size80mm => PaperSize.mm80,
  };
}
