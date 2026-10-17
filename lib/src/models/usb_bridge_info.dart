import 'package:flutter/foundation.dart';

import '../enums.dart';

/// The Local TCP bridge as [PrinterUsbManager.checkBridge] found it.
@immutable
class UsbBridgeInfo {
  const UsbBridgeInfo({
    required this.status,
    this.hostVersion,
    this.extensionVersion,
    this.platform,
    this.error,
  });

  static const notNeeded = UsbBridgeInfo(status: UsbBridgeStatus.notNeeded);

  final UsbBridgeStatus status;

  /// The installed native host's version, such as "2.1.2".
  final String? hostVersion;

  /// The browser extension's version.
  final String? extensionVersion;

  /// The computer the bridge runs on: `win`, `mac` or `linux`.
  final String? platform;

  /// Why the bridge is not ready, as the extension reported it.
  final String? error;

  bool get isReady => status == UsbBridgeStatus.ready;

  @override
  String toString() =>
      'UsbBridgeInfo(${status.name}, host: $hostVersion, extension: $extensionVersion, '
      'platform: $platform${error == null ? '' : ', error: $error'})';
}
