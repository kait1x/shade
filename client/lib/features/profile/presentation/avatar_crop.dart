import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

import 'avatar_crop_decode_io.dart'
    if (dart.library.html) 'avatar_crop_decode_web.dart';

/// Source-space crop, shared by gesture preview and exported pixels.
class AvatarCrop {
  final ui.Size source;
  double zoom;
  ui.Offset center;
  AvatarCrop(this.source, {this.zoom = 1})
      : center = ui.Offset(source.width / 2, source.height / 2);
  double get side => math.min(source.width, source.height) / zoom;
  ui.Rect get rect =>
      ui.Rect.fromCenter(center: center, width: side, height: side);
  void setZoom(double value) {
    zoom = value.clamp(1, 4);
    _clamp();
  }

  void pan(ui.Offset delta, double viewport) {
    center -= delta * (side / viewport);
    _clamp();
  }

  void _clamp() {
    final half = side / 2;
    center = ui.Offset(center.dx.clamp(half, source.width - half),
        center.dy.clamp(half, source.height - half));
  }
}

Future<ui.Image> decodeAvatarSource(Uint8List bytes) async {
  if (bytes.length > 10 * 1024 * 1024) {
    throw const FormatException('Выберите фотографию до 10 МБ');
  }
  final png = bytes.length > 8 &&
      bytes[0] == 137 &&
      bytes[1] == 80 &&
      bytes[2] == 78 &&
      bytes[3] == 71;
  final jpeg =
      bytes.length > 3 && bytes[0] == 255 && bytes[1] == 216 && bytes[2] == 255;
  final webp = bytes.length > 12 &&
      String.fromCharCodes(bytes.take(4)) == 'RIFF' &&
      String.fromCharCodes(bytes.sublist(8, 12)) == 'WEBP';
  if (!png && !jpeg && !webp) {
    throw const FormatException('Поддерживаются JPEG, PNG и WebP');
  }
  // Platform decode: native probes dimensions via ImageDescriptor; web cannot
  // (UnsupportedError) and uses createImageBitmap + instantiateImageCodec.
  return decodeGuardedAvatar(bytes);
}

Uint8List _jpeg(Uint8List png) {
  final decoded = img.decodePng(png)!;
  // A fresh pixel image has no source EXIF, GPS, ICC or textual metadata.
  final clean =
      img.Image(width: decoded.width, height: decoded.height, numChannels: 3);
  img.compositeImage(clean, decoded);
  return Uint8List.fromList(img.encodeJpg(clean, quality: 85));
}

Future<Uint8List> exportAvatarCrop(ui.Image image, ui.Rect crop) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawColor(const ui.Color(0xFF111113), ui.BlendMode.src);
  canvas.drawImageRect(image, crop, const ui.Rect.fromLTWH(0, 0, 512, 512),
      ui.Paint()..filterQuality = ui.FilterQuality.high);
  final picture = recorder.endRecording();
  final output = await picture.toImage(512, 512);
  try {
    final data = await output.toByteData(format: ui.ImageByteFormat.png);
    return await compute(_jpeg, data!.buffer.asUint8List());
  } finally {
    output.dispose();
    picture.dispose();
  }
}
