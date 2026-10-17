# flutter_esc_pos_usb_universal example

Lists the USB printers (or opens the browser's USB chooser), and prints a widget receipt or a text ticket.

```bash
flutter run -d macos     # or windows, linux, android, chrome
```

- **macOS:** the USB entitlement is already in `macos/Runner/*.entitlements`.
- **Android:** use an OTG cable; Android asks once whether the app may use the printer. The example opens itself when a printer is plugged in (see `android/app/src/main/AndroidManifest.xml`).
- **Linux:** the user needs write access to `/dev/usb/lp*` (`sudo usermod -aG lp $USER`).
- **Web on Windows / Linux:** install the Local TCP extension and run its installer.

`integration_test/usb_printer_test.dart` lists the printers inside the real app and opens the first one without printing:

```bash
flutter test integration_test -d macos
```
