// Экран «Новый разговор» и TOFU-старт переписки: рендер по референсу,
// валидация никнейма, открытие чата без диалога ключа, бейдж «Ключ не сверен».
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shade/features/web/presentation/alpha_app.dart';
import 'package:shade/features/web/presentation/alpha_controller.dart';

void main() {
  void phone(WidgetTester tester) {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
  }

  // Проекция моста: избранное присутствует всегда, как в alpha-ui.mjs.
  Map<String, dynamic> projection({
    String? selected,
    List<Map<String, dynamic>> peers = const [],
    List<Map<String, dynamic>> messages = const [],
  }) =>
      <String, dynamic>{
        'account': 'alice',
        'selected': selected,
        'connected': true,
        'peers': [
          {
            'account': 'alice',
            'favorites': true,
            'pinned': true,
            'name': 'Избранное'
          },
          ...peers,
        ],
        'messages': messages,
      };

  Map<String, dynamic> hello(String from) => {
        'ref': '1',
        'from': from,
        'to': 'alice',
        'text': 'Привет',
        'createdAt': 1700000000000,
        'status': 'received',
        'devices': [],
      };

  PopScope popScope(WidgetTester tester) => tester
      .widget<PopScope>(find.byWidgetPredicate((w) => w is PopScope));

  testWidgets('FAB открывает экран «Новый разговор», а не каталог пользователей',
      (tester) async {
    phone(tester);
    final actions = <String>[];
    final c = AlphaController((action, payload) async {
      actions.add(action);
      return null;
    });
    c.apply(projection(peers: [
      {'account': 'bob', 'pinned': true},
      // Контакт из каталога без переписки не должен появляться в списке.
      {'account': 'stranger', 'pinned': false},
    ], messages: [
      hello('bob')
    ]));
    await tester.pumpWidget(ShadeAlphaApp(controller: c));
    await tester.pumpAndSettle();
    expect(find.text('Сообщения'), findsOneWidget);
    expect(find.text('stranger'), findsNothing);
    await tester.tap(find.text('Написать'));
    await tester.pumpAndSettle();
    // Референс нативного экрана: заголовок, крупный титул, описание, поле,
    // кнопка и информационный блок.
    expect(find.text('Новый разговор'), findsOneWidget);
    expect(find.text('Найдите своих'), findsOneWidget);
    expect(
        find.text(
            'Введите точный никнейм друга в Shade. Имена аккаунтов состоят из латинских букв, цифр и _.'),
        findsOneWidget);
    expect(find.text('Никнейм собеседника'), findsOneWidget);
    expect(find.text('Найти собеседника'), findsOneWidget);
    expect(find.text('Одно имя — и вы на связи'), findsOneWidget);
    expect(
        find.text(
            'Попросите друга поделиться никнеймом. Ваш собственный никнейм есть в профиле.'),
        findsOneWidget);
    // Каталог всех пользователей удалён из UI.
    expect(find.text('ПОЛЬЗОВАТЕЛИ SHADE'), findsNothing);
    expect(find.text('Новый диалог'), findsNothing);
    expect(find.text('stranger'), findsNothing);
    expect(actions, contains('refresh'));
    // Доступность: поле и кнопка подписаны для ассистивных технологий.
    expect(find.bySemanticsLabel(RegExp('Никнейм собеседника')), findsWidgets);
    expect(find.bySemanticsLabel('Найти собеседника'), findsWidgets);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });

  testWidgets('Кнопка поиска активна только при валидном никнейме',
      (tester) async {
    phone(tester);
    final c = AlphaController((_, __) async => null);
    c.apply(projection());
    await tester.pumpWidget(ShadeAlphaApp(controller: c));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Написать'));
    await tester.pumpAndSettle();
    bool enabled() => tester
        .widget<FilledButton>(find.byKey(const Key('new-chat-find')))
        .onPressed !=
        null;
    Future<void> enter(String text) async {
      await tester.enterText(find.byKey(const Key('new-chat-field')), text);
      await tester.pump();
    }

    expect(enabled(), isFalse);
    await enter('ab');
    expect(enabled(), isFalse);
    expect(
        find.text('От 3 до 32 символов: латинские буквы, цифры и _'),
        findsOneWidget);
    await enter('bad name');
    expect(enabled(), isFalse);
    await enter('привет');
    expect(enabled(), isFalse);
    await enter('a_b');
    expect(enabled(), isTrue);
    await enter('kait1x');
    expect(enabled(), isTrue);
    // Префикс @ и верхний регистр допустимы: мост нормализует никнейм.
    await enter('@Friend_2');
    expect(enabled(), isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });

  testWidgets('Find закрепляет контакт (TOFU) и открывает чат без диалога ключа',
      (tester) async {
    phone(tester);
    final actions = <Map<String, dynamic>>[];
    late final AlphaController c;
    c = AlphaController((action, payload) async {
      actions.add({'action': action, 'payload': payload});
      if (action == 'find') {
        // Мост отвечает проекцией: контакт закреплён, чат выбран.
        c.apply(projection(selected: payload['account'] as String, peers: [
          {'account': payload['account'], 'pinned': true, 'unverified': true},
        ]));
      }
      return null;
    });
    c.apply(projection(peers: [
      {'account': 'bob', 'pinned': true}
    ], messages: [
      hello('bob')
    ]));
    await tester.pumpWidget(ShadeAlphaApp(controller: c));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Написать'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const Key('new-chat-field')), '@Friend_2');
    await tester.pump();
    await tester.tap(find.byKey(const Key('new-chat-find')));
    await tester.pumpAndSettle();
    final findAction = actions.lastWhere((e) => e['action'] == 'find');
    expect((findAction['payload'] as Map)['account'], 'friend_2');
    // Чат открыт, композер доступен сразу — ручная сверка не требуется.
    expect(find.text('Новый разговор'), findsNothing);
    expect(find.byKey(const Key('message-field')), findsOneWidget);
    expect(find.text('Только между вами'), findsOneWidget);
    expect(find.text('Сверьте отпечаток ключа'), findsNothing);
    // Бейдж TOFU и кнопка сверки ведут в существующий verify-диалог.
    expect(find.text('Ключ не сверен'), findsOneWidget);
    await tester.tap(find.text('Сверить'));
    await tester.pumpAndSettle();
    final verify = actions.lastWhere((e) => e['action'] == 'verify');
    expect((verify['payload'] as Map)['account'], 'friend_2');
    // Отправка работает без каких-либо шагов обмена ключами.
    await tester.enterText(
        find.byKey(const Key('message-field')), 'Привет из нового чата');
    await tester.pump();
    await tester.tap(find.byKey(const Key('send-message')));
    await tester.pumpAndSettle();
    final send = actions.lastWhere((e) => e['action'] == 'send');
    expect((send['payload'] as Map)['account'], 'friend_2');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });

  testWidgets('Поиск показывает загрузку и не теряет экран при ожидании',
      (tester) async {
    phone(tester);
    final gate = Completer<void>();
    final c = AlphaController((action, payload) async {
      if (action == 'find') await gate.future;
      return null;
    });
    c.apply(projection());
    await tester.pumpWidget(ShadeAlphaApp(controller: c));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Написать'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('new-chat-field')), 'kait1x');
    await tester.pump();
    await tester.tap(find.byKey(const Key('new-chat-find')));
    await tester.pump();
    // Loading: кнопка заблокирована, поле недоступно, прогресс виден.
    expect(find.text('Ищем…'), findsOneWidget);
    expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('new-chat-find')))
            .onPressed,
        isNull);
    expect(
        tester
            .widget<TextField>(find.byKey(const Key('new-chat-field')))
            .enabled,
        isFalse);
    gate.complete();
    await tester.pumpAndSettle();
    expect(find.text('Новый разговор'), findsNothing);
    expect(find.text('Сообщения'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });

  testWidgets('Ошибки поиска честные: «Никнейм не найден» и «Нет сети»',
      (tester) async {
    phone(tester);
    var failure = 'Никнейм не найден';
    final c = AlphaController((action, payload) async {
      if (action == 'find') throw StateError(failure);
      return null;
    });
    c.apply(projection());
    await tester.pumpWidget(ShadeAlphaApp(controller: c));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Написать'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const Key('new-chat-field')), 'ghost_user');
    await tester.pump();
    await tester.tap(find.byKey(const Key('new-chat-find')));
    await tester.pumpAndSettle();
    expect(find.text('Никнейм не найден'), findsOneWidget);
    // Экран не закрывается, кнопка снова активна для повторной попытки.
    expect(find.text('Новый разговор'), findsOneWidget);
    expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('new-chat-find')))
            .onPressed,
        isNotNull);
    failure = 'Нет сети';
    await tester.enterText(find.byKey(const Key('new-chat-field')), 'ghost_2');
    await tester.pump();
    // Ввод очищает прошлую ошибку.
    expect(find.text('Никнейм не найден'), findsNothing);
    await tester.tap(find.byKey(const Key('new-chat-find')));
    await tester.pumpAndSettle();
    expect(find.text('Нет сети'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });

  testWidgets('TOFU-бейдж в профиле; старый контакт без trust считается сверенным',
      (tester) async {
    phone(tester);
    final actions = <Map<String, dynamic>>[];
    final c = AlphaController((action, payload) async {
      actions.add({'action': action, 'payload': payload});
      return null;
    });
    final data = projection(selected: 'bob', peers: [
      {'account': 'bob', 'pinned': true, 'unverified': true},
    ], messages: [
      hello('bob')
    ]);
    c.apply(data);
    await tester.pumpWidget(ShadeAlphaApp(controller: c));
    await tester.pumpAndSettle();
    expect(find.text('Ключ не сверен'), findsOneWidget);
    await tester.tap(find.text('Личная переписка'));
    await tester.pumpAndSettle();
    expect(find.text('Профиль собеседника'), findsOneWidget);
    expect(find.text('Ключ не сверен'), findsOneWidget);
    expect(
        find.textContaining('Закреплён автоматически при первом контакте'),
        findsOneWidget);
    await tester.tap(find.text('Сверить'));
    await tester.pumpAndSettle();
    expect(
        actions.where((e) => e['action'] == 'verify').length, 1);
    await tester.tap(find.byTooltip('Назад к переписке'));
    await tester.pumpAndSettle();
    // Обратная совместимость: контакт без флага unverified — сверенный.
    c.apply(projection(selected: 'bob', peers: [
      {'account': 'bob', 'pinned': true},
    ], messages: [
      hello('bob')
    ]));
    await tester.pumpAndSettle();
    expect(find.text('Ключ не сверен'), findsNothing);
    await tester.tap(find.text('Личная переписка'));
    await tester.pumpAndSettle();
    expect(find.text('Ключ собеседника проверен'), findsOneWidget);
    expect(find.text('Ключ не сверен'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });

  testWidgets('Назад с экрана поиска: кнопка, системный жест и пустой список',
      (tester) async {
    phone(tester);
    final actions = <String>[];
    final c = AlphaController((action, payload) async {
      actions.add(action);
      return null;
    });
    // Пустой список (без избранного в проекции) предлагает тот же экран поиска.
    c.apply(<String, dynamic>{
      'account': 'alice',
      'selected': null,
      'connected': true,
      'peers': <Map<String, dynamic>>[],
      'messages': <Map<String, dynamic>>[],
    });
    await tester.pumpWidget(ShadeAlphaApp(controller: c));
    await tester.pumpAndSettle();
    expect(find.text('Здесь начнётся общение'), findsOneWidget);
    await tester.tap(find.text('Найти собеседника'));
    await tester.pumpAndSettle();
    expect(find.text('Новый разговор'), findsOneWidget);
    expect(popScope(tester).canPop, isFalse);
    // Кнопка «Назад» возвращает к списку без bridge-действия back.
    await tester.tap(find.byTooltip('Назад'));
    await tester.pumpAndSettle();
    expect(find.text('Сообщения'), findsOneWidget);
    expect(actions, isNot(contains('back')));
    // Системный жест назад закрывает экран поиска, а не приложение.
    await tester.tap(find.text('Написать'));
    await tester.pumpAndSettle();
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    await navigator.maybePop();
    await tester.pumpAndSettle();
    expect(find.text('Новый разговор'), findsNothing);
    expect(find.text('Сообщения'), findsOneWidget);
    expect(actions, isNot(contains('back')));
    expect(popScope(tester).canPop, isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });

  testWidgets('Широкий макет: экран поиска заменяет правую панель, список жив',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final c = AlphaController((_, __) async => null);
    c.apply(projection(peers: [
      {'account': 'bob', 'pinned': true}
    ], messages: [
      hello('bob')
    ]));
    await tester.pumpWidget(ShadeAlphaApp(controller: c));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Написать'));
    await tester.pumpAndSettle();
    expect(find.text('Новый разговор'), findsOneWidget);
    expect(find.text('Сообщения'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });
}