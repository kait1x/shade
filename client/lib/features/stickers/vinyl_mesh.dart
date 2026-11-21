import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';

/// A cylindrical fold sampled into textured triangles. Both sides share
/// the original alpha silhouette, including the printed note on the reverse.
class VinylMesh extends CustomPainter {
  final ui.Image front, back;
  final Offset axis, tilt;
  final double peel;
  VinylMesh(this.front, this.back, this.axis, this.peel, this.tilt);
  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, inset = w * .21, art = w * .58;
    canvas.save();
    canvas.translate(inset, w * .235);
    final projections = [
      const Offset(0, 0),
      Offset(art, 0),
      Offset(0, art),
      Offset(art, art)
    ].map((p) => p.dx * axis.dx + p.dy * axis.dy);
    final minimum = projections.reduce(math.min), fold = minimum + peel * art;
    final radius = art * .07;
    final flat = <Offset>[],
        reverse = <Offset>[],
        flatUv = <Offset>[],
        reverseUv = <Offset>[];
    final flatColors = <Color>[], reverseColors = <Color>[];
    (Offset, bool, double) project(Offset p) {
      final u = fold - (p.dx * axis.dx + p.dy * axis.dy);
      if (u <= 0 || peel <= .0001) return (p, false, 1);
      final theta = math.min(math.pi, u / radius),
          tail = math.max(0.0, u - math.pi * radius);
      final mapped = fold - radius * math.sin(theta) + tail;
      final elevation = radius * (1 - math.cos(theta));
      final displacement = mapped - (p.dx * axis.dx + p.dy * axis.dy);
      return (
        p + axis * displacement + Offset(0, -elevation * .55),
        theta > math.pi / 2,
        .79 + .21 * math.cos(theta).abs()
      );
    }

    const cells = 42;
    for (var y = 0; y < cells; y++) {
      for (var x = 0; x < cells; x++) {
        final points = [
          Offset(x * art / cells, y * art / cells),
          Offset((x + 1) * art / cells, y * art / cells),
          Offset((x + 1) * art / cells, (y + 1) * art / cells),
          Offset(x * art / cells, (y + 1) * art / cells)
        ];
        for (final indices in [
          [0, 1, 2],
          [0, 2, 3]
        ]) {
          final midpoint =
              indices.map((i) => points[i]).reduce((a, b) => a + b) / 3;
          final (_, isBack, brightness) = project(midpoint);
          for (final i in indices) {
            final p = project(points[i]).$1;
            (isBack ? reverse : flat).add(p);
            (isBack ? reverseUv : flatUv).add(points[i] * (front.width / art));
            final light = (brightness * 255).round();
            (isBack ? reverseColors : flatColors)
                .add(Color.fromARGB(255, light, light, light));
          }
        }
      }
    }
    void layer(ui.Image image, List<Offset> vertices, List<Offset> uv,
        List<Color> colors,
        {bool shadow = false}) {
      if (vertices.isEmpty) return;
      final paint = Paint()
        ..filterQuality = FilterQuality.medium
        ..shader = ui.ImageShader(
            image, TileMode.clamp, TileMode.clamp, Matrix4.identity().storage);
      if (shadow) {
        paint.colorFilter =
            const ColorFilter.mode(Color(0x65000000), BlendMode.srcIn);
        paint.maskFilter = MaskFilter.blur(BlurStyle.normal, art * .025);
      }
      final mesh = ui.Vertices(ui.VertexMode.triangles, vertices,
          textureCoordinates: uv, colors: shadow ? null : colors);
      canvas.drawVertices(mesh, BlendMode.modulate, paint);
      mesh.dispose();
    }

    canvas.save();
    canvas.translate(0, art * .015);
    layer(front, flat, flatUv, flatColors, shadow: true);
    layer(back, reverse, reverseUv, reverseColors, shadow: true);
    canvas.restore();
    canvas.saveLayer(
        Rect.fromLTWH(-art * .2, -art * .2, art * 1.6, art * 1.6), Paint());
    layer(front, flat, flatUv, flatColors);
    layer(back, reverse, reverseUv, reverseColors);
    final light = art * (.35 + tilt.dx * .4 + tilt.dy * .2);
    canvas.drawRect(
        Rect.fromLTWH(-art * .2, -art * .2, art * 1.6, art * 1.6),
        Paint()
          ..blendMode = BlendMode.srcATop
          ..shader = ui.Gradient.linear(
              Offset(light - art * .2, 0),
              Offset(light + art * .5, art),
              const [Colors.transparent, Color(0x22ffffff), Colors.transparent],
              [0, .5, 1]));
    canvas.restore();
    canvas.restore();
  }

  @override
  bool shouldRepaint(VinylMesh old) =>
      old.peel != peel ||
      old.tilt != tilt ||
      old.front != front ||
      old.back != back ||
      old.axis != axis;
}
