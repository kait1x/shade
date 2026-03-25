import 'package:flutter/material.dart';

/// Liquid glass ghost logo — frosted, translucent, glowing eyes.
class ShadeLogo extends StatelessWidget {
  final double size;

  const ShadeLogo({super.key, this.size = 80});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _GlassGhostPainter(),
      ),
    );
  }
}

class _GlassGhostPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width;
    final cx = s / 2;

    // ── Ghost body path ─────────────────────────────────
    final bodyPath = Path();
    bodyPath.moveTo(cx, s * 0.15);
    bodyPath.quadraticBezierTo(s * 0.85, s * 0.1, s * 0.82, s * 0.45);
    bodyPath.lineTo(s * 0.82, s * 0.58);
    // Wavy bottom
    bodyPath.quadraticBezierTo(s * 0.76, s * 0.68, s * 0.7, s * 0.6);
    bodyPath.quadraticBezierTo(s * 0.64, s * 0.7, s * 0.57, s * 0.6);
    bodyPath.quadraticBezierTo(s * 0.5, s * 0.7, s * 0.43, s * 0.6);
    bodyPath.quadraticBezierTo(s * 0.36, s * 0.7, s * 0.3, s * 0.6);
    bodyPath.quadraticBezierTo(s * 0.24, s * 0.68, s * 0.18, s * 0.58);
    bodyPath.lineTo(s * 0.18, s * 0.45);
    bodyPath.quadraticBezierTo(s * 0.15, s * 0.1, cx, s * 0.15);
    bodyPath.close();

    // ── Outer glow ─────────────────────────────────────
    final glowPaint = Paint()
      ..color = const Color(0xFF8B5CF6).withOpacity(0.06)
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, s * 0.06);
    canvas.drawPath(bodyPath, glowPaint);

    // ── Glass fill ─────────────────────────────────────
    final glassPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          Colors.white.withOpacity(0.14),
          Colors.white.withOpacity(0.04),
          const Color(0xFF8B5CF6).withOpacity(0.07),
          Colors.white.withOpacity(0.03),
        ],
        stops: const [0.0, 0.3, 0.7, 1.0],
      ).createShader(Rect.fromLTWH(0, 0, s, s));
    canvas.drawPath(bodyPath, glassPaint);

    // ── Highlight (top left reflection) ─────────────────
    final highlightPath = Path();
    highlightPath.moveTo(cx - s * 0.22, s * 0.24);
    highlightPath.quadraticBezierTo(
        cx - s * 0.05, s * 0.17, cx + s * 0.12, s * 0.26);
    highlightPath.quadraticBezierTo(
        cx - s * 0.05, s * 0.2, cx - s * 0.22, s * 0.24);
    highlightPath.close();

    final highlightPaint = Paint()..color = Colors.white.withOpacity(0.12);
    canvas.drawPath(highlightPath, highlightPaint);

    // ── Outline ─────────────────────────────────────────
    final outlinePaint = Paint()
      ..color = Colors.white.withOpacity(0.2)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0
      ..strokeCap = StrokeCap.round;
    canvas.drawPath(bodyPath, outlinePaint);

    // Soft violet glow outline
    final violetPaint = Paint()
      ..color = const Color(0xFF8B5CF6).withOpacity(0.25)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1.5);
    canvas.drawPath(bodyPath, violetPaint);

    // ── Eyes ────────────────────────────────────────────
    final eyeY = s * 0.37;
    final eyeSpacing = s * 0.14;
    final eyeRadius = s * 0.03;

    for (final sign in [-1.0, 1.0]) {
      final eyeX = cx + sign * eyeSpacing;

      // Soft glow
      final glowPaint = Paint()
        ..color = const Color(0xFF06B6D4).withOpacity(0.4)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, eyeRadius * 2.5);
      canvas.drawCircle(Offset(eyeX, eyeY), eyeRadius * 3, glowPaint);

      // Eye core
      final eyePaint = Paint()
        ..shader = RadialGradient(
          colors: [
            Colors.white,
            const Color(0xFF22D3EE),
            const Color(0xFF06B6D4).withOpacity(0.7),
          ],
          stops: const [0.0, 0.45, 1.0],
        ).createShader(
          Rect.fromCircle(center: Offset(eyeX, eyeY), radius: eyeRadius),
        );
      canvas.drawCircle(Offset(eyeX, eyeY), eyeRadius, eyePaint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
