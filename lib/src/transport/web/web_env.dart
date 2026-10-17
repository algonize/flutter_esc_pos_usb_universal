import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:web/web.dart' as web;

/// The operating system the browser runs on. It decides how USB printers are
/// reached: WebUSB opens them on macOS and ChromeOS, but Windows and Linux keep
/// them for their own printer drivers, so there the Local TCP bridge prints.
enum BrowserOs { windows, macos, linux, chromeos, android, other }

BrowserOs get browserOs {
  final navigator = web.window.navigator as JSObject;
  String platform = '';
  if (navigator.has('userAgentData')) {
    final data = navigator.getProperty<JSObject?>('userAgentData'.toJS);
    final value = data?.getProperty<JSAny?>('platform'.toJS);
    if (value != null && value.isA<JSString>()) platform = (value as JSString).toDart;
  }
  final text = '$platform ${web.window.navigator.userAgent}'.toLowerCase();
  if (text.contains('android')) return BrowserOs.android;
  if (text.contains('windows')) return BrowserOs.windows;
  if (text.contains('cros') || text.contains('chrome os')) return BrowserOs.chromeos;
  if (text.contains('mac')) return BrowserOs.macos;
  if (text.contains('linux')) return BrowserOs.linux;
  return BrowserOs.other;
}

/// Whether a browser error is the DOMException named [name], such as
/// "NotFoundError". Matched on the error text, which works the same whether the
/// app is compiled to JavaScript or WebAssembly.
bool isDomError(Object error, String name) => error.toString().contains(name);
