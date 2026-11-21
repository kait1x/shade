import 'dart:ui' as ui;
import 'package:flutter/material.dart';

import 'package:flutter/services.dart';
export 'vinyl_viewer.dart';
import 'legacy_print.dart' show drawPrint;

const stickerNames = {
  'flowers': 'Цветы в полутоне',
  'orbit': 'Орбита',
  'moth': 'Лунный мотылёк',
  'comet': 'Комета',
  'ghost': 'Полуночный гость'
};
Future<ui.Image> loadVinyl(String id) async {
  if (id == 'flowers') {
    final data = await rootBundle.load('assets/stickers/flowers.png');
    final codec = await ui.instantiateImageCodec(data.buffer.asUint8List(),
        targetWidth: 768);
    final frame = await codec.getNextFrame();
    codec.dispose();
    return frame.image;
  }
  final recorder = ui.PictureRecorder();
  drawPrint(Canvas(recorder), const Size.square(768), id);
  final pic = recorder.endRecording();
  final image = pic.toImageSync(768, 768);
  pic.dispose();
  return image;
}

Widget stamp(String id, {double size = 58}) =>
    SizedBox.square(dimension: size, child: _Stamp(id, size));

class _Stamp extends StatelessWidget {
  final String id;
  final double size;
  const _Stamp(this.id, this.size);
  @override
  Widget build(BuildContext context) {
    if (id == 'flowers') {
      // Decode at the device resolution the stamp actually paints at
      // (<=110 logical px): the 1254px source costs ~6 MB RAM per decode.
      final dpr = MediaQuery.devicePixelRatioOf(context);
      return Image.asset('assets/stickers/flowers.png',
          fit: BoxFit.contain,
          filterQuality: FilterQuality.medium,
          cacheWidth: (size * (dpr > 3 ? 3 : dpr)).round());
    }
    return CustomPaint(painter: _Legacy(id));
  }
}

class _Legacy extends CustomPainter {
  final String id;
  _Legacy(this.id);
  @override
  void paint(Canvas c, Size s) => drawPrint(c, s, id);
  @override
  bool shouldRepaint(_Legacy old) => old.id != id;
}
