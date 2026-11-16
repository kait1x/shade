import 'dart:typed_data';
import 'package:image/image.dart' as img;

/// Used with compute: keep image decoding off the UI isolate and strip metadata.
Uint8List prepareMessageImage(Uint8List bytes) {
  img.Image? decoded;
  try {
    decoded = img.decodeImage(bytes);
  } catch (_) {
    throw const FormatException('Invalid image');
  }
  if (decoded == null) throw const FormatException('Invalid image');
  final oriented = img.bakeOrientation(decoded);
  final resized = oriented.width > 1280 || oriented.height > 1280
      ? img.copyResize(oriented,
          width: oriented.width >= oriented.height ? 1280 : null,
          height: oriented.height > oriented.width ? 1280 : null)
      : oriented;
  // Re-encoding alone preserves EXIF in image's JPEG encoder.
  resized.exif = img.ExifData();
  resized.iccProfile = null;
  resized.textData = null;
  return Uint8List.fromList(img.encodeJpg(resized, quality: 80));
}
