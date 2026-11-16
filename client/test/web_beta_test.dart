import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shade/main_web.dart';

void main() {
  for (final width in [320.0, 390.0, 430.0, 768.0]) {
    testWidgets('Web Beta fits $width width with large text and install guide',
        (tester) async {
      tester.view.physicalSize = Size(width, 844);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        tester.platformDispatcher.clearTextScaleFactorTestValue();
      });
      await tester.pumpWidget(const ShadeWebBeta());
      await tester.pumpAndSettle();
      expect(find.text('Переписка пока недоступна'), findsOneWidget);
      final install = find.text('Установить на iPhone');
      await tester.scrollUntilVisible(install, 300);
      await tester.tap(install);
      await tester.pumpAndSettle();
      expect(find.text('Установить Shade'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
