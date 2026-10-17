import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_esc_pos_utils/flutter_esc_pos_utils.dart';
import 'package:image/image.dart' as img;
import 'package:screenshot/screenshot.dart';

import '../enums.dart';
import 'column_image.dart';

/// `ESC a 0`: left alignment. The bands are trimmed on the right, so they
/// must print left-aligned whatever alignment an earlier ticket left the
/// printer in (a centred band would shift by its own trimmed width). Then
/// `FS .`: cancel Kanji mode, as `Generator` sends before every style.
///
/// Deliberately no `ESC @` (initialise): it is not needed, and the network
/// and Bluetooth packages do not send it either.
const List<int> _ticketPrefix = [0x1b, 0x61, 0x30, 0x1c, 0x2e];

/// Renders [child] off screen and turns it into an ESC/POS ticket the way
/// `flutter_esc_pos_network_universal` and `flutter_esc_pos_bluetooth_universal`
/// do: one image as `ESC *` column bands, then a short feed and a cut.
/// Receipts print the same dots over Wi-Fi, Bluetooth and USB.
///
/// [gapMm] millimetres of blank paper are added below the receipt, inside the
/// image, so they come out on printers without a cutter too.
Future<Uint8List> buildWidgetTicket(
  BuildContext context,
  Widget child, {
  required ThermalPosPrinterPageSize paperSize,
  required CapabilityProfile profile,
  double gapMm = 0,
  bool scrubRealTime = true,
}) async {
  assert(gapMm >= 0);
  // 8 dots per millimetre, captured at one pixel per dot.
  final receipt = gapMm > 0
      ? Padding(
          padding: EdgeInsets.only(bottom: gapMm * 8),
          child: child,
        )
      : child;
  final image = await ScreenshotController().longWidgetToUiImage(
    InheritedTheme.captureAll(context, Material(color: Colors.white, child: receipt)),
    delay: const Duration(milliseconds: kIsWeb ? 500 : 200),
    context: context,
    // Without a width limit the widget is laid out at infinite width, and any
    // Row + Expanded (or other width-filling layout) fails to lay out. Cap it
    // at the print-head width so ordinary receipt layouts just work.
    constraints: BoxConstraints(maxWidth: paperSize.widthPx),
  );
  final width = image.width;
  final height = image.height;
  final ByteData? pixels;
  try {
    // Raw pixels rather than a PNG: they are always 8 bits per channel, even
    // where the screen captures 16 (wide colour on real iOS devices), which
    // is what garbled receipts printed from a PNG.
    pixels = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  } finally {
    image.dispose();
  }
  if (pixels == null) return Uint8List(0);
  return encodeTicketPixels(
    pixels.buffer.asUint8List(pixels.offsetInBytes, pixels.lengthInBytes),
    width,
    height,
    paperSize: paperSize,
    profile: profile,
    scrubRealTime: scrubRealTime,
  );
}

/// Encodes 8-bit RGBA pixels into an ESC/POS ticket: left alignment, the
/// image as column bands, a feed and a cut.
///
/// [scrubRealTime] drops the single dots that would spell a real-time command
/// in the image data (see `columnImageBands`).
@visibleForTesting
Uint8List encodeTicketPixels(
  Uint8List rgba,
  int width,
  int height, {
  required ThermalPosPrinterPageSize paperSize,
  required CapabilityProfile profile,
  bool scrubRealTime = true,
}) {
  if (width == 0 || height == 0) return Uint8List(0);

  // Keep within the print head; wider bitmaps desync the image command. The
  // widget is laid out at most this wide, so this is only a safeguard.
  final maxWidth = paperSize.widthPx.toInt();
  if (width > maxWidth) {
    final resized = img.copyResize(
      img.Image.fromBytes(
        width: width,
        height: height,
        bytes: rgba.buffer,
        bytesOffset: rgba.offsetInBytes,
        numChannels: 4,
      ),
      width: maxWidth,
    );
    rgba = resized.getBytes(order: img.ChannelOrder.rgba);
    width = resized.width;
    height = resized.height;
  }

  // A picture narrower than the head is padded to where centring would put it.
  final image = columnImageBands(
    rgba,
    width,
    height,
    leftPad: (maxWidth - width) ~/ 2,
    scrubRealTime: scrubRealTime,
  );
  final generator = Generator(paperSize.toPaperSize, profile);
  final bytes = BytesBuilder(copy: false)
    ..add(_ticketPrefix)
    ..add(image)
    ..add(generator.feed(2))
    ..add(generator.cut());
  return bytes.takeBytes();
}
