# Flutter ESC/POS USB Universal

[![pub package](https://img.shields.io/pub/v/flutter_esc_pos_usb_universal.svg)](https://pub.dev/packages/flutter_esc_pos_usb_universal)
[![platform](https://img.shields.io/badge/platform-android%20%7C%20windows%20%7C%20macos%20%7C%20linux%20%7C%20web-blue.svg)](https://pub.dev/packages/flutter_esc_pos_usb_universal)

Print receipts on ESC/POS thermal **USB** printers from **Android, Windows, macOS, Linux and Flutter Web**, with one API, and **no printer driver**.

It is the USB companion of [`flutter_esc_pos_network_universal`](https://pub.dev/packages/flutter_esc_pos_network_universal) (Wi‑Fi / Ethernet) and [`flutter_esc_pos_bluetooth_universal`](https://pub.dev/packages/flutter_esc_pos_bluetooth_universal) (Bluetooth): the same `connect` / `printTicket` / `printWidget` / `disconnect` surface, the same `PosPrintResult` values, and the same receipt dots.

---

## ✨ Features

- **No driver.** Reaches USB printer‑class printers (most 58/80 mm receipt printers) through the operating system's own USB printer support.
- **Mostly pure Dart.** Desktop platforms are reached through `dart:ffi` (Windows SetupAPI and spooler, macOS IOKit, Linux libc) and the web through `dart:js_interop`. Only Android has a small Kotlin part, as its USB host API is Java-only.
- **Discovery.** `listPrinters()` finds connected printers, receipt printers first, with their make, model and command set from the printer's own IEEE 1284 Device ID.
- **Widget printing.** `printWidget` renders any Flutter widget and prints it as an image, the same dots as the network and Bluetooth packages.
- **Raw ESC/POS.** `printTicket` sends bytes built with the re‑exported `flutter_esc_pos_utils` (`Generator`, `PaperSize`, `CapabilityProfile`, …).
- **Survives replugging.** Printers are named by their USB serial number, so a printer moved to another port is found again.
- **Clean timeouts.** A printer that is out of paper, has its cover open or is switched off fails with `PosPrintResult.timeout` instead of hanging.
- **Installed printers too.** On Windows (and in browsers through the bridge), printers installed with a vendor driver print through the system spooler as RAW jobs.

---

## 📋 Platform support

| Platform | How it reaches the printer | Setup |
|---|---|---|
| **Windows app** | Straight to the device through Windows' built‑in "USB Printing Support" (`usbprint.sys`); or an installed Windows printer through the spooler (RAW / XPS_PASS) | None |
| **macOS app** | Straight to the device through IOKit | Sandboxed apps: add the `com.apple.security.device.usb` entitlement |
| **Linux app** | Straight to `/dev/usb/lp*` (the kernel's `usblp` driver) | The user needs write access: the `lp` group or a udev rule |
| **Android app** | Straight to the device through Android's USB host API | A USB OTG cable; the user allows the app once per printer |
| **Chrome / Edge on macOS, ChromeOS, Android** | WebUSB | The user picks the printer once in the browser's chooser |
| **Chrome / Edge on Windows, Linux** | The [Local TCP](https://chromewebstore.google.com/detail/local-tcp/ngbakchodnmhndnghhejmocfadjfekkf) extension and bridge (v2.1.2+) | Install the extension and run its installer once |
| Firefox, Safari | The Local TCP bridge, if installed (no WebUSB) | As above |
| iOS, iPadOS | Not supported: iOS lets apps use only MFi‑certified accessories | — |

Why the bridge on Windows and Linux browsers: those systems give USB printers to their own printer drivers, and Chrome's WebUSB can't open a device that a driver holds. The Local TCP bridge's native host writes to the printer the way an app would.

Printers that need special handling:
- **Vendor‑class printers** (some Epson TM models, cheap unbranded ones) don't use the USB printer class. On Windows, install the vendor driver and print through the installed printer.
- **USB‑to‑serial printers** (they show up as a COM port) are not supported.

---

## 🚀 Installation

```yaml
dependencies:
  flutter_esc_pos_usb_universal: ^1.0.0
```

```dart
import 'package:flutter_esc_pos_usb_universal/flutter_esc_pos_usb_universal.dart';
```

### macOS

Sandboxed apps (the default for Flutter apps) need the USB entitlement in **both** `macos/Runner/DebugProfile.entitlements` and `macos/Runner/Release.entitlements`:

```xml
<key>com.apple.security.device.usb</key>
<true/>
```

Without it, printers are still listed, but opening one fails with `PosPrintResult.permissionDenied`, and `notes` says which entitlement is missing.

### Linux

USB printers appear as `/dev/usb/lp0`, `lp1`, …, usually owned by the `lp` group. Either add the user to it (then log out and back in):

```bash
sudo usermod -aG lp $USER
```

or install a udev rule, for example `/etc/udev/rules.d/70-usb-printers.rules`:

```
SUBSYSTEM=="usbmisc", KERNEL=="lp[0-9]*", TAG+="uaccess"
```

`listPrinters()` reports printers it can't write to with `isAccessible == false` and a `permissionDenied` note.

### Android

USB printers need a phone or tablet with USB host (OTG) support and an OTG cable or adapter. Android asks once per printer whether the app may use it; the package asks when it first connects (`connect()` or the first print), so nothing is needed in the app.

Optionally, let Android offer to open your app when a printer is plugged in. With "Always open", Android also keeps the permission for that printer. In `android/app/src/main/AndroidManifest.xml`, inside the main `<activity>`:

```xml
<intent-filter>
    <action android:name="android.hardware.usb.action.USB_DEVICE_ATTACHED" />
</intent-filter>
<meta-data
    android:name="android.hardware.usb.action.USB_DEVICE_ATTACHED"
    android:resource="@xml/usb_printer_filter" />
```

and `android/app/src/main/res/xml/usb_printer_filter.xml`:

```xml
<resources>
    <usb-device class="7" />
</resources>
```

### Web

- **macOS / ChromeOS / Android:** nothing to install. Call `requestPrinter()` from a button tap to open the browser's USB chooser. The page must be served over HTTPS (or `localhost`).
- **Windows / Linux:** the user installs the [Local TCP extension](https://chromewebstore.google.com/detail/local-tcp/ngbakchodnmhndnghhejmocfadjfekkf) and runs the one‑click installer it offers (the same bridge `flutter_esc_pos_network_universal` uses on the web). Check it with `checkBridge()`.

---

## ⚡ Quick start

### 1. Pick a printer

```dart
final manager = PrinterUsbManager(paperSize: ThermalPosPrinterPageSize.size80mm);

// Apps, and browsers with the bridge: no prompt.
final printers = await manager.listPrinters();
for (final note in manager.notes) {
  debugPrint(note.message); // e.g. how to fix Linux permissions
}
await manager.selectPrinter(printers.firstWhere((p) => p.isReceiptPrinter));

// Browsers on macOS / ChromeOS: the WebUSB chooser, from a button tap.
if (PrinterUsbManager.capabilities.chooser) {
  await manager.requestPrinter(); // selects the chosen printer
}
```

### 2. Print a Flutter widget

```dart
final result = await manager.printWidget(context, child: const MyReceipt());
if (result != PosPrintResult.success) debugPrint('${result.msg}: ${manager.lastError}');
```

### 3. Print raw ESC/POS bytes

```dart
final profile = await CapabilityProfile.load();
final generator = Generator(PaperSize.mm80, profile);
final result = await manager.printTicket([
  ...generator.text('ALGORAMMING CAFE', styles: const PosStyles(align: PosAlign.center, bold: true)),
  ...generator.text('Espresso .......... \$3.00'),
  ...generator.feed(2),
  ...generator.cut(),
]);
```

Each print opens the printer and closes it afterwards, so the system print queue can use it in between. To send several tickets in a row, pass `isDisconnect: false` and call `disconnect()` when done.

### 4. Save the printer and print later

```dart
// Save
settings['usbPrinter'] = jsonEncode(manager.selectedPrinter!.toJson());

// Later, without listing first
final printer = UsbPrinter.fromJson(jsonDecode(settings['usbPrinter']));
final manager = PrinterUsbManager(printer: printer);
await manager.printWidget(context, child: const MyReceipt());
```

Save `manager.selectedPrinter` after printing: when a printer was found again on another port, its id is updated there.

---

## 📚 API reference

### `PrinterUsbManager`

| Member | Description |
|---|---|
| `PrinterUsbManager({printer, paperSize = size80mm, profile, timeout = 20s, writeOptions})` | Create a manager. |
| `static UsbCapabilities capabilities` | `list`, `chooser` (WebUSB), `bridge`, `queues` on this platform. |
| `Future<List<UsbPrinter>> listPrinters({includeVirtual = false})` | Connected printers (and installed ones where supported), receipt printers first. |
| `List<UsbPrinterNote> notes` | What the last listing found worth telling the user. |
| `Future<UsbPrinter?> requestPrinter()` | Web: the browser's USB chooser. |
| `Future<UsbBridgeInfo> checkBridge()` | Web: whether the Local TCP bridge is installed, linked and new enough. |
| `Future<void> selectPrinter(UsbPrinter)` · `UsbPrinter? selectedPrinter` | The printer to print on. |
| `Future<PosPrintResult> connect({timeout})` · `disconnect({timeout})` | Open and close the printer (the print methods do it for you). |
| `Future<PosPrintResult> printTicket(List<int> data, {isDisconnect = true})` | Send raw ESC/POS bytes. |
| `Future<PosPrintResult> printWidget(context, {required child, isDisconnect = true, gapMm = 0})` | Render and print a widget. |
| `Object? lastError` · `PrintOutcome? lastPrint` | The underlying error, and size / time of the last print, for logs. |

### `UsbPrinter`

`id` (how to reach it; its prefix gives the `route`), `kind` (`device` or `queue`), `name`, `manufacturer`, `model`, `vendorId`, `productId`, `serialNumber`, `category` (`receipt` / `other` / `unknown`), `paperWidthMm` (a hint from the model name), and, from the latest listing, `commandSet`, `port`, `queueStatus`, `isDefault`, `isAccessible`, `isBusy`. `toJson` / `fromJson` save what identifies the printer; `findIn(list)` finds it again in a fresh list.

### `PosPrintResult`

Shared with the other two packages: `success`, `timeout`, `ticketEmpty`, `printInProgress`, `scanInProgress`, `disconnectError`, `unknown`. USB adds `printerNotSelected`, `printerNotConnected`, `connectionFailed`, `writeFailed`, `printerNotFound`, `printerBusy`, `permissionDenied`, `printerAccessRequired` (WebUSB: pick the printer again), `bridgeRequired`, `bridgeOutdated`, `unsupported`, `userCancelled`. Each has a readable `.msg`.

### `UsbWriteOptions`

| Option | Default | Meaning |
|---|---|---|
| `chunkSize` | 16 KB | Bytes per USB write. |
| `stallTimeout` | 10 s | How long the printer may take no data before the print fails. A long receipt is fine; only a stall counts. |
| `jobName` | `Receipt` | The title the system print queue shows. |

USB needs no pacing: a printer with a full buffer refuses data until it has room, and the write waits.

---

## 🏗️ How it works

```
PrinterUsbManager  (public API)
   │  UsbPlatform, picked at compile time
   ├── io:  Windows  → SetupAPI + overlapped WriteFile to usbprint.sys   (win-usb:…)
   │                → spooler StartDocPrinter RAW / XPS_PASS            (win-queue:…)
   │        macOS    → IOKit IOUSBInterfaceInterface, bulk OUT pipe     (mac-usb:…)
   │        Linux    → /dev/usb/lpN, non-blocking write + poll          (linux-usb:…)
   │        Android  → UsbManager + bulkTransfer (Kotlin, method channel) (android-usb:…)
   └── web: WebUSB   → navigator.usb, claimInterface + transferOut      (webusb:…)
            bridge   → window.postMessage ⇄ Local TCP USB_LIST/USB_PRINT (bridge:…)
```

Blocking writes run in a background isolate on the desktop, so the UI never freezes. The receipt raster pipeline is shared with the Bluetooth package: `ESC *` column bands, trimmed on the right, with zero line spacing so bands butt together without white lines.

---

## 🧰 Troubleshooting

| Symptom | Fix |
|---|---|
| macOS: `permissionDenied` | Add `com.apple.security.device.usb` to both entitlements files. |
| Android: `permissionDenied` | The user chose "Deny" in Android's dialog; print again and choose "Allow". |
| Android: no printer listed | Check the OTG cable/adapter and that the device supports USB host. |
| macOS: printer not listed | On Apple‑silicon Macs, allow the accessory when macOS asks the first time it is plugged in. |
| Linux: `permissionDenied` | `sudo usermod -aG lp $USER`, then log out and back in (or the udev rule above). |
| Linux: no printer, `usblpMissing` note | `sudo modprobe usblp`. |
| `printerBusy` | The system print queue is printing on it. The manager retries for a few seconds by itself. |
| `timeout` | Paper, cover, power. |
| Web on Windows/Linux: `bridgeRequired` / `bridgeOutdated` | Install or update the Local TCP extension and run its installer. |
| WebUSB: `printerAccessRequired` | Chrome forgets printers without a USB serial number after a restart; pick it again with `requestPrinter()`. |
| Windows: printer missing from the direct list | It is a vendor‑class printer: install its driver and pick the installed printer. |

---

## 🤝 Contributing

Bug reports and pull requests are welcome on the [GitHub repository](https://github.com/algonize/flutter_esc_pos_usb_universal).

## ⚖️ License

See [LICENSE](LICENSE).
