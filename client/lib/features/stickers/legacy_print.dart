import 'dart:ui' as ui;
import 'package:flutter/material.dart';

const stickerNames = {
  'orbit': 'Орбита',
  'moth': 'Лунный мотылёк',
  'comet': 'Комета',
  'ghost': 'Полуночный гость'
};
const _tones = {
  'orbit': Color(0xff6254a5),
  'moth': Color(0xff346e69),
  'comet': Color(0xffb64d40),
  'ghost': Color(0xff394375)
};

void drawPrint(Canvas canvas, Size size, String id) {
  canvas.save();
  canvas.scale(size.width / 200, size.height / 200);
  final p = Paint();
  final paper = RRect.fromRectAndRadius(
      const Rect.fromLTWH(0, 0, 200, 200), const Radius.circular(20));
  canvas.clipRRect(paper);
  canvas.drawRRect(paper, p..color = Colors.white);
  final face = paper.deflate(3);
  canvas.clipRRect(face);
  canvas.drawRRect(
      face,
      p
        ..shader = ui.Gradient.linear(
            const Offset(20, 0),
            const Offset(165, 200),
            [_tones[id] ?? Colors.grey, const Color(0xff121423)]));
  p.shader = null;
  const gold = Color(0xffffdca8), milk = Color(0xfffff1d7);
  if (id == 'orbit') {
    canvas.drawCircle(const Offset(100, 99), 47, p..color = gold);
    canvas.save();
    canvas.translate(100, 100);
    canvas.rotate(-.4);
    canvas.drawArc(
        const Rect.fromLTWH(-78, -16, 156, 32),
        -.55,
        4.28,
        false,
        p
          ..color = const Color(0xffd6b2ff)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 8);
    canvas.restore();
    p.style = PaintingStyle.fill;
  } else if (id == 'moth') {
    for (final sign in [-1.0, 1.0]) {
      canvas.save();
      canvas.translate(100, 99);
      canvas.scale(sign, 1);
      final wing = Path()
        ..moveTo(0, 3)
        ..quadraticBezierTo(30, -48, 76, -47)
        ..quadraticBezierTo(68, -4, 39, 10)
        ..quadraticBezierTo(50, 48, 19, 54)
        ..close();
      canvas.drawPath(wing, p..color = milk);
      canvas.drawCircle(
          const Offset(42, -18), 11, p..color = const Color(0xff429a91));
      canvas.drawCircle(const Offset(42, -18), 5, p..color = gold);
      canvas.restore();
    }
    canvas.drawOval(const Rect.fromLTWH(95, 72, 10, 65), p..color = gold);
  } else if (id == 'comet') {
    final tail = Path()
      ..moveTo(45, 132)
      ..quadraticBezierTo(85, 97, 164, 40)
      ..quadraticBezierTo(136, 99, 71, 152)
      ..close();
    canvas.drawPath(tail, p..color = gold);
    canvas.drawCircle(const Offset(67, 130), 23, p..color = milk);
    canvas.drawCircle(
        const Offset(58, 124), 5, p..color = const Color(0xffcc8979));
  } else {
    final ghost = Path()
      ..moveTo(51, 145)
      ..lineTo(56, 93)
      ..cubicTo(59, 34, 139, 34, 145, 94)
      ..lineTo(152, 145)
      ..quadraticBezierTo(139, 132, 125, 148)
      ..quadraticBezierTo(109, 130, 94, 147)
      ..quadraticBezierTo(75, 132, 51, 145);
    canvas.drawPath(ghost, p..color = milk);
    for (final x in [84.0, 112.0]) {
      canvas.drawOval(
          Rect.fromLTWH(x, 86, 10, 17), p..color = const Color(0xff25283c));
    }
  }
  canvas.restore();
}
