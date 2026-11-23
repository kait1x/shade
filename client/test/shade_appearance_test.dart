import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shade/core/theme/shade_theme.dart';
import 'package:shade/core/widgets/shade_states.dart';
import 'package:shade/core/widgets/shade_tab_dock.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('light appearance updates shared screens and persists',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    await loadShadeAppearance();
    addTearDown(() => shadeLightTheme.value = false);
    const canvas = ValueKey('conversation canvas');

    await tester.pumpWidget(ValueListenableBuilder<bool>(
      valueListenable: shadeLightTheme,
      builder: (context, light, _) => MaterialApp(
        theme: light ? buildShadeLightTheme() : buildShadeTheme(),
        home: Scaffold(
          body: Column(children: [
            const ShadeAppearanceTile(),
            const ShadeConversationBackground(key: canvas, child: SizedBox()),
            ShadeTabDock(selectedIndex: 0, onSelected: (_) {}),
          ]),
        ),
      ),
    ));
    Color background() => tester
        .widget<ColoredBox>(find.descendant(
            of: find.byKey(canvas), matching: find.byType(ColoredBox)))
        .color;
    expect(background(), Colors.black);
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(background(), Colors.white);
    expect(tester.takeException(), isNull);
    shadeLightTheme.value = false;
    await loadShadeAppearance();
    expect(shadeLightTheme.value, isTrue);
  });
}
