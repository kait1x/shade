import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:shade/core/services/message_image.dart';

void main() {
  test('message photo bakes orientation and removes identifying EXIF', () {
    final image = img.Image(width: 32, height: 16);
    image.exif.imageIfd['Make'] = 'Private camera';
    image.exif.imageIfd['Orientation'] = 6;
    final source = Uint8List.fromList(img.encodeJpg(image));
    expect(img.decodeJpg(source)!.exif.isEmpty, isFalse);
    final output = img.decodeJpg(prepareMessageImage(source))!;
    expect(output.width, 16);
    expect(output.height, 32);
    expect(output.exif.isEmpty, isTrue);
    expect(output.iccProfile, isNull);
  });

  test('message photo caps dimensions and rejects corrupt data', () {
    final image = img.Image(width: 1600, height: 800);
    final output = img.decodeJpg(
        prepareMessageImage(Uint8List.fromList(img.encodeJpg(image))))!;
    expect(output.width, 1280);
    expect(output.height, 640);
    expect(() => prepareMessageImage(Uint8List.fromList([1, 2, 3])),
        throwsFormatException);
  });
}
