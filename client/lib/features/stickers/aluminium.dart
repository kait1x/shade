import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// A matte anodised lid. Paint is deterministic and scales with layout.
class AluminiumLid extends CustomPainter {
  final ui.Image? reference;
  const AluminiumLid({this.reference});
  @override
  void paint(Canvas c, Size s) {
    final r = RRect.fromRectAndRadius(
        Offset.zero & s, Radius.circular(s.width * .035));
    if (reference != null) {
      c.save();
      c.clipRRect(r);
      c.drawImageRect(reference!, const Rect.fromLTRB(28, 184, 1118, 944),
          Offset.zero & s, Paint()..filterQuality = FilterQuality.medium);
      c.restore();
      return;
    }
    c.drawShadow(Path()..addRRect(r), Colors.black87, 9, true);
    c.drawRRect(
        r,
        Paint()
          ..shader = ui.Gradient.linear(
              Offset.zero, Offset(s.width * .28, s.height), const [
            Color(0xffededf0),
            Color(0xffc8c9ce),
            Color(0xffb0b2b8),
            Color(0xff8f9198)
          ], [
            0,
            .32,
            .7,
            1
          ]));
    c.save();
    c.clipRRect(r);
    c.drawRect(
        Offset.zero & s,
        Paint()
          ..shader = ui.Gradient.radial(Offset(s.width * .22, s.height * .1),
              s.width * .85, const [Color(0x46ffffff), Color(0x00ffffff)]));
    final rng = math.Random(106);
    final ink = Paint()..strokeWidth = .35;
    for (var i = 0; i < 2200; i++) {
      final p = Offset(rng.nextDouble() * s.width, rng.nextDouble() * s.height);
      c.drawLine(
          p,
          p + Offset(.4 + rng.nextDouble(), 0),
          ink
            ..color =
                i.isEven ? const Color(0x0bffffff) : const Color(0x08000000));
    }
    c.restore();
    c.drawRRect(
        r.deflate(.7),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.3
          ..shader = ui.Gradient.linear(Offset.zero, Offset(0, s.height),
              const [Colors.white, Color(0xffa5a7ac)]));
    c.drawRRect(
        r.deflate(2),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = .5
          ..color = const Color(0x38ffffff));
  }

  @override
  bool shouldRepaint(AluminiumLid old) => old.reference != reference;
}

final lidImage = _loadLid();
Future<ui.Image> _loadLid() async {
  final bytes = await rootBundle.load('assets/stickers/lid-reference.png');
  final codec = await ui.instantiateImageCodec(bytes.buffer.asUint8List());
  final frame = await codec.getNextFrame();
  codec.dispose();
  return frame.image;
}

class ReferenceLid extends StatelessWidget {
  const ReferenceLid({super.key});
  @override
  Widget build(BuildContext context) => FutureBuilder<ui.Image>(
      future: lidImage,
      builder: (ctx, snapshot) =>
          CustomPaint(painter: AluminiumLid(reference: snapshot.data)));
}
