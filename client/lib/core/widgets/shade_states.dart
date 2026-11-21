import 'package:flutter/material.dart';
import '../theme/shade_theme.dart';

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
  Widget build(BuildContext context) =>
      ColoredBox(color: Colors.black, child: child);
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
            margin: const EdgeInsets.only(top: 24, bottom: 18),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
            decoration: BoxDecoration(
                color: ShadeColors.surfaceDark,
                borderRadius: BorderRadius.circular(20)),
            child: Text(label,
                style: const TextStyle(
                    fontSize: 12,
                    color: ShadeColors.textSecondary,
                    fontWeight: FontWeight.w500))));
  }
}
