import 'package:flutter/material.dart';

/// Solid, scalable Shade mascot, readable even in the conversation header.
class ShadeLogo extends StatelessWidget {
  final double size;
  const ShadeLogo({super.key, this.size = 80});

  @override
  Widget build(BuildContext context) => Semantics(
      label: 'Shade — призрак',
      image: true,
      child: SizedBox(
          width: size,
          height: size,
          child: CustomPaint(painter: _ShadeGhostPainter())));
}

class _ShadeGhostPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 100, size.height / 100);
    final body = Path()
      ..moveTo(18, 48)
      ..cubicTo(18, 25, 31, 13, 50, 13)
      ..cubicTo(70, 13, 82, 27, 82, 48)
      ..cubicTo(82, 62, 86, 73, 88, 79)
      ..cubicTo(90, 86, 80, 90, 74, 85)
      ..lineTo(66, 79)
      ..cubicTo(61, 92, 49, 94, 43, 81)
      ..cubicTo(34, 92, 20, 91, 19, 80)
      ..cubicTo(18, 70, 18, 58, 18, 48)
      ..close();
    canvas.drawPath(
        body,
        Paint()
          ..shader = const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Color(0xFFFFFFFF), Color(0xFFE3E3E3)])
              .createShader(const Rect.fromLTWH(15, 13, 74, 80)));
    final ink = Paint()..color = const Color(0xFF181818);
    canvas.drawOval(const Rect.fromLTWH(32, 38, 11, 18), ink);
    canvas.drawOval(const Rect.fromLTWH(57, 36, 11, 18), ink);
    canvas.drawPath(
        Path()
          ..moveTo(44, 64)
          ..quadraticBezierTo(51, 70, 58, 62),
        Paint()
          ..color = const Color(0xFF181818)
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeWidth = 3.5);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _ShadeGhostPainter oldDelegate) => false;
}
