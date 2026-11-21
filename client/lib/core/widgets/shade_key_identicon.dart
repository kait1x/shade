import 'package:flutter/material.dart';

class ShadeKeyIdenticon extends StatelessWidget {
  final List<int> bytes;
  final double size;
  const ShadeKeyIdenticon({super.key, required this.bytes, required this.size});

  @override
  Widget build(BuildContext context) => ClipRRect(
      borderRadius: BorderRadius.circular(size > 100 ? 14 : 10),
      child: CustomPaint(
          size: Size.square(size), painter: _IdenticonPainter(bytes)));
}

class _IdenticonPainter extends CustomPainter {
  final List<int> bytes;
  _IdenticonPainter(this.bytes);

  static const _colors = [
    Color(0xFF2A2A2A),
    Color(0xFF5C5C5C),
    Color(0xFF9E9E9E),
    Color(0xFFEDEDED),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final cell = size.width / 8;
    final paint = Paint();
    for (var i = 0; i < 64; i++) {
      final byte = bytes[(i ~/ 2) % bytes.length];
      final nibble = i.isEven ? byte >> 4 : byte & 0x0F;
      paint.color = _colors[nibble & 0x03];
      canvas.drawRect(
          Rect.fromLTWH((i % 8) * cell, (i ~/ 8) * cell, cell + .5, cell + .5),
          paint);
    }
  }

  @override
  bool shouldRepaint(covariant _IdenticonPainter oldDelegate) =>
      oldDelegate.bytes != bytes;
}
