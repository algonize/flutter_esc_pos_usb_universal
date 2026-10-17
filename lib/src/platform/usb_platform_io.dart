import 'dart:io';

import '../enums.dart';
import '../models/usb_bridge_info.dart';
import '../models/usb_capabilities.dart';
import '../models/usb_printer.dart';
import '../models/usb_printer_note.dart';
import '../models/usb_write_options.dart';
import '../transport/io/android_usb.dart';
import '../transport/io/linux_usb.dart';
import '../transport/io/macos_usb.dart';
import '../transport/io/windows_usb.dart';
import '../transport/printer_transport.dart';
import 'usb_platform.dart';

/// Windows, macOS, Linux and Android apps: USB printers straight through the
/// system's own USB support, no driver needed. iOS does not let apps use USB
/// printers (only MFi accessories), so it is not supported.
class IoUsbPlatform implements UsbPlatform {
  IoUsbPlatform._();

  static final IoUsbPlatform instance = IoUsbPlatform._();

  bool get _supported =>
      Platform.isWindows || Platform.isMacOS || Platform.isLinux || Platform.isAndroid;

  @override
  UsbCapabilities get capabilities => _supported
      ? UsbCapabilities(list: true, chooser: false, bridge: false, queues: Platform.isWindows)
      : UsbCapabilities.none;

  @override
  Future<UsbPrinterListing> listPrinters({required bool includeVirtual}) async {
    if (Platform.isWindows) return listWindowsPrinters(includeVirtual: includeVirtual);
    if (Platform.isMacOS) {
      final result = await listMacUsbPrinters(known1284: mac1284Cache, inUse: macEntriesInUse);
      mac1284Cache
        ..clear()
        ..addAll(result.ids);
      return (printers: result.printers, notes: result.notes);
    }
    if (Platform.isLinux) {
      final result = LinuxUsbLister().list();
      return (printers: result.printers, notes: result.notes);
    }
    if (Platform.isAndroid) {
      final result = await listAndroidUsbPrinters();
      return (printers: result.printers, notes: result.notes);
    }
    return (
      printers: const <UsbPrinter>[],
      notes: const [
        UsbPrinterNote(
          code: 'unsupported',
          message:
              'USB printing works on Android, Windows, macOS, Linux and in Chromium browsers. '
              'iOS does not let apps use USB printers.',
        ),
      ],
    );
  }

  @override
  Future<UsbPrinter?> requestPrinter() async => null; // Native platforms list instead.

  @override
  Future<UsbBridgeInfo> checkBridge() async => UsbBridgeInfo.notNeeded;

  @override
  PrinterTransport createTransport(UsbPrinter printer, UsbWriteOptions options) {
    final route = printer.route;
    final here = switch (route) {
      UsbPrinterRoute.windowsDevice || UsbPrinterRoute.windowsQueue => Platform.isWindows,
      UsbPrinterRoute.macosDevice => Platform.isMacOS,
      UsbPrinterRoute.linuxDevice => Platform.isLinux,
      UsbPrinterRoute.androidDevice => Platform.isAndroid,
      _ => false,
    };
    if (!here) {
      return UnsupportedTransport(
        printer,
        route == UsbPrinterRoute.webUsb || route == UsbPrinterRoute.bridge
            ? 'This printer was chosen in a browser. List the printers again in this app.'
            : 'This printer was set up on another operating system. Choose a printer on this computer.',
      );
    }
    return switch (route) {
      UsbPrinterRoute.windowsDevice => WindowsDeviceTransport(printer, options),
      UsbPrinterRoute.windowsQueue => WindowsQueueTransport(printer, options),
      UsbPrinterRoute.macosDevice => MacUsbTransport(printer, options),
      UsbPrinterRoute.androidDevice => AndroidUsbTransport(printer, options),
      _ => LinuxUsbTransport(printer, options),
    };
  }
}

UsbPlatform createUsbPlatform() => IoUsbPlatform.instance;
