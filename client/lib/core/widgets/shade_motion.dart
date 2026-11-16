import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Short, shared transitions. No repeating work when system motion is disabled.
abstract final class ShadeMotion {
  static void selection(BuildContext context) {
    if (!MediaQuery.disableAnimationsOf(context) &&
        MediaQuery.maybeOf(context)?.accessibleNavigation != true) {
      HapticFeedback.selectionClick();
    }
  }

  static AnimationStyle sheet(BuildContext context) => AnimationStyle(
      duration: duration(context, 240),
      reverseDuration: duration(context, 180));

  static Duration duration(BuildContext context, [int milliseconds = 200]) =>
      MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : Duration(milliseconds: milliseconds);
}

class ShadeLoadingIndicator extends StatelessWidget {
  final double strokeWidth;
  final Color? color;
  const ShadeLoadingIndicator({super.key, this.strokeWidth = 2, this.color});
  @override
  Widget build(BuildContext context) => MediaQuery.disableAnimationsOf(context)
      ? Semantics(
          label: 'Загрузка',
          child: Icon(Icons.more_horiz_rounded, color: color, size: 22))
      : CircularProgressIndicator(strokeWidth: strokeWidth, color: color);
}

class ShadeMessageArrival extends StatelessWidget {
  final bool animate;
  final Widget child;
  const ShadeMessageArrival(
      {super.key, required this.animate, required this.child});

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
      tween: Tween(begin: animate ? 0 : 1, end: 1),
      duration: ShadeMotion.duration(context, 220),
      curve: Curves.easeOutCubic,
      child: child,
      builder: (context, value, child) => Opacity(
          opacity: value,
          child: Transform.translate(
              offset: Offset(0, 10 * (1 - value)), child: child)));
}

/// Keeps the existing button semantics and ink feedback while adding touch weight.
class ShadeTapScale extends StatefulWidget {
  final Widget child;
  const ShadeTapScale({super.key, required this.child});
  @override
  State<ShadeTapScale> createState() => _ShadeTapScaleState();
}

class _ShadeTapScaleState extends State<ShadeTapScale> {
  bool _pressed = false;
  @override
  Widget build(BuildContext context) => Listener(
      onPointerDown: (_) => setState(() => _pressed = true),
      onPointerUp: (_) => setState(() => _pressed = false),
      onPointerCancel: (_) => setState(() => _pressed = false),
      child: AnimatedScale(
          scale: _pressed && !MediaQuery.disableAnimationsOf(context) ? .97 : 1,
          duration: ShadeMotion.duration(context, 150),
          curve: Curves.easeOutCubic,
          child: widget.child));
}
