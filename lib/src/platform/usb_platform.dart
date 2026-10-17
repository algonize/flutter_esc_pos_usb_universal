import '../models/usb_bridge_info.dart';
import '../models/usb_capabilities.dart';
import '../models/usb_printer.dart';
import '../models/usb_printer_note.dart';
import '../models/usb_write_options.dart';
import '../transport/printer_transport.dart';

/// Printers found by [UsbPlatform.listPrinters], with anything worth telling
/// the user about them.
typedef UsbPrinterListing = ({List<UsbPrinter> printers, List<UsbPrinterNote> notes});

/// Discovery and transport creation for one platform family. Picked at compile
/// time: `usb_platform_io.dart` or `usb_platform_web.dart`.
abstract interface class UsbPlatform {
  UsbCapabilities get capabilities;

  /// Connected USB printers, and installed printers where [UsbCapabilities.queues].
  /// Receipt printers first.
  Future<UsbPrinterListing> listPrinters({required bool includeVirtual});

  /// Opens the browser's USB chooser. Web only; must run from a user gesture.
  /// Returns null when the user closes the chooser.
  Future<UsbPrinter?> requestPrinter();

  /// The Local TCP bridge's state. [UsbBridgeInfo.notNeeded] on native platforms.
  Future<UsbBridgeInfo> checkBridge();

  PrinterTransport createTransport(UsbPrinter printer, UsbWriteOptions options);
}
