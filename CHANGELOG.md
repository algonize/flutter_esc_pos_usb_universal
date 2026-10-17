# 1.0.0

- First release: ESC/POS printing on USB thermal printers from Windows, macOS, Linux and Chromium browsers, with the API of `flutter_esc_pos_network_universal` and `flutter_esc_pos_bluetooth_universal`.
- **Windows:** straight to the device through `usbprint.sys` (SetupAPI, overlapped writes with a stall timeout), and installed printers through the spooler (RAW, or XPS_PASS for v4 / XPS drivers).
- **macOS:** straight to the device through IOKit, from Dart (`dart:ffi`). Needs the `com.apple.security.device.usb` entitlement when sandboxed; a missing entitlement is reported as `permissionDenied` with a note.
- **Linux:** `/dev/usb/lp*` with non-blocking writes and `poll`, ids from sysfs that survive renumbering, notes for missing permissions and a missing `usblp` driver.
- **Web:** WebUSB on macOS and ChromeOS; the Local TCP bridge (2.1.2+, `USB_LIST` / `USB_PRINT`) on Windows and Linux.
- Printer discovery with IEEE 1284 Device IDs, receipt printers first, and `UsbPrinter.findIn` to find a printer again after a replug.
- `printWidget` with the Bluetooth package's raster pipeline (same dots as the network package, fewer bytes).
