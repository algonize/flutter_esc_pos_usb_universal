import 'package:flutter_esc_pos_usb_universal/flutter_esc_pos_usb_universal.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('UsbPrinter', () {
    const pos80 = UsbPrinter(
      id: 'mac-usb:1fc9:2016:sn=716D086D3537',
      name: 'Printer POS-80',
      manufacturer: 'Printer',
      model: 'POS-80',
      vendorId: 0x1fc9,
      productId: 0x2016,
      serialNumber: '716D086D3537',
      category: UsbPrinterCategory.receipt,
      paperWidthMm: 80,
      commandSet: 'ESC/POS',
      isBusy: true,
    );

    test('saves what identifies it, not what changes from list to list', () {
      final json = pos80.toJson();
      expect(json, {
        'id': 'mac-usb:1fc9:2016:sn=716D086D3537',
        'kind': 'device',
        'name': 'Printer POS-80',
        'manufacturer': 'Printer',
        'model': 'POS-80',
        'vendorId': 0x1fc9,
        'productId': 0x2016,
        'serialNumber': '716D086D3537',
        'category': 'receipt',
        'paperWidthMm': 80,
      });
      final back = UsbPrinter.fromJson(json);
      expect(back, pos80);
      expect(back.vendorId, 0x1fc9);
      expect(back.category, UsbPrinterCategory.receipt);
      expect(back.isBusy, isFalse);
      expect(back.commandSet, isNull);
    });

    test('reads numbers saved as doubles (JSON from the web) and unknown values', () {
      final p = UsbPrinter.fromJson({
        'id': 'bridge:win-queue:POS-80C',
        'kind': 'queue',
        'vendorId': 8137.0,
        'category': 'something new',
        'extra': true,
      });
      expect(p.vendorId, 8137);
      expect(p.isQueue, isTrue);
      expect(p.category, UsbPrinterCategory.unknown);
    });

    test('route comes from the id', () {
      expect(pos80.route, UsbPrinterRoute.macosDevice);
      expect(
        const UsbPrinter(id: r'win-usb:\\?\usb#vid_0416').route,
        UsbPrinterRoute.windowsDevice,
      );
      expect(const UsbPrinter(id: 'win-queue:POS-80').route, UsbPrinterRoute.windowsQueue);
      expect(
        const UsbPrinter(id: 'linux-usb:0416:5011:port=1-2').route,
        UsbPrinterRoute.linuxDevice,
      );
      expect(const UsbPrinter(id: 'webusb:0416:5011:#1').route, UsbPrinterRoute.webUsb);
      expect(const UsbPrinter(id: 'bridge:cups:POS').route, UsbPrinterRoute.bridge);
      expect(const UsbPrinter(id: 'nothing').route, UsbPrinterRoute.unknown);
    });

    test('displayName falls back to the USB ids', () {
      expect(pos80.displayName, 'Printer POS-80');
      expect(
        const UsbPrinter(id: 'x', name: '  ', vendorId: 0x416, productId: 0x5011).displayName,
        'USB printer 0416:5011',
      );
      expect(const UsbPrinter(id: 'linux-usb:lp0').displayName, 'linux-usb:lp0');
    });

    group('findIn', () {
      const moved = UsbPrinter(
        id: 'linux-usb:0416:5011:port=1-3',
        vendorId: 0x416,
        productId: 0x5011,
      );

      test('finds the same id', () {
        expect(pos80.findIn([pos80.copyWith(name: 'fresh')])!.name, 'fresh');
      });

      test('finds a printer that moved to another port by its serial number', () {
        final there = pos80.copyWith(id: 'mac-usb:1fc9:2016:sn=716D086D3537#1');
        expect(pos80.findIn([there]), there);
      });

      test('finds the only identical printer without a serial number', () {
        const saved = UsbPrinter(
          id: 'linux-usb:0416:5011:port=1-2',
          vendorId: 0x416,
          productId: 0x5011,
        );
        expect(saved.findIn([moved]), moved);
      });

      test('never guesses between identical printers', () {
        const saved = UsbPrinter(
          id: 'linux-usb:0416:5011:port=1-2',
          vendorId: 0x416,
          productId: 0x5011,
        );
        final twin = moved.copyWith(id: 'linux-usb:0416:5011:port=1-4');
        expect(saved.findIn([moved, twin]), isNull);
      });

      test('a different serial number is a different printer', () {
        final other = pos80.copyWith(id: 'mac-usb:1fc9:2016:sn=OTHER', serialNumber: 'OTHER');
        expect(pos80.findIn([other]), isNull);
      });

      test('stays on its route', () {
        const saved = UsbPrinter(
          id: 'linux-usb:0416:5011:port=1-2',
          vendorId: 0x416,
          productId: 0x5011,
        );
        const webUsb = UsbPrinter(id: 'webusb:0416:5011:#1', vendorId: 0x416, productId: 0x5011);
        expect(saved.findIn([webUsb]), isNull);
      });

      test('installed printers are only found by id', () {
        const queue = UsbPrinter(
          id: 'win-queue:A',
          kind: UsbPrinterKind.queue,
          vendorId: 1,
          productId: 2,
        );
        const other = UsbPrinter(
          id: 'win-queue:B',
          kind: UsbPrinterKind.queue,
          vendorId: 1,
          productId: 2,
        );
        expect(queue.findIn([other]), isNull);
      });
    });
  });

  test('PosPrintResult shares its common values with the other two packages', () {
    for (final name in [
      'success',
      'timeout',
      'ticketEmpty',
      'printInProgress',
      'scanInProgress',
      'disconnectError',
      'unknown',
    ]) {
      expect(PosPrintResult.values.map((r) => r.name), contains(name));
    }
    expect(PosPrintResult.success.isSuccess, isTrue);
  });

  test('paper sizes', () {
    expect('58mm'.toThermalPosPrinterPageSize, ThermalPosPrinterPageSize.size58mm);
    expect('bogus'.toThermalPosPrinterPageSize, ThermalPosPrinterPageSize.size80mm);
    expect(ThermalPosPrinterPageSize.size72mm.widthPx, 512);
    expect(ThermalPosPrinterPageSize.size58mm.toPaperSize, PaperSize.mm58);
  });
}
