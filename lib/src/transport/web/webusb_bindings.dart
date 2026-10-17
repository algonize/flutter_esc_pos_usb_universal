// Minimal WebUSB bindings (https://wicg.github.io/webusb/). package:web does
// not ship them, and only this small part is needed: choose and list devices,
// open, claim, write, release. Web only.

import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:web/web.dart' as web;

/// `navigator.usb`, or null when the browser has no WebUSB (Firefox, Safari)
/// or the page is not served over HTTPS.
Usb? get navigatorUsb {
  final navigator = web.window.navigator as JSObject;
  if (!navigator.has('usb')) return null;
  return navigator.getProperty<JSObject?>('usb'.toJS) as Usb?;
}

extension type Usb._(JSObject _) implements JSObject {
  external JSPromise<UsbDevice> requestDevice(UsbDeviceRequestOptions options);
  external JSPromise<JSArray<UsbDevice>> getDevices();
}

extension type UsbDeviceRequestOptions._(JSObject _) implements JSObject {
  external factory UsbDeviceRequestOptions({JSArray<UsbDeviceFilter> filters});
}

extension type UsbDeviceFilter._(JSObject _) implements JSObject {
  /// Matches the device class or the class of any of its interfaces.
  external factory UsbDeviceFilter({int classCode});
}

extension type UsbDevice._(JSObject _) implements JSObject {
  external int get vendorId;
  external int get productId;
  external String? get manufacturerName;
  external String? get productName;
  external String? get serialNumber;
  external bool get opened;
  external UsbConfiguration? get configuration;
  external JSArray<UsbConfiguration> get configurations;

  external JSPromise<JSAny?> open();
  external JSPromise<JSAny?> close();
  external JSPromise<JSAny?> selectConfiguration(int configurationValue);
  external JSPromise<JSAny?> claimInterface(int interfaceNumber);
  external JSPromise<JSAny?> releaseInterface(int interfaceNumber);
  external JSPromise<JSAny?> selectAlternateInterface(int interfaceNumber, int alternateSetting);
  external JSPromise<JSAny?> clearHalt(String direction, int endpointNumber);
  external JSPromise<UsbOutTransferResult> transferOut(int endpointNumber, JSAny data);
  external JSPromise<UsbInTransferResult> controlTransferIn(
    UsbControlTransferParameters setup,
    int length,
  );
}

extension type UsbConfiguration._(JSObject _) implements JSObject {
  external int get configurationValue;
  external JSArray<UsbInterface> get interfaces;
}

extension type UsbInterface._(JSObject _) implements JSObject {
  external int get interfaceNumber;
  external UsbAlternateInterface get alternate;
  external JSArray<UsbAlternateInterface> get alternates;
  external bool get claimed;
}

extension type UsbAlternateInterface._(JSObject _) implements JSObject {
  external int get alternateSetting;
  external int get interfaceClass;
  external JSArray<UsbEndpoint> get endpoints;
}

extension type UsbEndpoint._(JSObject _) implements JSObject {
  external int get endpointNumber;

  /// "in" or "out".
  external String get direction;

  /// "bulk", "interrupt" or "isochronous".
  external String get type;
}

extension type UsbOutTransferResult._(JSObject _) implements JSObject {
  external int get bytesWritten;

  /// "ok", "stall" or "babble".
  external String get status;
}

extension type UsbInTransferResult._(JSObject _) implements JSObject {
  external JSDataView? get data;
  external String get status;
}

extension type UsbControlTransferParameters._(JSObject _) implements JSObject {
  external factory UsbControlTransferParameters({
    String requestType,
    String recipient,
    int request,
    int value,
    int index,
  });
}
