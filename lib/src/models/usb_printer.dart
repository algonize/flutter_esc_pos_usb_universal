import 'package:flutter/foundation.dart';

import '../enums.dart';

/// A USB printer found by [PrinterUsbManager.listPrinters] or picked in the
/// browser's chooser.
///
/// It is plain data, so it can be saved (see [toJson]) and used again later to
/// print without listing first.
///
/// [id] tells the package how to reach the printer; treat it as opaque. Its
/// prefix is the [route]:
///
/// | Prefix | Route |
/// |---|---|
/// | `win-usb:<device path>` | Windows, straight to the device |
/// | `win-queue:<printer name>` | Windows, an installed printer |
/// | `linux-usb:<vid>:<pid>:sn=<serial>` or `…:port=<usb port>` | Linux, `/dev/usb/lp*` |
/// | `mac-usb:<vid>:<pid>:sn=<serial>` or `…:loc=<location id>` | macOS, IOKit |
/// | `android-usb:<vid>:<pid>:sn=<serial>` or `…:dev=<device name>` | Android, USB host |
/// | `webusb:<vid>:<pid>:sn=<serial>` or `…:#<n>` | Browser, WebUSB |
/// | `bridge:<bridge id>` | Browser, the Local TCP bridge |
///
/// Device ids name the printer by its serial number when it has one, so they
/// survive a move to another USB port. A printer without one is found again by
/// its vendor and product ids, when it is the only such printer (see [findIn]).
@immutable
class UsbPrinter {
  const UsbPrinter({
    required this.id,
    this.kind = UsbPrinterKind.device,
    this.name,
    this.manufacturer,
    this.model,
    this.vendorId,
    this.productId,
    this.serialNumber,
    this.category = UsbPrinterCategory.unknown,
    this.paperWidthMm,
    this.commandSet,
    this.port,
    this.queueStatus,
    this.devicePrinterId,
    this.isDefault = false,
    this.isAccessible = true,
    this.isBusy = false,
  });

  /// How to reach the printer. See the table above.
  final String id;

  final UsbPrinterKind kind;

  /// The best name available: the printer's own make and model, its USB
  /// product string, or the installed printer's name.
  final String? name;

  final String? manufacturer;
  final String? model;

  /// USB vendor id, when known (not for most installed printers).
  final int? vendorId;

  /// USB product id, when known.
  final int? productId;

  /// The printer's USB serial number, when it reports one.
  final String? serialNumber;

  /// Receipt printer, other printer, or unknown. Receipt printers are listed first.
  final UsbPrinterCategory category;

  /// 58 or 80 when the model name gives the paper width away (XP-80C, POS-58).
  /// Only a hint: the app's paper-size setting stays the authority.
  final int? paperWidthMm;

  /// The command set from the printer's IEEE 1284 Device ID, such as "ESC/POS".
  /// Not saved by [toJson].
  final String? commandSet;

  /// Where it is plugged in: the Windows spooler port (USB001), or the Linux
  /// USB port path (1-2.3). Not saved by [toJson].
  final String? port;

  /// Installed printers only: what the operating system reports.
  /// Not saved by [toJson].
  final UsbQueueStatus? queueStatus;

  /// Installed printers only: the id of the USB device this printer prints on,
  /// when it is listed too. Not saved by [toJson].
  final String? devicePrinterId;

  /// Installed printers only: the operating system's default printer.
  /// Not saved by [toJson].
  final bool isDefault;

  /// False when the system does not let this app open the printer (Linux
  /// permissions). Not saved by [toJson].
  final bool isAccessible;

  /// True when another program held the printer while listing.
  /// Not saved by [toJson].
  final bool isBusy;

  bool get isDevice => kind == UsbPrinterKind.device;
  bool get isQueue => kind == UsbPrinterKind.queue;
  bool get isReceiptPrinter => category == UsbPrinterCategory.receipt;

  UsbPrinterRoute get route => routeOf(id);

  /// [name] when available, otherwise the USB ids, otherwise [id].
  String get displayName {
    final trimmed = name?.trim();
    if (trimmed != null && trimmed.isNotEmpty) return trimmed;
    if (vendorId != null && productId != null) {
      return 'USB printer ${hex4(vendorId!)}:${hex4(productId!)}';
    }
    return id;
  }

  /// This printer in [printers], a fresh list: the one with the same [id], or
  /// else the only USB device of the same route with the same vendor id,
  /// product id and serial number. Null when it is not there, or when several
  /// identical printers without serial numbers make it ambiguous.
  UsbPrinter? findIn(Iterable<UsbPrinter> printers) {
    for (final p in printers) {
      if (p.id == id) return p;
    }
    if (!isDevice || vendorId == null || productId == null) return null;
    final candidates = printers
        .where(
          (p) =>
              p.isDevice &&
              p.route == route &&
              p.vendorId == vendorId &&
              p.productId == productId &&
              (serialNumber == null || p.serialNumber == serialNumber),
        )
        .toList();
    return candidates.length == 1 ? candidates.single : null;
  }

  UsbPrinter copyWith({
    String? id,
    String? name,
    String? manufacturer,
    String? model,
    int? vendorId,
    int? productId,
    String? serialNumber,
    UsbPrinterCategory? category,
    int? paperWidthMm,
    String? commandSet,
    String? port,
  }) {
    return UsbPrinter(
      id: id ?? this.id,
      kind: kind,
      name: name ?? this.name,
      manufacturer: manufacturer ?? this.manufacturer,
      model: model ?? this.model,
      vendorId: vendorId ?? this.vendorId,
      productId: productId ?? this.productId,
      serialNumber: serialNumber ?? this.serialNumber,
      category: category ?? this.category,
      paperWidthMm: paperWidthMm ?? this.paperWidthMm,
      commandSet: commandSet ?? this.commandSet,
      port: port ?? this.port,
      queueStatus: queueStatus,
      devicePrinterId: devicePrinterId,
      isDefault: isDefault,
      isAccessible: isAccessible,
      isBusy: isBusy,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'kind': kind.name,
    if (name != null) 'name': name,
    if (manufacturer != null) 'manufacturer': manufacturer,
    if (model != null) 'model': model,
    if (vendorId != null) 'vendorId': vendorId,
    if (productId != null) 'productId': productId,
    if (serialNumber != null) 'serialNumber': serialNumber,
    'category': category.name,
    if (paperWidthMm != null) 'paperWidthMm': paperWidthMm,
  };

  /// Reads what [toJson] wrote. Unknown keys are ignored.
  factory UsbPrinter.fromJson(Map<String, dynamic> json) {
    return UsbPrinter(
      id: json['id'] as String,
      kind: UsbPrinterKind.values.firstWhere(
        (k) => k.name == json['kind'],
        orElse: () => UsbPrinterKind.device,
      ),
      name: json['name'] as String?,
      manufacturer: json['manufacturer'] as String?,
      model: json['model'] as String?,
      vendorId: (json['vendorId'] as num?)?.toInt(),
      productId: (json['productId'] as num?)?.toInt(),
      serialNumber: json['serialNumber'] as String?,
      category: UsbPrinterCategory.values.firstWhere(
        (c) => c.name == json['category'],
        orElse: () => UsbPrinterCategory.unknown,
      ),
      paperWidthMm: (json['paperWidthMm'] as num?)?.toInt(),
    );
  }

  /// Two printers are the same when their [id]s match.
  @override
  bool operator ==(Object other) => other is UsbPrinter && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'UsbPrinter(${route.name}, $displayName, $id)';
}

/// The route a printer [id] takes, from its prefix.
UsbPrinterRoute routeOf(String id) {
  final sep = id.indexOf(':');
  return switch (sep > 0 ? id.substring(0, sep) : '') {
    'win-usb' => UsbPrinterRoute.windowsDevice,
    'win-queue' => UsbPrinterRoute.windowsQueue,
    'linux-usb' => UsbPrinterRoute.linuxDevice,
    'mac-usb' => UsbPrinterRoute.macosDevice,
    'android-usb' => UsbPrinterRoute.androidDevice,
    'webusb' => UsbPrinterRoute.webUsb,
    'bridge' => UsbPrinterRoute.bridge,
    _ => UsbPrinterRoute.unknown,
  };
}

/// Four lowercase hex digits, as USB ids are usually written.
String hex4(int n) => n.toRadixString(16).padLeft(4, '0');
