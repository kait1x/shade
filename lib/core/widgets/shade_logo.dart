import 'dart:math';
import 'package:flutter/material.dart';

/// Animated ghost logo with static/glitch outline and glowing eyes.
class ShadeLogo extends StatefulWidget {
  final double size;
  final bool animate;

  const ShadeLogo({
    super.key,
    this.size = 80,
    this.animate = true,
  });

  @override
  State<ShadeLogo> createState() => _ShadeLogoState();
}

class _ShadeLogoState extends State<ShadeLogo>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 3000),
    );
    if (widget.animate) _controller.repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          return CustomPaint(
            painter: _GhostPainter(
              progress: _controller.value,
              animate: widget.animate,
            ),
          );
        },
      ),
    );
  }
}

class _GhostPainter extends CustomPainter {
  final double progress;
  final bool animate;

  _GhostPainter({required this.progress, required this.animate});

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width;
    final center = Offset(s / 2, s / 2);
    final rand = Random(42); // deterministic seed

    // ── Glow under eyes ───────────────────────────────────
    final glowPaint = Paint()
      ..color = const Color(0xFF06B6D4).withOpacity(0.15)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 12);
    canvas.drawCircle(center.translate(0, -s * 0.08), s * 0.15, glowPaint);

    // ── Ghost body outline (erratic/glitch style) ─────────
    final bodyPoints = _generateGhostBody(s);

    for (int pass = 0; pass < 3; pass++) {
      final offset = animate
          ? Offset(
              (rand.nextDouble() - 0.5) * (1 + pass) * 0.8,
              (rand.nextDouble() - 0.5) * (1 + pass) * 0.4,
            )
          : Offset.zero;

      final alpha = pass == 0 ? 0.9 : (pass == 1 ? 0.3 : 0.15);
      final color = pass == 0
          ? const Color(0xFF8B5CF6)
          : pass == 1
              ? const Color(0xFF06B6D4)
              : const Color(0xFFA78BFA);

      final paint = Paint()
        ..color = color.withOpacity(alpha)
        ..style = PaintingStyle.stroke
        ..strokeWidth = pass == 0 ? 1.8 : 1.2
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;

      final path = Path();
      final movedPoints = bodyPoints
          .map((p) => Offset(p.dx + offset.dx, p.dy + offset.dy))
          .toList();

      path.moveTo(movedPoints.first.dx, movedPoints.first.dy);
      for (int i = 1; i < movedPoints.length; i++) {
        // Add jitter for static effect
        final jitter = animate
            ? Offset(
                (rand.nextDouble() - 0.5) * (pass == 0 ? 1.5 : 0.5),
                (rand.nextDouble() - 0.5) * (pass == 0 ? 1.0 : 0.3),
              )
            : Offset.zero;
        path.lineTo(
          movedPoints[i].dx + jitter.dx,
          movedPoints[i].dy + jitter.dy,
        );
      }
      path.close();
      canvas.drawPath(path, paint);
    }

    // ── Wavy bottom (ghost tail) ──────────────────────────
    for (int pass = 0; pass < 2; pass++) {
      final alpha = pass == 0 ? 0.7 : 0.2;
      final color =
          pass == 0 ? const Color(0xFF8B5CF6) : const Color(0xFF06B6D4);

      final paint = Paint()
        ..color = color.withOpacity(alpha)
        ..style = PaintingStyle.stroke
        ..strokeWidth = pass == 0 ? 1.8 : 1.0
        ..strokeCap = StrokeCap.round;

      final path = Path();
      final bottomY = s * 0.72;
      final waveAmplitude = s * 0.08;
      final segments = 8;

      path.moveTo(s * 0.2, bottomY);
      for (int i = 0; i <= segments; i++) {
        final x = s * 0.2 + (s * 0.6 / segments) * i;
        final yOffset = i.isEven ? -waveAmplitude : waveAmplitude * 0.6;
        final jitter = animate ? (rand.nextDouble() - 0.5) * 1.5 : 0.0;
        path.lineTo(x, bottomY + yOffset + jitter);
      }
      canvas.drawPath(path, paint);
    }

    // ── Eyes ─────────────────────────────────────────────
    final eyeY = center.dy - s * 0.1;
    final eyeSpacing = s * 0.12;
    final eyeRadius = s * 0.035;

    for (final eyeX in [center.dx - eyeSpacing, center.dx + eyeSpacing]) {
      // Outer glow
      final glowPaint = Paint()
        ..color = const Color(0xFF06B6D4).withOpacity(0.6)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6);
      canvas.drawCircle(Offset(eyeX, eyeY), eyeRadius * 1.5, glowPaint);

      // Inner bright dot
      final eyePaint = Paint()
        ..color = const Color(0xFF22D3EE)
        ..style = PaintingStyle.fill;
      canvas.drawCircle(Offset(eyeX, eyeY), eyeRadius, eyePaint);

      // White center
      final dotPaint = Paint()
        ..color = Colors.white
        ..style = PaintingStyle.fill;
      canvas.drawCircle(Offset(eyeX, eyeY), eyeRadius * 0.4, dotPaint);
    }
  }

  List<Offset> _generateGhostBody(double s) {
    final cx = s / 2;
    final topY = s * 0.2;
    final bottomY = s * 0.72;
    final width = s * 0.5;

    final points = <Offset>[];

    // Top dome
    for (int i = 0; i <= 20; i++) {
      final angle = pi + (pi / 20) * i;
      final x = cx + cos(angle) * (width / 2);
      final y = topY + s * 0.2 + sin(angle) * (s * 0.2);
      points.add(Offset(x, y));
    }

    // Right side
    points.add(Offset(cx + width / 2, bottomY));

    // Bottom (will be replaced by waves)
    points.add(Offset(cx + width / 2 - s * 0.05, bottomY + s * 0.02));
    points.add(Offset(cx - width / 2 + s * 0.05, bottomY + s * 0.02));

    // Left side
    points.add(Offset(cx - width / 2, bottomY));

    return points;
  }

  @override
  bool shouldRepaint(covariant _GhostPainter oldDelegate) {
    return animate && oldDelegate.progress != progress;
  }
}
