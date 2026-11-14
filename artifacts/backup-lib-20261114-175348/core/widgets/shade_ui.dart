import 'package:flutter/material.dart';
import 'package:shade/main.dart';

/// Consistent identity treatment; colors are deterministic, never an online badge.
class ShadeAvatar extends StatelessWidget {
  final String name;
  final double size;
  final String? imageUrl;
  final bool saved;
  const ShadeAvatar(
      {super.key,
      required this.name,
      this.size = 52,
      this.imageUrl,
      this.saved = false});
  @override
  Widget build(BuildContext context) {
    const palettes = [
      [Color(0xFF515151), Color(0xFF303030)],
      [Color(0xFF454545), Color(0xFF252525)],
      [Color(0xFF606060), Color(0xFF393939)],
      [Color(0xFF484848), Color(0xFF292929)],
    ];
    final index =
        name.runes.fold<int>(0, (sum, rune) => sum + rune) % palettes.length;
    final fallback = Center(
        child: saved
            ? Icon(Icons.bookmark_rounded,
                color: ShadeColors.violetLight, size: size * .44)
            : Text(
                name.isEmpty
                    ? '?'
                    : String.fromCharCode(name.runes.first).toUpperCase(),
                style: TextStyle(
                    fontSize: size * .37,
                    fontWeight: FontWeight.w700,
                    color: Colors.white)));
    return Semantics(
        label: saved ? 'Избранное' : 'Аватар $name',
        image: true,
        child: Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: saved
                        ? [const Color(0xFF353535), const Color(0xFF242424)]
                        : palettes[index]),
                border: Border.all(color: Colors.white.withValues(alpha: .07))),
            child: ClipOval(
                child: imageUrl == null
                    ? fallback
                    : Image.network(imageUrl!,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => fallback))));
  }
}

class ShadeEmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String description;
  final Widget? action;
  const ShadeEmptyState(
      {super.key,
      required this.icon,
      required this.title,
      required this.description,
      this.action});
  @override
  Widget build(BuildContext context) => Center(
      child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(
                padding: const EdgeInsets.all(22),
                decoration: BoxDecoration(
                    color: ShadeColors.surfaceCard,
                    borderRadius: BorderRadius.circular(28),
                    border: Border.all(color: ShadeColors.greyBorder)),
                child: Icon(icon, size: 32, color: ShadeColors.violetLight)),
            const SizedBox(height: 22),
            Text(title,
                textAlign: TextAlign.center,
                style:
                    const TextStyle(fontSize: 19, fontWeight: FontWeight.w700)),
            const SizedBox(height: 10),
            Text(description,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    color: ShadeColors.textSecondary,
                    fontSize: 14,
                    height: 1.6)),
            if (action != null) ...[const SizedBox(height: 20), action!],
          ])));
}

class ShadeConversationBackground extends StatelessWidget {
  final Widget child;
  const ShadeConversationBackground({super.key, required this.child});
  @override
  Widget build(BuildContext context) => DecoratedBox(
      decoration: const BoxDecoration(
          gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
            Color(0xFF111111),
            ShadeColors.black,
            Color(0xFF141414)
          ])),
      child: CustomPaint(painter: _ConversationPattern(), child: child));
}

class _ConversationPattern extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xFF404040).withValues(alpha: .24)
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;
    for (var y = 48.0; y < size.height; y += 104) {
      for (var x = 32.0; x < size.width; x += 104) {
        canvas.drawCircle(Offset(x, y), 2, paint);
        canvas.drawLine(Offset(x + 45, y + 42), Offset(x + 53, y + 50), paint);
        canvas.drawLine(Offset(x + 53, y + 42), Offset(x + 45, y + 50), paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class ShadeDateSeparator extends StatelessWidget {
  final DateTime date;
  const ShadeDateSeparator({super.key, required this.date});
  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final days = DateTime(now.year, now.month, now.day)
        .difference(DateTime(date.year, date.month, date.day))
        .inDays;
    final label = days == 0
        ? 'Сегодня'
        : days == 1
            ? 'Вчера'
            : '${date.day.toString().padLeft(2, '0')}.${date.month.toString().padLeft(2, '0')}.${date.year}';
    return Center(
        child: Container(
            margin: const EdgeInsets.only(top: 20, bottom: 16),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
            decoration: BoxDecoration(
                color: ShadeColors.surfaceCard.withValues(alpha: .8),
                borderRadius: BorderRadius.circular(20)),
            child: Text(label,
                style: const TextStyle(
                    fontSize: 11,
                    color: ShadeColors.textSecondary,
                    fontWeight: FontWeight.w500))));
  }
}
