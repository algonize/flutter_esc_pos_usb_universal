import 'package:flutter/services.dart';
import 'package:flutter_esc_pos_usb_universal/flutter_esc_pos_usb_universal.dart';
import 'package:flutter_esc_pos_usb_universal/src/transport/io/android_usb.dart';
import 'package:flutter_test/flutter_test.dart';

/// The Kotlin side, faked: one printer, with or without permission.
class _FakeAndroid {
  bool hasPermission = false;
  bool grant = true;
  String? openError;
  String? writeError;
  final calls = <String>[];
  final written = <Uint8List>[];

  Map<String, Object?> get _device => {
    'deviceName': '/dev/bus/usb/001/007',
    'vendorId': 0x1fc9,
    'productId': 0x2016,
    'manufacturerName': 'Printer',
    'productName': 'USB Printer Port',
    // Android shows the serial number only once the app may use the printer.
    'serialNumber': hasPermission ? '716D086D3537' : null,
    'interfaceNumber': 0,
    'hasPermission': hasPermission,
    'ieee1284': hasPermission
        ? Uint8List.fromList([0, 37, ...'MFG:Printer;MDL:POS-80;CMD:ESC/POS;'.codeUnits])
        : null,
    'busy': false,
  };

  Future<Object?> handle(MethodCall call) async {
    calls.add(call.method);
    switch (call.method) {
      case 'list':
        return [_device];
      case 'requestPermission':
        expect((call.arguments as Map)['deviceName'], '/dev/bus/usb/001/007');
        hasPermission = grant;
        return grant;
      case 'open':
        if (openError != null) throw PlatformException(code: openError!, message: 'open failed');
        return 1;
      case 'write':
        if (writeError != null) throw PlatformException(code: writeError!, message: 'write failed');
        final args = call.arguments as Map;
        written.add(args['data'] as Uint8List);
        expect(args['timeoutMs'], 10000);
        return (args['data'] as Uint8List).length;
      case 'close':
        return null;
    }
    throw MissingPluginException();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _FakeAndroid android;

  setUp(() {
    android = _FakeAndroid();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      androidUsbChannel,
      android.handle,
    );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      androidUsbChannel,
      null,
    );
  });

  test('lists a printer before permission by its device node, with a note', () async {
    final result = await listAndroidUsbPrinters();
    final p = result.printers.single;
    expect(p.id, 'android-usb:1fc9:2016:dev=/dev/bus/usb/001/007');
    expect(p.route, UsbPrinterRoute.androidDevice);
    expect(p.isAccessible, isFalse);
    expect(p.name, 'Printer USB Printer Port');
    expect(result.deviceNames[p.id], '/dev/bus/usb/001/007');
    expect(result.notes.single.code, 'permissionRequired');
  });

  test('after permission: named by serial number, with the 1284 Device ID', () async {
    android.hasPermission = true;
    final result = await listAndroidUsbPrinters();
    final p = result.printers.single;
    expect(p.id, 'android-usb:1fc9:2016:sn=716D086D3537');
    expect(p.name, 'Printer POS-80');
    expect(p.commandSet, 'ESC/POS');
    expect(p.category, UsbPrinterCategory.receipt);
    expect(p.paperWidthMm, 80);
    expect(result.notes, isEmpty);
  });

  test('connect asks for permission, then prints and remembers the serial-number id', () async {
    final saved = (await listAndroidUsbPrinters()).printers.single;
    android.calls.clear();
    final transport = AndroidUsbTransport(saved, const UsbWriteOptions());
    await transport.connect(const Duration(seconds: 5));
    expect(android.calls, ['list', 'requestPermission', 'list', 'open']);
    expect(transport.printer.id, 'android-usb:1fc9:2016:sn=716D086D3537');
    await transport.write(Uint8List.fromList([0x1b, 0x40]));
    expect(android.written.single, [0x1b, 0x40]);
    await transport.disconnect();
    expect(android.calls.last, 'close');
  });

  test('a refused permission is permissionDenied', () async {
    android.grant = false;
    final saved = (await listAndroidUsbPrinters()).printers.single;
    final transport = AndroidUsbTransport(saved, const UsbWriteOptions());
    await expectLater(
      transport.connect(const Duration(seconds: 5)),
      throwsA(
        isA<PrinterTransportException>().having(
          (e) => e.result,
          'result',
          PosPrintResult.permissionDenied,
        ),
      ),
    );
    expect(android.calls, isNot(contains('open')));
  });

  test('a printer that is not there is printerNotFound', () async {
    const gone = UsbPrinter(
      id: 'android-usb:0416:5011:sn=OTHER',
      vendorId: 0x416,
      productId: 0x5011,
      serialNumber: 'OTHER',
    );
    await expectLater(
      AndroidUsbTransport(gone, const UsbWriteOptions()).connect(const Duration(seconds: 5)),
      throwsA(
        isA<PrinterTransportException>().having(
          (e) => e.result,
          'result',
          PosPrintResult.printerNotFound,
        ),
      ),
    );
  });

  test('native error codes map to results', () async {
    android
      ..hasPermission = true
      ..openError = 'busy';
    final saved = (await listAndroidUsbPrinters()).printers.single;
    await expectLater(
      AndroidUsbTransport(saved, const UsbWriteOptions()).connect(const Duration(seconds: 5)),
      throwsA(
        isA<PrinterTransportException>().having(
          (e) => e.result,
          'result',
          PosPrintResult.printerBusy,
        ),
      ),
    );

    android
      ..openError = null
      ..writeError = 'timeout';
    final transport = AndroidUsbTransport(saved, const UsbWriteOptions());
    await transport.connect(const Duration(seconds: 5));
    await expectLater(
      transport.write(Uint8List.fromList([1])),
      throwsA(
        isA<PrinterTransportException>().having((e) => e.result, 'result', PosPrintResult.timeout),
      ),
    );
  });
}
