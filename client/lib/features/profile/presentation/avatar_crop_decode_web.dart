import 'dart:js_interop';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:web/web.dart' as web;

/// Web decode path: ui.ImageDescriptor.width/height throw UnsupportedError on
/// web, so dimensions are probed with the browser's own decoder
/// (createImageBitmap) BEFORE Flutter allocates pixels — the same pre-decode
/// 32 Мп / 12000 px guard as native. instantiateImageCodec then downscales to
/// ≤2048 px during decode and exposes frameCount for the static-image guard.
Future<ui.Image> decodeGuardedAvatar(Uint8List bytes) async {
  final blob = web.Blob(<JSUint8Array>[bytes.toJS].toJS);
  final bitmap = await web.window.createImageBitmap(blob).toDart;
  final width = bitmap.width;
  final height = bitmap.height;
  bitmap.close();
  if (width * height > 32000000 || width > 12000 || height > 12000) {
    throw const FormatException(
        'Фотография слишком большая. Выберите изображение до 32 Мп');
  }
  final scale = math.min(1.0, 2048 / math.max(width, height));
  final codec = await ui.instantiateImageCodec(bytes,
      targetWidth: math.max(1, (width * scale).round()),
      targetHeight: math.max(1, (height * scale).round()));
  try {
    if (codec.frameCount != 1) {
      throw const FormatException('Выберите статичное изображение');
    }
    return (await codec.getNextFrame()).image;
  } finally {
    codec.dispose();
  }
}