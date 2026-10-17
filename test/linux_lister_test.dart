import 'dart:io';

import 'package:flutter_esc_pos_usb_universal/flutter_esc_pos_usb_universal.dart';
import 'package:flutter_esc_pos_usb_universal/src/transport/io/linux_usb.dart';
import 'package:flutter_test/flutter_test.dart';

/// A fake /dev/usb and /sys laid out the way the kernel does it:
/// /sys/class/usbmisc/lpN/device links to the USB interface, whose parent is
/// the USB device with idVendor, idProduct, serial, ...
class _FakeSystem {
  _FakeSystem() : root = Directory.systemTemp.createTempSync('usblp');

  final Directory root;

  String get dev => '${root.path}/dev/usb';
  String get sys => '${root.path}/sys';

  void addPrinter(
    String lp, {
    required String port,
    String? vendor,
    String? product,
    String? serial,
    String? productName,
    String? ieee1284,
  }) {
    File('$dev/$lp').createSync(recursive: true);
    final device = Directory('$sys/devices/usb1/$port')..createSync(recursive: true);
    final iface = Directory('${device.path}/$port:1.0')..createSync();
    void write(Directory d, String name, String? value) {
      if (value != null) File('${d.path}/$name').writeAsStringSync('$value\n');
    }

    write(device, 'idVendor', vendor);
    write(device, 'idProduct', product);
    write(device, 'serial', serial);
    write(device, 'product', productName);
    write(iface, 'ieee1284_id', ieee1284);
    write(iface, 'bInterfaceClass', '07');
    Directory('$sys/class/usbmisc/$lp').createSync(recursive: true);
    Link('$sys/class/usbmisc/$lp/device').createSync(iface.path);
  }

  void addUnboundPrinterInterface() {
    final d = Directory('$sys/bus/usb/devices/1-9:1.0')..createSync(recursive: true);
    File('${d.path}/bInterfaceClass').writeAsStringSync('07\n');
  }

  void dispose() => root.deleteSync(recursive: true);
}

void main() {
  late _FakeSystem system;

  setUp(() => system = _FakeSystem());
  tearDown(() => system.dispose());

  test('lists lp devices with ids that survive renumbering', () {
    system
      ..addPrinter(
        'lp1',
        port: '1-2.3',
        vendor: '1fc9',
        product: '2016',
        serial: '716D086D3537',
        productName: 'USB Printer Port',
        ieee1284: 'MFG:Printer;MDL:POS-80;CMD:ESC/POS;',
      )
      ..addPrinter(
        'lp0',
        port: '1-4',
        vendor: '0416',
        product: '5011',
        productName: 'POS58 Printer',
      );
    final lister = LinuxUsbLister(devRoot: system.dev, sysRoot: system.sys, canWrite: (_) => true);
    final result = lister.list();
    expect(result.notes, isEmpty);
    expect(result.printers.map((p) => p.id), [
      'linux-usb:0416:5011:port=1-4',
      'linux-usb:1fc9:2016:sn=716D086D3537',
    ]);
    final pos80 = result.printers[1];
    expect(pos80.name, 'Printer POS-80');
    expect(pos80.commandSet, 'ESC/POS');
    expect(pos80.category, UsbPrinterCategory.receipt);
    expect(pos80.serialNumber, '716D086D3537');
    expect(pos80.port, '1-2.3');
    expect(result.paths[pos80.id], '${system.dev}/lp1');
    final pos58 = result.printers[0];
    expect(pos58.name, 'POS58 Printer');
    expect(pos58.paperWidthMm, 58);
  });

  test('says how to fix permissions', () {
    system.addPrinter('lp0', port: '1-4', vendor: '0416', product: '5011');
    final result = LinuxUsbLister(
      devRoot: system.dev,
      sysRoot: system.sys,
      canWrite: (_) => false,
    ).list();
    expect(result.printers.single.isAccessible, isFalse);
    expect(result.notes.single.code, 'permissionDenied');
    expect(result.notes.single.message, contains('usermod -aG lp'));
  });

  test('says when usblp is not loaded', () {
    system.addUnboundPrinterInterface();
    final result = LinuxUsbLister(
      devRoot: system.dev,
      sysRoot: system.sys,
      canWrite: (_) => true,
    ).list();
    expect(result.printers, isEmpty);
    expect(result.notes.single.code, 'usblpMissing');
  });

  test('no /dev/usb at all is an empty list', () {
    final result = LinuxUsbLister(
      devRoot: '${system.root.path}/missing',
      sysRoot: system.sys,
      canWrite: (_) => true,
    ).list();
    expect(result.printers, isEmpty);
  });
}
