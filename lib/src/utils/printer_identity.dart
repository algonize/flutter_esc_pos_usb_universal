import 'dart:typed_data';

import '../enums.dart';
import '../models/usb_printer.dart';

// Receipt printer detection, the same rules as the Local TCP bridge, so a
// printer is sorted the same way in an app and in a browser.
//
// The operating system lists office printers (laser, inkjet, PDF, label) next
// to receipt printers, and raw ESC/POS sent to those prints pages of symbols.
// The printer's own command set (from its IEEE 1284 Device ID) wins over any
// name.

final _receiptCommands = RegExp(r'ESC\s*/?\s*POS|STAR\s*(LINE|PRNT)', caseSensitive: false);
final _otherCommands = RegExp(
  r'\b(PCL\w*|PJL|POSTSCRIPT|PS|URF|PWG\w*|PDF|ESCPL2|ESC/P-?R|ESCPR\w*|BDC|IPP\w*|XPS|LIPS\w*|'
  r'RPCS|GDI|CAPT|ZPL\w*|EPL\d?|CPCL|TSPL\d?)\b',
  caseSensitive: false,
);
final _receiptNames = RegExp(
  [
    'receipt',
    'thermal',
    r'esc/?pos',
    r'\bpos[\s_-]?(58|76|80)',
    r'\bpos\b',
    'kitchen',
    'ticket',
    r'\btm[\s_-]?[tmpuhl]\d',
    r'\btsp\s?\d',
    r'\bsp\s?7\d\d',
    'mc-?print',
    r'\bsrp-?\d',
    'bixolon',
    'posiflex',
    'xprinter',
    r'\bxp-?(58|80|n\d{3}|q\d{3}|t\d{2})',
    'rongta',
    r'\brp[\s_-]?(58|80|\d{3})',
    'hprt',
    'gprinter',
    r'\bgp-?\d',
    'zjiang',
    r'\bzj-?\d',
    'goojprt',
    'munbyn',
    'sunmi',
    r'\bct-?s\d',
    r'\bdeli\b',
    r'generic\s*/\s*text only',
    r'\b(58|80)\s?mm\b',
  ].join('|'),
  caseSensitive: false,
);
final _otherNames = RegExp(
  [
    'laserjet',
    'deskjet',
    'officejet',
    r'\benvy\b',
    'pagewide',
    'smart tank',
    'pixma',
    'imageclass',
    'imagerunner',
    'maxify',
    'selphy',
    'ecotank',
    'workforce',
    'surecolor',
    'stylus',
    r'epson\s+(et|wf|xp|l)-?\d{3,4}',
    r'\bhl-',
    r'\bmfc-',
    r'\bdcp-',
    'kyocera',
    'ecosys',
    'taskalfa',
    'ricoh',
    'lexmark',
    'xerox',
    'workcentre',
    'versalink',
    'phaser',
    'bizhub',
    'konica',
    r'\boki\b',
    r'\blbp\d',
    r'\bmf\d{3}',
    r'\bg[1-7]0\d0\b',
    'pdf',
    'xps',
    'onenote',
    r'\bfax\b',
    'ipp class',
    'mopria',
    'postscript',
    r'\bpcl\b',
    'zebra',
    r'\bzpl\b',
    'label',
    'dymo',
  ].join('|'),
  caseSensitive: false,
);
final _epson80 = RegExp(r'\btm[\s_-]?(t(20|70|81|82|83|86|88|90)|m(30|50))', caseSensitive: false);
final _epson58 = RegExp(r'\btm[\s_-]?p20', caseSensitive: false);
final _width = RegExp(r'(?:^|[^0-9])(58|80)(?:\s?mm)?(?![0-9])', caseSensitive: false);

/// The fields of an IEEE 1284 Device ID, such as "MFG:Xprinter;MDL:XP-80C;CMD:ESC/POS;".
class Ieee1284Id {
  const Ieee1284Id({
    this.manufacturer,
    this.model,
    this.commandSet,
    this.description,
    this.serialNumber,
  });

  factory Ieee1284Id.parse(String? id) {
    if (id == null || id.isEmpty) return const Ieee1284Id();
    String? manufacturer, model, commandSet, description, serialNumber;
    for (final part in id.split(';')) {
      final i = part.indexOf(':');
      if (i <= 0) continue;
      final key = part.substring(0, i).trim().toUpperCase();
      final value = part.substring(i + 1).trim();
      if (value.isEmpty) continue;
      switch (key) {
        case 'MFG' || 'MANUFACTURER':
          manufacturer = value;
        case 'MDL' || 'MODEL':
          model = value;
        case 'CMD' || 'COMMAND SET':
          commandSet = value;
        case 'DES' || 'DESCRIPTION':
          description = value;
        case 'SN' || 'SERN' || 'SERIALNUMBER':
          serialNumber = value;
      }
    }
    return Ieee1284Id(
      manufacturer: manufacturer,
      model: model,
      commandSet: commandSet,
      description: description,
      serialNumber: serialNumber,
    );
  }

  final String? manufacturer;
  final String? model;
  final String? commandSet;
  final String? description;
  final String? serialNumber;
}

/// Decodes a GET_DEVICE_ID reply (the printer class request, or Windows'
/// IOCTL_USBPRINT_GET_1284_ID): a 2-byte length (big-endian per IEEE 1284,
/// little-endian on some printers) that counts itself, then the ASCII id.
String? decode1284Reply(Uint8List reply) {
  final got = reply.length;
  if (got <= 2) return null;
  final big = (reply[0] << 8) | reply[1];
  final little = reply[0] | (reply[1] << 8);
  final length = (big >= 2 && big <= got)
      ? big
      : (little >= 2 && little <= got)
      ? little
      : got;
  final text = String.fromCharCodes(reply.sublist(2, length)).replaceAll(RegExp(r'[\x00\s]+$'), '');
  return text.isEmpty ? null : text;
}

/// The best human name for a USB printer: the 1284 make and model, then its
/// USB product string, then its ids.
String usbDisplayName(Ieee1284Id info, String? fallback, int? vendorId, int? productId) {
  final mfg = info.manufacturer;
  final mdl = info.model;
  if (mdl != null) {
    return mfg != null && !mdl.toLowerCase().startsWith(mfg.toLowerCase()) ? '$mfg $mdl' : mdl;
  }
  if (info.description != null) return info.description!;
  if (fallback != null && fallback.trim().isNotEmpty) return fallback.trim();
  if (vendorId != null && productId != null) {
    return 'USB printer ${hex4(vendorId)}:${hex4(productId)}';
  }
  return 'USB printer';
}

/// Paper width from a model name, when it says (XP-80C, POS-58, RP80, TM-T20).
int? paperWidthHint(String text) {
  if (_epson80.hasMatch(text)) return 80;
  if (_epson58.hasMatch(text)) return 58;
  final m = _width.firstMatch(text);
  return m == null ? null : int.parse(m.group(1)!);
}

/// Sorts [printer] into receipt, other or unknown, from its command set first
/// and its names after. [driver] is the installed printer's driver name.
({UsbPrinterCategory category, int? paperWidthMm}) classifyPrinter(
  UsbPrinter printer, {
  String? driver,
}) {
  final cmd = printer.commandSet ?? '';
  final text = [
    printer.name,
    printer.model,
    printer.manufacturer,
    driver,
  ].whereType<String>().join(' ');
  final UsbPrinterCategory category;
  if (_receiptCommands.hasMatch(cmd)) {
    category = UsbPrinterCategory.receipt;
  } else if (cmd.isNotEmpty && _otherCommands.hasMatch(cmd)) {
    category = UsbPrinterCategory.other;
  } else if (_receiptNames.hasMatch(text)) {
    category = UsbPrinterCategory.receipt;
  } else if (_otherNames.hasMatch(text)) {
    category = UsbPrinterCategory.other;
  } else {
    category = UsbPrinterCategory.unknown;
  }
  return (
    category: category,
    paperWidthMm: category == UsbPrinterCategory.receipt ? paperWidthHint(text) : null,
  );
}

/// Classifies every printer, lets an installed printer and the USB device it
/// prints on (one physical printer) share what each knows, and puts receipt
/// printers first. [drivers] maps installed printer ids to driver names.
List<UsbPrinter> classifyPrinters(
  List<UsbPrinter> printers, {
  Map<String, String> drivers = const {},
}) {
  final out = [
    for (final p in printers)
      () {
        final c = classifyPrinter(p, driver: drivers[p.id]);
        return p.copyWith(category: c.category, paperWidthMm: c.paperWidthMm);
      }(),
  ];
  for (var i = 0; i < out.length; i++) {
    final queue = out[i];
    final deviceId = queue.devicePrinterId;
    if (deviceId == null) continue;
    final d = out.indexWhere((p) => p.id == deviceId);
    if (d < 0) continue;
    final device = out[d];
    // The device's own command set is the better witness; the queue's driver
    // name fills in when the device said nothing.
    final known = device.category != UsbPrinterCategory.unknown ? device : queue;
    final width = known.category == UsbPrinterCategory.receipt
        ? device.paperWidthMm ?? queue.paperWidthMm
        : null;
    out[d] = _withCategory(device, known.category, width);
    out[i] = _withCategory(queue, known.category, width);
  }
  return sortReceiptFirst(out);
}

/// [printers] with receipt printers first, then unknown, then other printers,
/// keeping the order within each group.
List<UsbPrinter> sortReceiptFirst(List<UsbPrinter> printers) {
  const rank = {
    UsbPrinterCategory.receipt: 0,
    UsbPrinterCategory.unknown: 1,
    UsbPrinterCategory.other: 2,
  };
  final indexed = printers.asMap().entries.toList()
    ..sort((a, b) {
      final byCategory = rank[a.value.category]!.compareTo(rank[b.value.category]!);
      return byCategory != 0 ? byCategory : a.key.compareTo(b.key);
    });
  return [for (final e in indexed) e.value];
}

UsbPrinter _withCategory(UsbPrinter p, UsbPrinterCategory category, int? width) {
  // copyWith cannot clear a value, and a width only belongs to receipt printers.
  final cleared = p.paperWidthMm != null && width == null;
  if (!cleared) return p.copyWith(category: category, paperWidthMm: width);
  return UsbPrinter(
    id: p.id,
    kind: p.kind,
    name: p.name,
    manufacturer: p.manufacturer,
    model: p.model,
    vendorId: p.vendorId,
    productId: p.productId,
    serialNumber: p.serialNumber,
    category: category,
    commandSet: p.commandSet,
    port: p.port,
    queueStatus: p.queueStatus,
    devicePrinterId: p.devicePrinterId,
    isDefault: p.isDefault,
    isAccessible: p.isAccessible,
    isBusy: p.isBusy,
  );
}
