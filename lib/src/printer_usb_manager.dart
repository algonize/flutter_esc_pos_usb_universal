import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_esc_pos_utils/flutter_esc_pos_utils.dart';

import 'enums.dart';
import 'models/print_outcome.dart';
import 'models/usb_bridge_info.dart';
import 'models/usb_capabilities.dart';
import 'models/usb_printer.dart';
import 'models/usb_printer_note.dart';
import 'models/usb_write_options.dart';
import 'platform/usb_platform.dart';
import 'platform/usb_platform_io.dart'
    if (dart.library.js_interop) 'platform/usb_platform_web.dart'
    as platform;
import 'printer_usb_interface.dart';
import 'raster/widget_raster.dart';
import 'transport/printer_transport.dart';

/// Finds, connects to and prints on ESC/POS USB printers, with the same code
/// on Android, Windows, macOS, Linux and in Chromium browsers. No printer
/// driver needed.
///
/// ```dart
/// final manager = PrinterUsbManager();
/// final printers = await manager.listPrinters();   // or requestPrinter() on the web
/// await manager.selectPrinter(printers.first);
/// final result = await manager.printWidget(context, child: const MyReceipt());
/// ```
///
/// How each platform reaches the printer:
/// - **Windows:** straight to the device through Windows' own USB printer
///   driver (usbprint.sys), or through an installed Windows printer.
/// - **macOS:** straight to the device through IOKit. Sandboxed apps need the
///   `com.apple.security.device.usb` entitlement.
/// - **Linux:** straight to `/dev/usb/lp*`. The user needs write access (the
///   `lp` group).
/// - **Android:** straight to the device through Android's USB host API. Android
///   asks the user once per printer; [connect] asks when needed.
/// - **Web (Chrome, Edge):** WebUSB on macOS, ChromeOS and Android; the Local
///   TCP extension and bridge on Windows and Linux.
/// - **iOS:** not supported; iOS lets apps use only MFi accessories.
class PrinterUsbManager implements BasePrinterUsbManager {
  PrinterUsbManager({
    UsbPrinter? printer,
    ThermalPosPrinterPageSize paperSize = ThermalPosPrinterPageSize.size80mm,
    CapabilityProfile? profile,
    Duration timeout = const Duration(seconds: 20),
    UsbWriteOptions writeOptions = const UsbWriteOptions(),
  }) : _selectedPrinter = printer,
       _paperSize = paperSize,
       _profile = profile,
       _timeout = timeout,
       _writeOptions = writeOptions;

  static UsbPlatform _platform = platform.createUsbPlatform();

  /// Replaces the platform layer, for tests.
  @visibleForTesting
  static set debugPlatform(UsbPlatform value) => _platform = value;

  final ThermalPosPrinterPageSize _paperSize;
  CapabilityProfile? _profile;
  final Duration _timeout;
  final UsbWriteOptions _writeOptions;

  UsbPrinter? _selectedPrinter;
  PrinterTransport? _transport;
  bool _isPrinting = false;
  Object? _lastError;
  PrintOutcome? _lastPrint;
  List<UsbPrinterNote> _notes = const [];

  // ── Platform ───────────────────────────────────────────────────────────────

  /// What this platform supports: listing, a browser chooser, the bridge,
  /// installed printers.
  static UsbCapabilities get capabilities => _platform.capabilities;

  /// Web: whether the Local TCP bridge is installed, running and new enough to
  /// print on USB printers. Native apps don't need it: [UsbBridgeStatus.notNeeded].
  Future<UsbBridgeInfo> checkBridge() => _platform.checkBridge();

  // ── Discovery ──────────────────────────────────────────────────────────────

  /// The USB printers connected to this computer, and the installed printers
  /// where [UsbCapabilities.queues], receipt printers first. On the web: what
  /// the Local TCP bridge finds plus the printers this page was allowed to use
  /// through WebUSB. Never asks the user anything.
  ///
  /// Installed printers that only make files (PDF, XPS, fax) are left out
  /// unless [includeVirtual] is true. Anything worth telling the user, such as
  /// a missing Linux permission, is in [notes] afterwards.
  Future<List<UsbPrinter>> listPrinters({bool includeVirtual = false}) async {
    try {
      final result = await _platform.listPrinters(includeVirtual: includeVirtual);
      _notes = List.unmodifiable(result.notes);
      return List.unmodifiable(result.printers);
    } catch (e) {
      _lastError = e;
      _notes = [
        UsbPrinterNote(code: 'listFailed', message: 'USB printers could not be listed: $e'),
      ];
      return const [];
    }
  }

  /// What the last [listPrinters] found worth telling the user.
  List<UsbPrinterNote> get notes => _notes;

  /// Web only: opens the browser's USB chooser (WebUSB) and selects the printer
  /// picked there. Call it from a button tap; browsers block it otherwise.
  /// Returns null when the chooser is closed without a choice.
  ///
  /// Not available on Windows, where the system keeps USB printers from the
  /// browser ([UsbCapabilities.chooser] is false): throws a
  /// [PrinterTransportException] with [PosPrintResult.bridgeRequired]. Use
  /// [listPrinters] with the Local TCP bridge there.
  Future<UsbPrinter?> requestPrinter() async {
    final printer = await _platform.requestPrinter();
    if (printer != null) await selectPrinter(printer);
    return printer;
  }

  // ── Selection ──────────────────────────────────────────────────────────────

  /// The printer used by [connect] and the print methods. Its id is updated
  /// when the printer is found again on another USB port, so save this one.
  UsbPrinter? get selectedPrinter => _selectedPrinter;

  /// Chooses the printer to print on. Disconnects from a different one first.
  Future<void> selectPrinter(UsbPrinter printer) async {
    if (_selectedPrinter == printer) {
      _selectedPrinter = printer;
      return;
    }
    await disconnect();
    _selectedPrinter = printer;
  }

  // ── Connection ─────────────────────────────────────────────────────────────

  @override
  bool get isConnected => _transport?.isConnected ?? false;

  /// The underlying error behind the last failed list, connect or print, for
  /// logs and bug reports. The returned [PosPrintResult] is the user-facing
  /// summary; a [UsbPlatformError] here carries the system's code and message.
  Object? get lastError => _lastError;

  /// How the last ticket was sent: its size, time and rate. For logs.
  PrintOutcome? get lastPrint => _lastPrint;

  @override
  ThermalPosPrinterPageSize get paperSize => _paperSize;

  @override
  CapabilityProfile? get profile => _profile;

  UsbWriteOptions get writeOptions => _writeOptions;

  /// Opens the selected printer. The print methods connect by themselves, so
  /// this is only needed to check a printer before printing.
  @override
  Future<PosPrintResult> connect({Duration? timeout}) async {
    final printer = _selectedPrinter;
    if (printer == null) return PosPrintResult.printerNotSelected;
    if (isConnected) return PosPrintResult.success;
    _lastError = null;
    try {
      _profile ??= await CapabilityProfile.load();
      final transport = _platform.createTransport(printer, _writeOptions);
      await transport.connect(timeout ?? _timeout);
      _transport = transport;
      _selectedPrinter = transport.printer;
      return PosPrintResult.success;
    } on PrinterTransportException catch (e) {
      _lastError = e.cause ?? e;
      return e.result;
    } catch (e) {
      _lastError = e;
      return PosPrintResult.connectionFailed;
    }
  }

  /// Closes the printer, so other programs (and the system print queue) can
  /// use it again.
  @override
  Future<PosPrintResult> disconnect({Duration? timeout}) async {
    final transport = _transport;
    _transport = null;
    if (transport == null) return PosPrintResult.success;
    try {
      await transport.disconnect();
      if (timeout != null) await Future<void>.delayed(timeout);
      return PosPrintResult.success;
    } catch (e) {
      _lastError = e;
      return PosPrintResult.disconnectError;
    }
  }

  // ── Printing ───────────────────────────────────────────────────────────────

  /// Sends raw ESC/POS [data], connecting first when needed.
  ///
  /// Disconnects afterwards unless [isDisconnect] is false, which keeps the
  /// printer open for more tickets (call [disconnect] when done). While it is
  /// open, other programs can't print on it.
  @override
  Future<PosPrintResult> printTicket(List<int> data, {bool isDisconnect = true}) {
    if (data.isEmpty) return Future.value(PosPrintResult.ticketEmpty);
    return _print(data is Uint8List ? data : Uint8List.fromList(data), isDisconnect: isDisconnect);
  }

  /// Renders [child] as an image and prints it, connecting first when needed.
  /// Handy for logos, QR codes, barcodes, non-Latin scripts and rich layouts.
  /// The image goes as `ESC *` column bands, the same dots as the network and
  /// Bluetooth packages print.
  ///
  /// [gapMm] adds that much blank paper below the receipt, for tearing by
  /// hand on printers without a cutter.
  @override
  Future<PosPrintResult> printWidget(
    BuildContext context, {
    required Widget child,
    bool isDisconnect = true,
    double gapMm = 0,
  }) async {
    if (_isPrinting) return PosPrintResult.printInProgress;
    if (_selectedPrinter == null) return PosPrintResult.printerNotSelected;
    final Uint8List ticket;
    try {
      final profile = _profile ??= await CapabilityProfile.load();
      if (!context.mounted) return PosPrintResult.unknown;
      ticket = await buildWidgetTicket(
        context,
        child,
        paperSize: _paperSize,
        profile: profile,
        gapMm: gapMm,
      );
    } catch (e) {
      // Rendering failed, for example a widget that can't lay out at paper width.
      _lastError = e;
      return PosPrintResult.ticketEmpty;
    }
    if (ticket.isEmpty) return PosPrintResult.ticketEmpty;
    return _print(ticket, isDisconnect: isDisconnect);
  }

  Future<PosPrintResult> _print(Uint8List ticket, {required bool isDisconnect}) async {
    if (_isPrinting) return PosPrintResult.printInProgress;
    _isPrinting = true;
    try {
      if (!isConnected) {
        var result = await connect();
        // The system print queue holds a USB printer while it prints a
        // document. That is over in a moment, so try again a few times.
        for (var retry = 0; result == PosPrintResult.printerBusy && retry < 3; retry++) {
          await Future<void>.delayed(const Duration(seconds: 1));
          result = await connect();
        }
        if (result != PosPrintResult.success) return result;
      }
      final transport = _transport!;
      final clock = Stopwatch()..start();
      await transport.write(ticket);
      clock.stop();
      _selectedPrinter = transport.printer;
      _lastPrint = PrintOutcome(
        bytes: ticket.length,
        elapsed: clock.elapsed,
        route: transport.printer.route,
      );
      if (kDebugMode) debugPrint('flutter_esc_pos_usb_universal: $_lastPrint');
      return PosPrintResult.success;
    } on PrinterTransportException catch (e) {
      _lastError = e.cause ?? e;
      await disconnect();
      return e.result;
    } catch (e) {
      _lastError = e;
      await disconnect();
      return PosPrintResult.writeFailed;
    } finally {
      if (isDisconnect) await disconnect();
      _isPrinting = false;
    }
  }

  /// Disconnects and releases this manager. Don't use it afterwards.
  Future<void> dispose() => disconnect();
}
