import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shade/core/widgets/shade_logo.dart';

// Renders the app icon set from the same mascot the UI uses, then verifies
// the adaptive-icon safe zone. Output lands in ../artifacts/icon/ and is
// copied into assets/ (icon.png + icon/) for flutter_launcher_icons.
const _background = Color(0xFF080808);
const _canvas = 1024.0;
// Android adaptive mask circle: 66/108 of the canvas, centred.
const _safeRadius = _canvas * 66 / 108 / 2;
// Ghost is painted inside a ShadeLogo-sized square; 700 leaves the whole
// silhouette (incl. wavy tail) well inside the mask circle.
const _foregroundSize = 700.0;

Future<ui.Image> _capture(WidgetTester tester, Widget child) async {
  tester.view.physicalSize = const Size(_canvas, _canvas);
  tester.view.devicePixelRatio = 1;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  final key = GlobalKey();
  await tester.pumpWidget(RepaintBoundary(
      key: key,
      child: MaterialApp(
          debugShowCheckedModeBanner: false, home: child)));
  await tester.pumpAndSettle();
  final boundary =
      tester.renderObject<RenderRepaintBoundary>(find.byKey(key));
  return boundary.toImage(pixelRatio: 1);
}

/// Bounding box of every pixel that differs from [background] plus its
/// farthest distance from the canvas centre — the numbers the safe-zone
/// checks use. Transparent layers pass [Color(0x00000000)].
Future<(Rect, double)> _alphaBounds(ui.Image image, Color background) async {
  final data =
      await image.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
  final bytes = data!.buffer.asUint8List();
  final w = image.width;
  double minX = w.toDouble(), minY = w.toDouble();
  double maxX = -1, maxY = -1;
  double farthest = 0;
  const c = _canvas / 2;
  final bgR = (background.r * 255).round(),
      bgG = (background.g * 255).round(),
      bgB = (background.b * 255).round();
  for (var y = 0; y < image.height; y++) {
    for (var x = 0; x < w; x++) {
      final i = (y * w + x) * 4;
      final differs = bytes[i + 3] > 8 &&
          (bytes[i] - bgR).abs() +
                  (bytes[i + 1] - bgG).abs() +
                  (bytes[i + 2] - bgB).abs() >
              12;
      if (differs) {
        if (x < minX) minX = x.toDouble();
        if (x > maxX) maxX = x.toDouble();
        if (y < minY) minY = y.toDouble();
        if (y > maxY) maxY = y.toDouble();
        farthest = math.max(
            farthest, math.sqrt((x - c) * (x - c) + (y - c) * (y - c)));
      }
    }
  }
  return (Rect.fromLTRB(minX, minY, maxX + 1, maxY + 1), farthest);
}

Future<void> _save(ui.Image image, String name) async {
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  final folder = Directory('../artifacts/icon');
  await folder.create(recursive: true);
  await File('${folder.path}/$name.png')
      .writeAsBytes(data!.buffer.asUint8List());
}

Widget _ghostSquare(double size, {bool silhouette = false}) => Center(
    child: SizedBox(
        width: size,
        height: size,
        child: CustomPaint(painter: ShadeGhostPainter(silhouette: silhouette))));

void main() {
  testWidgets('app icon set renders on #080808 and respects safe zones',
      (tester) async {
    // toImage/toByteData are real async work — they must all run inside
    // tester.runAsync or the fake-async test zone never sees them finish.
    await tester.runAsync(() async {
      // Full 1024 source: ghost on the Shade black, no text, no trim.
      final icon = await _capture(
          tester, ColoredBox(color: _background, child: _ghostSquare(_canvas)));
      expect(icon.width, 1024);
      expect(icon.height, 1024);
      await _save(icon, 'icon-1024');

      // Adaptive foreground: transparent, ghost inside the 66% mask circle.
      final foreground =
          await _capture(tester, _ghostSquare(_foregroundSize));
      await _save(foreground, 'adaptive-foreground');

      // Monochrome layer: white silhouette with features punched out.
      final mono = await _capture(tester,
          _ghostSquare(_foregroundSize, silhouette: true));
      await _save(mono, 'adaptive-monochrome');

      for (final (name, image, limit, edgeMargin, bg) in [
        // The full-bleed source is never drawn inside the adaptive mask —
        // only check it stays clear of the canvas edges. The adaptive layers
        // must fit the 66% mask circle.
        ('icon-1024', icon, 452.0, 60.0, _background),
        ('adaptive-foreground', foreground, _safeRadius, 0.0,
            const Color(0x00000000)),
        ('adaptive-monochrome', mono, _safeRadius, 0.0,
            const Color(0x00000000)),
      ]) {
        final (bounds, farthest) = await _alphaBounds(image, bg);
        final center = bounds.center;
        expect(farthest, lessThanOrEqualTo(limit),
            reason: '$name pokes out of the adaptive mask circle');
        // Content is centred and never clipped by the canvas edges.
        expect((center.dx - _canvas / 2).abs(), lessThan(6),
            reason: '$name is horizontally off-centre');
        expect((center.dy - _canvas / 2).abs(), lessThan(6),
            reason: '$name is vertically off-centre');
        expect(bounds.left, greaterThanOrEqualTo(edgeMargin),
            reason: '$name touches the left edge');
        expect(bounds.top, greaterThanOrEqualTo(edgeMargin),
            reason: '$name touches the top edge');
        expect(bounds.right, lessThanOrEqualTo(_canvas - edgeMargin),
            reason: '$name touches the right edge');
        expect(bounds.bottom, lessThanOrEqualTo(_canvas - edgeMargin),
            reason: '$name touches the bottom edge');
        debugPrint(
            '$name bounds=$bounds farthest=${farthest.toStringAsFixed(1)}px '
            '(limit ${limit.toStringAsFixed(0)}px)');
      }
    });
  });
}
