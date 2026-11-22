import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shade/core/widgets/shade_chat_list.dart';
import 'package:shade/core/widgets/shade_tab_dock.dart';
import 'package:shade/core/widgets/shade_profile_layout.dart';
import 'package:shade/features/web/presentation/alpha_app.dart';
import 'package:shade/features/web/presentation/alpha_controller.dart';

void main() {
  testWidgets('mobile web uses the shared chat presentation and controls',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final calls = <String>[];
    final controller = AlphaController((action, _) async {
      calls.add(action);
      return null;
    });
    addTearDown(controller.dispose);
    controller.apply({
      'account': 'alice',
      'connected': true,
      'peers': [
        {'account': 'alice', 'favorites': true, 'pinned': true},
        {'account': 'bob', 'name': 'Боб', 'pinned': true},
      ],
      'messages': [
        {'from': 'bob', 'to': 'alice', 'createdAt': 1, 'text': 'Привет'},
      ],
    });
    await tester.pumpWidget(ShadeAlphaApp(controller: controller));
    await tester.pumpAndSettle();

    expect(find.byType(ShadeChatsHeader), findsOneWidget);
    expect(find.byType(ShadeComposeButton), findsOneWidget);
    expect(find.byType(ShadeTabDock), findsOneWidget);
    expect(find.byType(ShadeChatRow), findsNWidgets(2));
    expect(find.text('Боб'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'привет');
    await tester.pumpAndSettle();
    expect(find.byType(ShadeChatRow), findsOneWidget);
    await tester.tap(find.byTooltip('Очистить поиск'));
    await tester.pumpAndSettle();
    final header = find.byType(ShadeChatsHeader);
    await tester
        .tap(find.descendant(of: header, matching: find.text('Избранное')));
    await tester.pumpAndSettle();
    expect(find.byType(ShadeChatRow), findsOneWidget);
    expect(find.text('Боб'), findsNothing);

    await tester.tap(find.byTooltip('Скрыть поиск'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNothing);
    await tester.tap(find.byTooltip('Новый чат'));
    await tester.pumpAndSettle();
    expect(calls, contains('refresh'));
    expect(find.byType(ShadeChatsHeader), findsNothing);
    expect(tester.takeException(), isNull);
  });
  testWidgets('mobile web shares the profile header and actions with Android',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(375, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = AlphaController((action, _) async {
      if (action == 'stickers.load') {
        return {'revision': 0, 'inventory': [], 'wall': []};
      }
      return null;
    });
    addTearDown(controller.dispose);
    controller.apply({
      'account': 'alice',
      'profile': {'displayName': 'Alice'},
      'connected': true,
    });
    await tester.pumpWidget(ShadeAlphaApp(controller: controller));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Профиль'));
    await tester.pumpAndSettle();
    expect(find.byType(ShadeProfileHeader), findsOneWidget);
    expect(find.byType(ShadeAvatarEdit), findsOneWidget);
    expect(find.byType(ShadeProfileAction), findsNWidgets(3));
    expect(find.text('Alice'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.byTooltip('Назад'));
    await tester.pumpAndSettle();
    expect(find.byType(ShadeChatsHeader), findsOneWidget);
  });
}
