import 'package:flutter/material.dart';

import '../theme/shade_theme.dart';
import 'shade_logo.dart';

/// Google's four-colour G, drawn in the original 24-unit coordinate system.
class _GoogleMark extends CustomPainter {
  const _GoogleMark();
  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 24, size.height / 24);
    final blue = Path()
      ..moveTo(21.6, 12.23)
      ..cubicTo(21.6, 11.52, 21.54, 10.84, 21.42, 10.18)
      ..lineTo(12, 10.18)
      ..lineTo(12, 14.05)
      ..lineTo(17.38, 14.05)
      ..cubicTo(17.15, 15.3, 16.44, 16.36, 15.38, 17.07)
      ..lineTo(15.38, 19.58)
      ..lineTo(18.61, 19.58)
      ..cubicTo(20.5, 17.84, 21.6, 15.28, 21.6, 12.23)
      ..close();
    final green = Path()
      ..moveTo(12, 22)
      ..cubicTo(14.7, 22, 16.96, 21.1, 18.61, 19.58)
      ..lineTo(15.38, 17.07)
      ..cubicTo(14.48, 17.67, 13.33, 18.04, 12, 18.04)
      ..cubicTo(9.39, 18.04, 7.18, 16.28, 6.39, 13.91)
      ..lineTo(3.05, 13.91)
      ..lineTo(3.05, 16.5)
      ..cubicTo(4.7, 19.76, 8.09, 22, 12, 22)
      ..close();
    final yellow = Path()
      ..moveTo(6.39, 13.91)
      ..cubicTo(6.19, 13.31, 6.07, 12.67, 6.07, 12)
      ..cubicTo(6.07, 11.33, 6.19, 10.69, 6.39, 10.09)
      ..lineTo(6.39, 7.5)
      ..lineTo(3.05, 7.5)
      ..cubicTo(2.38, 8.85, 2, 10.38, 2, 12)
      ..cubicTo(2, 13.62, 2.38, 15.15, 3.05, 16.5)
      ..close();
    final red = Path()
      ..moveTo(12, 5.96)
      ..cubicTo(13.47, 5.96, 14.78, 6.47, 15.82, 7.47)
      ..lineTo(18.68, 4.61)
      ..cubicTo(16.95, 3, 14.7, 2, 12, 2)
      ..cubicTo(8.09, 2, 4.7, 4.24, 3.05, 7.5)
      ..lineTo(6.39, 10.09)
      ..cubicTo(7.18, 7.72, 9.39, 5.96, 12, 5.96)
      ..close();
    for (final (path, color) in [
      (blue, 0xff4285f4),
      (green, 0xff34a853),
      (yellow, 0xfffbbc05),
      (red, 0xffea4335)
    ]) {
      canvas.drawPath(path, Paint()..color = Color(color));
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_GoogleMark oldDelegate) => false;
}

class ShadeGoogleButton extends StatelessWidget {
  const ShadeGoogleButton({super.key, required this.onPressed, this.progress});

  final VoidCallback? onPressed;
  final String? progress;

  @override
  Widget build(BuildContext context) {
    return FilledButton.icon(
      onPressed: progress == null ? onPressed : null,
      icon: progress == null
          ? const SizedBox.square(
              dimension: 20, child: CustomPaint(painter: _GoogleMark()))
          : const SizedBox.square(
              dimension: 18, child: CircularProgressIndicator(strokeWidth: 2)),
      label: Text(progress ?? 'Продолжить с Google'),
      style: FilledButton.styleFrom(
        backgroundColor: const Color(0xFFF1F1F1),
        foregroundColor: ShadeColors.black,
        minimumSize: const Size.fromHeight(52),
        textStyle: const TextStyle(
            fontFamily: 'Roboto', fontWeight: FontWeight.w700, fontSize: 14),
      ),
    );
  }
}

class ShadeWelcomeLayout extends StatelessWidget {
  const ShadeWelcomeLayout({
    super.key,
    required this.card,
    required this.footer,
    this.fillScreen = false,
  });

  final List<Widget> Function(bool compact) card;
  final List<Widget> footer;
  final bool fillScreen;

  @override
  Widget build(BuildContext context) {
    final viewport = MediaQuery.sizeOf(context);
    final compact = viewport.height < 740;
    final narrow = viewport.width < 360;
    final heroSize = compact && narrow ? 72.0 : 100.0;
    final padding = EdgeInsets.fromLTRB(
      24,
      compact ? 8 : 20,
      24,
      compact ? 8 : 28,
    );
    const wordmark = Row(children: [
      ShadeLogo(size: 30),
      SizedBox(width: 8),
      Text('shade',
          style: TextStyle(
              fontSize: 24, fontWeight: FontWeight.w700, letterSpacing: -1)),
    ]);
    final mainContent = <Widget>[
      Center(
        child: Container(
          width: heroSize,
          height: heroSize,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border:
                Border.all(color: ShadeColors.violet.withValues(alpha: .15)),
            color: ShadeColors.surfaceCard,
          ),
          child: Center(child: ShadeLogo(size: heroSize)),
        ),
      ),
      SizedBox(height: compact ? 6 : 14),
      Text('Свои люди.\nЛичные разговоры.',
          style: TextStyle(
            fontSize: narrow ? 27 : 36,
            fontWeight: FontWeight.w700,
            letterSpacing: -1.3,
            height: 1.12,
          )),
      SizedBox(height: compact ? 4 : 12),
      const Text('Место для ваших разговоров,\nфотографий и маленьких планов.',
          style: TextStyle(
              color: ShadeColors.textSecondary, fontSize: 15, height: 1.6)),
      SizedBox(height: compact ? 8 : 20),
      Container(
        padding: EdgeInsets.all(compact ? 16 : 20),
        decoration: BoxDecoration(
          color: ShadeColors.surfaceCard.withValues(alpha: .9),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: ShadeColors.greyBorder),
        ),
        child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: card(compact)),
      ),
    ];
    return Scaffold(
      body: ColoredBox(
        color: ShadeColors.black,
        child: SafeArea(
          child: LayoutBuilder(builder: (context, constraints) {
            final minimumHeight = fillScreen
                ? (constraints.maxHeight - padding.vertical)
                    .clamp(0.0, double.infinity)
                : 0.0;
            return Center(
              child: SingleChildScrollView(
                padding: padding,
                child: ConstrainedBox(
                  constraints:
                      BoxConstraints(maxWidth: 420, minHeight: minimumHeight),
                  child: Column(
                    mainAxisAlignment: fillScreen
                        ? MainAxisAlignment.spaceBetween
                        : MainAxisAlignment.start,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      wordmark,
                      Padding(
                        padding: EdgeInsets.only(
                            top: compact ? 4 : 16, bottom: compact ? 6 : 14),
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: mainContent),
                      ),
                      Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: footer),
                    ],
                  ),
                ),
              ),
            );
          }),
        ),
      ),
    );
  }
}
