import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

/// Native decode path: ImageDescriptor gives dimensions BEFORE allocating
/// pixels, so the 32 Мп / 12000 px guard runs pre-decode, and the codec
/// downscales to ≤2048 px during decode.
Future<ui.Image> decodeGuardedAvatar(Uint8List bytes) async {
  final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
  ui.ImageDescriptor? descriptor;
  ui.Codec? codec;
  try {
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    if (descriptor.width * descriptor.height > 32000000 ||
        descriptor.width > 12000 ||
        descriptor.height > 12000) {
      throw const FormatException(
          'Фотография слишком большая. Выберите изображение до 32 Мп');
    }
    final scale =
        math.min(1.0, 2048 / math.max(descriptor.width, descriptor.height));
    codec = await descriptor.instantiateCodec(
        targetWidth: math.max(1, (descriptor.width * scale).round()),
        targetHeight: math.max(1, (descriptor.height * scale).round()));
    if (codec.frameCount != 1) {
      throw const FormatException('Выберите статичное изображение');
    }
    return (await codec.getNextFrame()).image;
  } finally {
    codec?.dispose();
    descriptor?.dispose();
    buffer.dispose();
  }
}