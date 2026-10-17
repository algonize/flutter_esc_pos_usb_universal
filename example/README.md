# flutter_esc_pos_usb_universal example

Lists the USB printers (or opens the browser's USB chooser), and prints a widget receipt or a text ticket.

```bash
flutter run -d macos     # or windows, linux, chrome
```

- **macOS:** the USB entitlement is already in `macos/Runner/*.entitlements`.
- **Linux:** the user needs write access to `/dev/usb/lp*` (`sudo usermod -aG lp $USER`).
- **Web on Windows / Linux:** install the Local TCP extension and run its installer.

`integration_test/usb_printer_test.dart` lists the printers inside the real app and opens the first one without printing:

```bash
flutter test integration_test -d macos
```
