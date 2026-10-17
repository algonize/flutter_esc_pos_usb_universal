import 'dart:typed_data';

import 'package:flutter_esc_pos_usb_universal/flutter_esc_pos_usb_universal.dart';
import 'package:flutter_esc_pos_usb_universal/src/transport/io/linux_usb.dart';
import 'package:flutter_esc_pos_usb_universal/src/transport/io/macos_usb.dart';
import 'package:flutter_esc_pos_usb_universal/src/transport/io/windows_usb.dart';
import 'package:flutter_esc_pos_usb_universal/src/transport/printer_transport.dart';
import 'package:flutter_esc_pos_usb_universal/src/utils/printer_identity.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('IEEE 1284 Device ID', () {
    test('parses the fields, long and short keys', () {
      final id = Ieee1284Id.parse('MFG:Xprinter;MDL:XP-80C;CMD:ESC/POS;CLS:PRINTER;SERN:A1;');
      expect(id.manufacturer, 'Xprinter');
      expect(id.model, 'XP-80C');
      expect(id.commandSet, 'ESC/POS');
      expect(id.serialNumber, 'A1');
      final long = Ieee1284Id.parse('MANUFACTURER:EPSON;MODEL:TM-T20II;COMMAND SET:ESC/POS;');
      expect(long.manufacturer, 'EPSON');
      expect(long.model, 'TM-T20II');
      expect(Ieee1284Id.parse(null).model, isNull);
    });

    test('decodes replies with either length byte order', () {
      final text = 'MFG:Printer;MDL:POS-80;CMD:ESC/POS;'.codeUnits;
      final length = text.length + 2;
      final big = Uint8List.fromList([length >> 8, length & 0xff, ...text, 0, 0]);
      final little = Uint8List.fromList([length & 0xff, length >> 8, ...text]);
      expect(decode1284Reply(big), 'MFG:Printer;MDL:POS-80;CMD:ESC/POS;');
      expect(decode1284Reply(little), 'MFG:Printer;MDL:POS-80;CMD:ESC/POS;');
      expect(decode1284Reply(Uint8List.fromList([0, 2])), isNull);
    });

    test('names a printer by make and model', () {
      expect(
        usbDisplayName(Ieee1284Id.parse('MFG:Printer;MDL:POS-80;'), 'USB Printer Port', 1, 2),
        'Printer POS-80',
      );
      expect(
        usbDisplayName(Ieee1284Id.parse('MFG:EPSON;MDL:EPSON TM-T20;'), null, 1, 2),
        'EPSON TM-T20',
      );
      expect(usbDisplayName(const Ieee1284Id(), 'USB Printer Port', 1, 2), 'USB Printer Port');
      expect(usbDisplayName(const Ieee1284Id(), null, 0x416, 0x5011), 'USB printer 0416:5011');
    });
  });

  group('classification', () {
    UsbPrinterCategory category(UsbPrinter p, {String? driver}) =>
        classifyPrinter(p, driver: driver).category;

    test('the command set wins over the name', () {
      expect(
        category(const UsbPrinter(id: 'a', name: 'LaserJet', commandSet: 'ESC/POS')),
        UsbPrinterCategory.receipt,
      );
      expect(
        category(const UsbPrinter(id: 'a', name: 'POS-80', commandSet: 'PCL,PJL')),
        UsbPrinterCategory.other,
      );
    });

    test('names and drivers', () {
      expect(category(const UsbPrinter(id: 'a', name: 'XP-80C')), UsbPrinterCategory.receipt);
      expect(
        category(const UsbPrinter(id: 'a', name: 'EPSON TM-T20II Receipt')),
        UsbPrinterCategory.receipt,
      );
      expect(
        category(const UsbPrinter(id: 'a', name: 'Microsoft Print to PDF')),
        UsbPrinterCategory.other,
      );
      expect(
        category(const UsbPrinter(id: 'a', name: 'HP LaserJet M404')),
        UsbPrinterCategory.other,
      );
      expect(
        category(
          const UsbPrinter(id: 'a', name: 'Front desk'),
          driver: 'Generic / Text Only',
        ),
        UsbPrinterCategory.receipt,
      );
      expect(
        category(const UsbPrinter(id: 'a', name: 'USB Printer Port')),
        UsbPrinterCategory.unknown,
      );
    });

    test('paper width hints', () {
      expect(paperWidthHint('XP-80C'), 80);
      expect(paperWidthHint('POS-58'), 58);
      expect(paperWidthHint('EPSON TM-T20II'), 80);
      expect(paperWidthHint('TM-P20'), 58);
      expect(paperWidthHint('RP580'), isNull);
      expect(classifyPrinter(const UsbPrinter(id: 'a', name: 'LaserJet 80')).paperWidthMm, isNull);
    });

    test('a queue and its device share what each knows; receipt printers first', () {
      final printers = classifyPrinters(
        [
          const UsbPrinter(id: 'win-usb:office', name: 'USB device', commandSet: 'PCL'),
          const UsbPrinter(id: 'win-usb:pos', name: 'USB Printer Port'),
          const UsbPrinter(
            id: 'win-queue:Kitchen',
            kind: UsbPrinterKind.queue,
            name: 'Kitchen',
            devicePrinterId: 'win-usb:pos',
          ),
        ],
        drivers: {'win-queue:Kitchen': 'POS-80C Printer Driver'},
      );
      expect(printers.map((p) => p.id), ['win-usb:pos', 'win-queue:Kitchen', 'win-usb:office']);
      expect(printers[0].category, UsbPrinterCategory.receipt);
      expect(printers[0].paperWidthMm, 80);
      expect(printers[2].category, UsbPrinterCategory.other);
    });
  });

  group('Windows', () {
    test('ids from the device instance id', () {
      final withSerial = windowsUsbIds(r'USB\VID_1FC9&PID_2016\716D086D3537');
      expect(withSerial.vendorId, 0x1fc9);
      expect(withSerial.productId, 0x2016);
      expect(withSerial.serialNumber, '716D086D3537');
      // Windows makes up a port-based instance (with '&') when there is no serial.
      expect(windowsUsbIds(r'USB\VID_0416&PID_5011\5&2A3B4C&0&2').serialNumber, isNull);
      // A function of a composite device: the instance is not a serial.
      expect(windowsUsbIds(r'USB\VID_0416&PID_5011&MI_00\6&1234').serialNumber, isNull);
      final path = windowsUsbIds(
        r'\\?\usb#vid_0416&pid_5011#ABC123#{28d78fad-5a12-11d1-ae5b-0000f803a8c2}',
      );
      expect(path.vendorId, 0x416);
      expect(path.serialNumber, 'ABC123');
    });

    test('queue status from status and attribute bits', () {
      expect(windowsQueueStatus(0, 0), UsbQueueStatus.ready);
      expect(windowsQueueStatus(0, 0x400), UsbQueueStatus.offline);
      expect(windowsQueueStatus(0x80, 0), UsbQueueStatus.offline);
      expect(windowsQueueStatus(0x10, 0), UsbQueueStatus.paperOut);
      expect(windowsQueueStatus(0x1, 0), UsbQueueStatus.paused);
      expect(windowsQueueStatus(0x400, 0), UsbQueueStatus.printing);
    });

    test('error codes', () {
      expect(windowsErrorCode(2), 'notFound');
      expect(windowsErrorCode(1167), 'notFound');
      expect(windowsErrorCode(5), 'busy');
      expect(windowsErrorCode(32), 'busy');
      expect(windowsErrorCode(995), 'timeout');
      expect(windowsErrorCode(31), 'ioError');
    });
  });

  test('macOS and Linux error codes', () {
    expect(macErrorCode(0xe00002c5), 'busy');
    expect(macErrorCode(-536870203), 'busy'); // the same IOReturn as a signed int
    expect(macErrorCode(0xe00002e2), 'permissionDenied');
    expect(macErrorCode(0xe00002c0), 'notFound');
    expect(macErrorCode(0xe00002d6), 'timeout');
    expect(macErrorCode(0xe000404f), 'ioError');
    expect(linuxErrorCode(13), 'permissionDenied');
    expect(linuxErrorCode(19), 'notFound');
    expect(linuxErrorCode(16), 'busy');
    expect(linuxErrorCode(5), 'ioError');
  });

  test('codes map to results', () {
    expect(resultForCode('notFound'), PosPrintResult.printerNotFound);
    expect(resultForCode('busy'), PosPrintResult.printerBusy);
    expect(resultForCode('permissionDenied'), PosPrintResult.permissionDenied);
    expect(resultForCode('timeout'), PosPrintResult.timeout);
    expect(resultForCode('bridgeOutdated'), PosPrintResult.bridgeOutdated);
    expect(resultForCode('helperMissing'), PosPrintResult.bridgeOutdated);
    expect(resultForCode('noPrinter'), PosPrintResult.printerNotSelected);
    expect(resultForCode('ioError'), PosPrintResult.writeFailed);
  });
}
