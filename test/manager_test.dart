import 'dart:typed_data';

import 'package:flutter_esc_pos_usb_universal/flutter_esc_pos_usb_universal.dart';
import 'package:flutter_esc_pos_usb_universal/src/platform/usb_platform.dart';
import 'package:flutter_esc_pos_usb_universal/src/transport/printer_transport.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeTransport implements PrinterTransport {
  _FakeTransport(this._printer, this._platform);

  UsbPrinter _printer;
  final _FakePlatform _platform;
  bool _open = false;

  @override
  UsbPrinter get printer => _printer;

  @override
  bool get isConnected => _open;

  @override
  Future<void> connect(Duration timeout) async {
    _platform.connects++;
    if (_platform.connectFailures.isNotEmpty) {
      throw PrinterTransportException(_platform.connectFailures.removeAt(0), 'connect failed');
    }
    if (_platform.resolveTo != null) _printer = _printer.copyWith(id: _platform.resolveTo);
    _open = true;
  }

  @override
  Future<void> write(Uint8List data) async {
    final failure = _platform.writeFailure;
    if (failure != null) throw PrinterTransportException(failure, 'write failed');
    _platform.written.add(data);
  }

  @override
  Future<void> disconnect() async {
    if (_open) _platform.disconnects++;
    _open = false;
  }
}

class _FakePlatform implements UsbPlatform {
  final written = <Uint8List>[];
  final connectFailures = <PosPrintResult>[];
  PosPrintResult? writeFailure;
  String? resolveTo;
  int connects = 0;
  int disconnects = 0;
  Object? listError;

  @override
  UsbCapabilities get capabilities =>
      const UsbCapabilities(list: true, chooser: false, bridge: false, queues: false);

  @override
  Future<UsbBridgeInfo> checkBridge() async => UsbBridgeInfo.notNeeded;

  @override
  Future<UsbPrinterListing> listPrinters({required bool includeVirtual}) async {
    if (listError != null) throw listError!;
    return (
      printers: const [
        UsbPrinter(id: 'linux-usb:0416:5011:port=1-2', vendorId: 0x416, productId: 0x5011),
      ],
      notes: const [UsbPrinterNote(code: 'permissionDenied', message: 'fix it')],
    );
  }

  @override
  Future<UsbPrinter?> requestPrinter() async => null;

  @override
  PrinterTransport createTransport(UsbPrinter printer, UsbWriteOptions options) =>
      _FakeTransport(printer, this);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _FakePlatform platform;
  const printer = UsbPrinter(
    id: 'linux-usb:0416:5011:port=1-2',
    vendorId: 0x416,
    productId: 0x5011,
  );

  setUp(() {
    platform = _FakePlatform();
    PrinterUsbManager.debugPlatform = platform;
  });

  test('needs a printer and bytes', () async {
    final manager = PrinterUsbManager();
    expect(await manager.printTicket([1, 2, 3]), PosPrintResult.printerNotSelected);
    expect(await manager.connect(), PosPrintResult.printerNotSelected);
    await manager.selectPrinter(printer);
    expect(await manager.printTicket([]), PosPrintResult.ticketEmpty);
  });

  test('prints and closes the printer afterwards', () async {
    final manager = PrinterUsbManager(printer: printer);
    expect(await manager.printTicket([0x1b, 0x40, 0x0a]), PosPrintResult.success);
    expect(platform.written.single, [0x1b, 0x40, 0x0a]);
    expect(platform.connects, 1);
    expect(platform.disconnects, 1);
    expect(manager.isConnected, isFalse);
    expect(manager.lastPrint!.bytes, 3);
    expect(manager.lastPrint!.route, UsbPrinterRoute.linuxDevice);
    expect(manager.profile, isNotNull);
  });

  test('keeps the printer open when asked', () async {
    final manager = PrinterUsbManager(printer: printer);
    expect(await manager.printTicket([1], isDisconnect: false), PosPrintResult.success);
    expect(await manager.printTicket([2], isDisconnect: false), PosPrintResult.success);
    expect(platform.connects, 1);
    expect(manager.isConnected, isTrue);
    expect(await manager.disconnect(), PosPrintResult.success);
    expect(platform.disconnects, 1);
  });

  test('tries again while the system print queue holds the printer', () async {
    platform.connectFailures.add(PosPrintResult.printerBusy);
    final manager = PrinterUsbManager(printer: printer);
    expect(await manager.printTicket([1]), PosPrintResult.success);
    expect(platform.connects, 2);
  });

  test('gives up when it stays busy', () async {
    platform.connectFailures.addAll(List.filled(4, PosPrintResult.printerBusy));
    final manager = PrinterUsbManager(printer: printer);
    expect(await manager.printTicket([1]), PosPrintResult.printerBusy);
    expect(platform.connects, 4);
    expect(manager.lastError, 'connect failed');
  }, timeout: const Timeout(Duration(seconds: 10)));

  test('reports a failed write and closes the printer', () async {
    platform.writeFailure = PosPrintResult.timeout;
    final manager = PrinterUsbManager(printer: printer);
    expect(await manager.printTicket([1]), PosPrintResult.timeout);
    expect(manager.lastError, 'write failed');
    expect(manager.isConnected, isFalse);
    expect(platform.disconnects, 1);
  });

  test('keeps the id the printer was found under again', () async {
    platform.resolveTo = 'linux-usb:0416:5011:port=1-3';
    final manager = PrinterUsbManager(printer: printer);
    expect(await manager.printTicket([1]), PosPrintResult.success);
    expect(manager.selectedPrinter!.id, 'linux-usb:0416:5011:port=1-3');
  });

  test('selecting another printer closes the open one', () async {
    final manager = PrinterUsbManager(printer: printer);
    await manager.connect();
    await manager.selectPrinter(const UsbPrinter(id: 'linux-usb:other'));
    expect(platform.disconnects, 1);
    expect(manager.selectedPrinter!.id, 'linux-usb:other');
  });

  test('lists printers with notes', () async {
    final manager = PrinterUsbManager();
    final printers = await manager.listPrinters();
    expect(printers.single.id, printer.id);
    expect(manager.notes.single.code, 'permissionDenied');
    platform.listError = StateError('boom');
    expect(await manager.listPrinters(), isEmpty);
    expect(manager.notes.single.code, 'listFailed');
  });
}
