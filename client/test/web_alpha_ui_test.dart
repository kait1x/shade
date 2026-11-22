import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';
import 'package:shade/core/widgets/shade_tab_dock.dart';
import 'package:shade/features/stickers/aluminium.dart';
import 'package:shade/features/web/presentation/alpha_app.dart';
import 'package:shade/features/web/presentation/alpha_controller.dart';

void main() {
  // PopScope<T> runtime types are invariant in Dart, so find.byType(PopScope)
  // misses the PopScope<Object> that MaterialApp routes infer; the predicate
  // form matches every generic instantiation.
  PopScope popScope(WidgetTester tester) => tester
      .widget<PopScope>(find.byWidgetPredicate((w) => w is PopScope));

  test('Delivery is derived from real per-device ACK, never server acceptance',
      () {
    final message = <String, dynamic>{
      'status': 'accepted',
      'devices': [
        {'id': 'browser', 'acknowledgedAt': null}
      ]
    };
    expect(AlphaController.status(message), 'sent');
    expect(AlphaController.delivery(message), contains('ожидает ACK'));
    message['devices'] = [
      {'id': 'browser', 'acknowledgedAt': 123}
    ];
    expect(AlphaController.status(message), 'delivered');
    expect(AlphaController.delivery(message), 'Доставлено: 1/1 устройств');
    message['status'] = 'queued';
    message['devices'] = [];
    expect(AlphaController.status(message), 'queued');
    message['status'] = 'blocked';
    expect(AlphaController.status(message), 'blocked');
  });

  testWidgets('Reload restores the actual scroll offset in a tall lazy history',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    Map<String, dynamic>? position;
    final c = AlphaController((action, payload) async {
      if (action == 'position') position = {...payload};
      return null;
    });
    final data = <String, dynamic>{
      'account': 'alice',
      'selected': 'bob',
      'connected': true,
      'peers': [
        {'account': 'bob', 'pinned': true}
      ],
      'messages': [
        for (var i = 0; i < 8; i++)
          {
            'ref': '$i',
            'from': i.isEven ? 'alice' : 'bob',
            'to': i.isEven ? 'bob' : 'alice',
            'text': i == 4 ? 'Высокое сообщение\n' * 100 : 'Сообщение $i',
            'createdAt': 1700000000000 + i,
            'status': 'received',
            'devices': [],
          }
      ],
    };
    c.apply(data);
    await tester.pumpWidget(ShadeAlphaApp(controller: c));
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView), const Offset(0, 500));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 220));
    final before =
        tester.widget<ListView>(find.byType(ListView)).controller!.offset;
    expect(before, greaterThan(0));
    await tester.pumpWidget(const SizedBox());
    c.dispose();
    expect(position?['bottom'], false);
    final restored = AlphaController((_, __) async { return null; });
    restored.apply({
      ...data,
      'positions': {'bob': position}
    });
    await tester.pumpWidget(ShadeAlphaApp(controller: restored));
    await tester.pumpAndSettle();
    final after =
        tester.widget<ListView>(find.byType(ListView)).controller!.offset;
    expect(after, closeTo(before, .1));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    restored.dispose();
  });

  testWidgets('Alpha reply: long-press menu, composer preview and payload',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final actions = <Map<String, dynamic>>[];
    final c = AlphaController((action, payload) async {
      actions.add({'action': action, 'payload': payload});
      return null;
    });
    final data = <String, dynamic>{
      'account': 'alice',
      'selected': 'bob',
      'connected': true,
      'peers': [
        {'account': 'bob', 'pinned': true}
      ],
      'messages': [
        {
          'ref': '1',
          'from': 'bob',
          'to': 'alice',
          'text': 'Привет, как дела?',
          'createdAt': 1700000000000,
          'status': 'received',
          'devices': [],
        },
        {
          'ref': '2',
          'from': 'alice',
          'to': 'bob',
          'text': 'Всё хорошо',
          'createdAt': 1700000000001,
          'status': 'accepted',
          'devices': [],
        },
      ],
    };
    c.apply(data);
    await tester.pumpWidget(ShadeAlphaApp(controller: c));
    await tester.pumpAndSettle();
    await tester.longPress(find.text('Привет, как дела?'));
    await tester.pumpAndSettle();
    expect(find.text('Ответить'), findsOneWidget);
    expect(find.text('Удалить у себя'), findsOneWidget);
    await tester.tap(find.text('Ответить'));
    await tester.pumpAndSettle();
    // Reply preview bar with the original sender and snapshot text.
    expect(find.byTooltip('Отменить ответ'), findsOneWidget);
    await tester.enterText(
        find.byKey(const Key('message-field')), 'Вот ответ');
    await tester.pump();
    await tester.tap(find.byKey(const Key('send-message')));
    await tester.pumpAndSettle();
    final send = actions.lastWhere((entry) => entry['action'] == 'send');
    final reply = (send['payload'] as Map)['reply'] as Map;
    expect(reply['ref'], '1');
    expect(reply['from'], 'bob');
    expect(reply['text'], 'Привет, как дела?');
    // Preview clears after a successful dispatch.
    expect(find.byTooltip('Отменить ответ'), findsNothing);
    // Plain messages still render without a reply block.
    await tester.longPress(find.text('Всё хорошо'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ответить'));
    await tester.pumpAndSettle();
    expect(find.text('Вы'), findsOneWidget);
    await tester.tap(find.byTooltip('Отменить ответ'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Отменить ответ'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });

  testWidgets('Alpha deleteLocal dispatches the exact message ref',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final actions = <Map<String, dynamic>>[];
    final c = AlphaController((action, payload) async {
      if (action == 'deleteLocal') {
        throw StateError('Сеть недоступна');
      }
      actions.add({'action': action, 'payload': payload});
      return null;
    });
    final data = <String, dynamic>{
      'account': 'alice',
      'selected': 'bob',
      'connected': true,
      'peers': [
        {'account': 'bob', 'pinned': true}
      ],
      'messages': [
        {
          'ref': 'a:b:1',
          'from': 'bob',
          'to': 'alice',
          'text': 'Удаляемое сообщение',
          'createdAt': 1700000000000,
          'status': 'received',
          'devices': [],
        },
      ],
    };
    c.apply(data);
    await tester.pumpWidget(ShadeAlphaApp(controller: c));
    await tester.pumpAndSettle();
    await tester.longPress(find.text('Удаляемое сообщение'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Удалить у себя'));
    await tester.pumpAndSettle();
    // The failed action is reported honestly instead of a fake success.
    expect(find.byType(SnackBar), findsOneWidget);
    expect(find.textContaining('Не удалось удалить'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });

  testWidgets('Alpha peer profile opens from the chat header', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final actions = <Map<String, dynamic>>[];
    final c = AlphaController((action, payload) async {
      actions.add({'action': action, 'payload': payload});
      return null;
    });
    final data = <String, dynamic>{
      'account': 'alice',
      'selected': 'bob',
      'connected': true,
      'peers': [
        {'account': 'bob', 'pinned': true}
      ],
      'messages': [
        {
          'ref': '1',
          'from': 'bob',
          'to': 'alice',
          'text': 'Привет',
          'createdAt': 1700000000000,
          'status': 'received',
          'devices': [],
        },
      ],
    };
    c.apply(data);
    await tester.pumpWidget(ShadeAlphaApp(controller: c));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Личная переписка'));
    await tester.pumpAndSettle();
    expect(find.text('Профиль собеседника'), findsOneWidget);
    expect(find.text('Ключ собеседника проверен'), findsOneWidget);
    expect(find.text('1'), findsOneWidget);
    await tester.tap(find.text('Ключ собеседника проверен'));
    await tester.pumpAndSettle();
    expect(
        actions.where((entry) => entry['action'] == 'verify').length, 1);
    await tester.tap(find.byTooltip('Назад к переписке'));
    await tester.pumpAndSettle();
    expect(find.text('Профиль собеседника'), findsNothing);
    expect(find.byKey(const Key('message-field')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });

  testWidgets(
      'Alpha jump-to-latest counts unseen peer messages while scrolled away',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final c = AlphaController((_, __) async { return null; });
    final data = <String, dynamic>{
      'account': 'alice',
      'selected': 'bob',
      'connected': true,
      'peers': [
        {'account': 'bob', 'pinned': true}
      ],
      'messages': [
        for (var i = 0; i < 8; i++)
          {
            'ref': '$i',
            'from': i.isEven ? 'alice' : 'bob',
            'to': i.isEven ? 'bob' : 'alice',
            'text': i == 4 ? 'Высокое сообщение\n' * 100 : 'Сообщение $i',
            'createdAt': 1700000000000 + i,
            'status': 'received',
            'devices': [],
          }
      ],
    };
    // Restore chains and lazy list extents converge over scheduled frames;
    // post-frame callbacks alone do not schedule work for pumpAndSettle.
    Future<void> settle() async {
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
    }

    c.apply(data);
    await tester.pumpWidget(ShadeAlphaApp(controller: c));
    await settle();
    // At the latest message there is no jump button.
    expect(find.byKey(const Key('jump-to-latest')), findsNothing);
    await tester.drag(find.byType(ListView), const Offset(0, 500));
    await settle();
    expect(find.byKey(const Key('jump-to-latest')), findsOneWidget);
    // A peer message arrives while away: count it, no forced scroll.
    final incoming = {
      'ref': '8',
      'from': 'bob',
      'to': 'alice',
      'text': 'Ответ пока вы читали историю',
      'createdAt': 1700000000008,
      'status': 'received',
      'devices': [],
    };
    c.apply({
      ...data,
      'messages': [...(data['messages'] as List), incoming],
    });
    await settle();
    expect(
        find.byTooltip('Новых сообщений: 1. К последним'), findsOneWidget);
    await tester.tap(find.byKey(const Key('jump-to-latest')));
    await settle();
    expect(find.byKey(const Key('jump-to-latest')), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });

  testWidgets('Alpha chat list parity: 99+ cap, old-message dates, retry',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final actions = <String>[];
    final c = AlphaController((action, payload) async {
      actions.add(action);
      return null;
    });
    final semantics = tester.ensureSemantics();
    final now = DateTime.now();
    final yesterday =
        now.subtract(const Duration(days: 1)).millisecondsSinceEpoch;
    final messages = [
      for (var i = 0; i < 120; i++)
        {
          'ref': 'old-$i',
          'from': 'bob',
          'to': 'alice',
          'text': 'История $i',
          'createdAt': yesterday + i,
          'status': 'received',
          'devices': [],
        },
    ];
    c.apply(<String, dynamic>{
      'account': 'alice',
      'selected': null,
      'connected': false,
      'connection': 'Нет связи · история на устройстве',
      'peers': [
        {'account': 'bob', 'pinned': true}
      ],
      'messages': messages,
    });
    await tester.pumpWidget(ShadeAlphaApp(controller: c));
    await tester.pumpAndSettle();
    expect(find.text('99+'), findsOneWidget);
    // The full count stays available to assistive technology.
    expect(
        tester.widget<Text>(find.text('99+')).semanticsLabel,
        '120 непрочитанных');
    expect(find.text('Повторить'), findsOneWidget);
    await tester.tap(find.text('Повторить'));
    await tester.pumpAndSettle();
    expect(actions, contains('sync'));
    expect(tester.takeException(), isNull);
    semantics.dispose();
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });

  testWidgets('Alpha empty state opens the directory', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final actions = <String>[];
    final c = AlphaController((action, payload) async {
      actions.add(action);
      return null;
    });
    c.apply(<String, dynamic>{
      'account': 'alice',
      'connected': true,
      'peers': <Map<String, dynamic>>[],
      'messages': <Map<String, dynamic>>[],
    });
    await tester.pumpWidget(ShadeAlphaApp(controller: c));
    await tester.pumpAndSettle();
    expect(find.text('Здесь начнётся общение'), findsOneWidget);
    await tester.tap(find.text('Найти собеседника'));
    await tester.pumpAndSettle();
    // Empty-state action opens the «Новый разговор» screen (directory removed).
    expect(find.text('Новый разговор'), findsOneWidget);
    expect(find.text('Найдите своих'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });

  testWidgets('Alpha profile parity: logout confirm, copy nick, note',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final actions = <Map<String, dynamic>>[];
    final c = AlphaController((action, payload) async {
      actions.add({'action': action, 'payload': payload});
      return null;
    });
    final clipboard = <String, String>{};
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        clipboard['text'] = (call.arguments as Map)['text'] as String;
        return null;
      }
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));
    final data = <String, dynamic>{
      'account': 'alice',
      'selected': 'bob',
      'connected': true,
      'peers': [
        {'account': 'bob', 'pinned': true}
      ],
      'messages': [
        {
          'ref': '1',
          'from': 'bob',
          'to': 'alice',
          'text': 'Привет',
          'createdAt': 1700000000000,
          'status': 'received',
          'devices': [],
        },
      ],
      'devices': [
        {'id': 'd1', 'current': true}
      ],
    };
    c.apply(data);
    await tester.pumpWidget(ShadeAlphaApp(controller: c));
    await tester.pumpAndSettle();
    // Peer profile: copy nickname.
    await tester.tap(find.text('Личная переписка'));
    await tester.pumpAndSettle();
    expect(find.text('Профиль собеседника'), findsOneWidget);
    expect(find.text('Добавить заметку'), findsOneWidget);
    await tester.tap(find.text('Копировать ник'));
    await tester.pumpAndSettle();
    expect(find.text('Никнейм скопирован'), findsOneWidget);
    expect(clipboard['text'], 'bob');
    // Contact note round-trips through the encrypted client state action.
    await tester.tap(find.text('Добавить заметку'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.widgetWithText(TextField, 'Заметка о собеседнике'),
        'Работаем над проектом');
    await tester.tap(find.text('Сохранить'));
    await tester.pumpAndSettle();
    final note =
        actions.lastWhere((entry) => entry['action'] == 'note');
    final notePayload = note['payload'] as Map;
    expect(notePayload['account'], 'bob');
    expect(notePayload['text'], 'Работаем над проектом');
    // Back to the conversation, then to the chat list, before self profile.
    await tester.tap(find.byTooltip('Назад к переписке'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Назад к чатам'));
    await tester.pumpAndSettle();
    // Without the JS bridge the projection does not change on its own.
    c.apply({...data, 'selected': null});
    await tester.pumpAndSettle();
    final dock = find.byType(ShadeTabDock);
    Finder tab(String label) => find.descendant(of: dock, matching: find.text(label));
    await tester.tap(tab('Профиль'));
    await tester.pumpAndSettle();
    expect(tester.widget<ShadeTabDock>(dock).selectedIndex, 2);
    await tester.tap(tab('Настройки'));
    await tester.pumpAndSettle();
    expect(tester.widget<ShadeTabDock>(dock).selectedIndex, 1);
    // Logging out still requires confirmation after moving it to Settings.
    await tester.dragUntilVisible(
        find.text('Выйти из аккаунта'), find.byType(ListView).first,
        const Offset(0, -160));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Выйти из аккаунта'));
    await tester.pumpAndSettle();
    expect(find.text('Выйти из аккаунта?'), findsOneWidget);
    await tester.tap(find.text('Отмена'));
    await tester.pumpAndSettle();
    expect(
        actions.where((entry) => entry['action'] == 'logout').length, 0);
    await tester.tap(find.text('Выйти из аккаунта'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Выйти'));
    await tester.pumpAndSettle();
    expect(
        actions.where((entry) => entry['action'] == 'logout').length, 1);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });

  testWidgets('Alpha avatar editor saves frame through the profile adapter',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final actions = <Map<String, dynamic>>[];
    final c = AlphaController((action, payload) async {
      actions.add({'action': action, 'payload': payload});
      if (action == 'profile.avatar') return {'image': null};
      return null;
    });
    final data = <String, dynamic>{
      'account': 'alice',
      'selected': null,
      'connected': true,
      'peers': <Map<String, dynamic>>[],
      'messages': <Map<String, dynamic>>[],
      'profile': {
        'displayName': '',
        'frame': 'none',
        'digest': '',
        'revision': 0
      },
    };
    c.apply(data);
    await tester.pumpWidget(ShadeAlphaApp(controller: c));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Профиль'));
    await tester.pumpAndSettle();
    expect(find.text('Изменить аватар'), findsOneWidget);
    // The Android-parity action row replaced the 'Добавить имя' text button.
    expect(find.text('Имя'), findsOneWidget);
    expect(find.text('Копировать'), findsOneWidget);
    expect(find.text('Мой ключ'), findsOneWidget);
    await tester.tap(find.text('Изменить аватар'));
    await tester.pumpAndSettle();
    expect(find.text('Ваш образ в Shade'), findsOneWidget);
    await tester.tap(find.text('Silver'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Сохранить'));
    await tester.pumpAndSettle();
    final save = actions.lastWhere((entry) => entry['action'] == 'profile.save');
    final payload = save['payload'] as Map;
    expect(payload['frame'], 'silver');
    expect(payload.containsKey('avatar'), false);
    // The editor closes after a successful save.
    expect(find.text('Ваш образ в Shade'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });

  testWidgets('Alpha profile rename saves displayName via dialog',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final actions = <Map<String, dynamic>>[];
    final c = AlphaController((action, payload) async {
      actions.add({'action': action, 'payload': payload});
      return null;
    });
    c.apply(<String, dynamic>{
      'account': 'alice',
      'connected': true,
      'peers': <Map<String, dynamic>>[],
      'messages': <Map<String, dynamic>>[],
      'profile': {
        'displayName': 'Старое Имя',
        'frame': 'none',
        'digest': '',
        'revision': 0
      },
    });
    await tester.pumpWidget(ShadeAlphaApp(controller: c));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Профиль'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Имя'));
    await tester.pumpAndSettle();
    expect(find.text('Отображаемое имя'), findsOneWidget);
    await tester.enterText(
        find.descendant(
            of: find.byType(AlertDialog), matching: find.byType(TextField)),
        'Новое Имя');
    await tester.tap(find.text('Сохранить'));
    await tester.pumpAndSettle();
    final save = actions.lastWhere((entry) => entry['action'] == 'profile.save');
    expect((save['payload'] as Map)['displayName'], 'Новое Имя');
    expect(find.text('Отображаемое имя'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });

  // P1 regression: the photo-pick path must surface honest errors and a
  // working preview through the real editor pipeline (bytes-backed XFile,
  // no editor internals mocked).
  testWidgets('Alpha avatar editor surfaces the honest size limit',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final previous = ImagePickerPlatform.instance;
    addTearDown(() => ImagePickerPlatform.instance = previous);
    ImagePickerPlatform.instance = _StaticPhotoPlatform(
        Uint8List(11 * 1024 * 1024)); // over the 10 MB avatar limit
    final c = AlphaController((action, payload) async {
      if (action == 'profile.avatar') return {'image': null};
      return null;
    });
    c.apply(<String, dynamic>{
      'account': 'alice',
      'selected': null,
      'connected': true,
      'peers': <Map<String, dynamic>>[],
      'messages': <Map<String, dynamic>>[],
    });
    await tester.pumpWidget(ShadeAlphaApp(controller: c));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Профиль'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Изменить аватар'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Выбрать фото'));
    await tester.pumpAndSettle();
    expect(find.text('Выберите фотографию до 10 МБ'), findsOneWidget);
    expect(find.textContaining('Галерея недоступна'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });

  testWidgets('Alpha avatar editor shows a decoded pick and honest errors',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    // Static 64×64 PNG fixture (solid #3366AA). Runtime Picture.toImage +
    // Image.toByteData(png) can hang the flutter_tester engine, so the pick
    // bytes are a deterministic constant instead of an engine round-trip.
    final pngBytes = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAIAAAAlC+aJAAAAgElEQVR4nNXOQREAIAzAsFJLeEIcKhGxB9coyNrnUiZxEidxEidxEidxEidxEidxEidxEidxEidxEidxEidxEidxEidxEidxEidxEidxEidxEidxEidxEidxEidxEidxEidxEidxEidxEidxEidxEidxEidxEidxEidxEufvwNQDIkoBwwp8+ZgAAAAASUVORK5CYII=');
    final previous = ImagePickerPlatform.instance;
    addTearDown(() => ImagePickerPlatform.instance = previous);
    ImagePickerPlatform.instance = _StaticPhotoPlatform(pngBytes);
    final c = AlphaController((action, payload) async {
      if (action == 'profile.avatar') return {'image': null};
      return null;
    });
    c.apply(<String, dynamic>{
      'account': 'alice',
      'selected': null,
      'connected': true,
      'peers': <Map<String, dynamic>>[],
      'messages': <Map<String, dynamic>>[],
    });
    await tester.pumpWidget(ShadeAlphaApp(controller: c));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Профиль'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Изменить аватар'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Выбрать фото'));
    // The editor decodes through the real engine (ImageDescriptor/codec);
    // those callbacks only run outside FakeAsync, so give them real time
    // before settling (same pattern as avatar_system_test's runAsync capture).
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 500)));
    await tester.pumpAndSettle();
    // The decoded pick lands in the editor: the pick button switches to
    // 'Выбрать другое фото' and no error is shown.
    expect(find.text('Выбрать другое фото'), findsOneWidget);
    expect(find.textContaining('Галерея недоступна'), findsNothing);
    expect(find.textContaining('Не удалось открыть фото'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });

  testWidgets('Alpha profile name dialog round-trips the adapter',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final actions = <Map<String, dynamic>>[];
    final c = AlphaController((action, payload) async {
      actions.add({'action': action, 'payload': payload});
      if (action == 'profile.avatar') return {'image': null};
      return null;
    });
    final data = <String, dynamic>{
      'account': 'alice',
      'selected': null,
      'connected': true,
      'peers': <Map<String, dynamic>>[],
      'messages': <Map<String, dynamic>>[],
    };
    c.apply(data);
    await tester.pumpWidget(ShadeAlphaApp(controller: c));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Профиль'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Имя'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Алиса');
    await tester.tap(find.text('Сохранить'));
    await tester.pumpAndSettle();
    final save = actions.lastWhere((entry) => entry['action'] == 'profile.save');
    final payload = save['payload'] as Map;
    expect(payload['displayName'], 'Алиса');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });

  testWidgets('Alpha avatar bytes load once per digest', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    var avatarRequests = 0;
    final c = AlphaController((action, payload) async {
      if (action == 'profile.avatar') {
        avatarRequests++;
        return {'image': null};
      }
      return null;
    });
    final data = <String, dynamic>{
      'account': 'alice',
      'selected': null,
      'connected': true,
      'peers': <Map<String, dynamic>>[],
      'messages': <Map<String, dynamic>>[],
      'profile': {
        'displayName': 'Алиса',
        'frame': 'minimal',
        'digest': 'digest-1',
        'revision': 1
      },
    };
    c.apply(data);
    await tester.pumpWidget(ShadeAlphaApp(controller: c));
    await tester.pumpAndSettle();
    expect(avatarRequests, 1);
    // A projection with the same digest must not refetch the bytes.
    c.apply({...data, 'selected': 'bob', 'messages': [
      {
        'ref': '1',
        'from': 'bob',
        'to': 'alice',
        'text': 'Привет',
        'createdAt': 1700000000000,
        'status': 'received',
        'devices': [],
      }
    ]});
    await tester.pumpAndSettle();
    expect(avatarRequests, 1);
    // Changing the digest refetches.
    c.apply({...data, 'profile': {
      'displayName': 'Алиса',
      'frame': 'minimal',
      'digest': 'digest-2',
      'revision': 2
    }});
    await tester.pumpAndSettle();
    expect(avatarRequests, 2);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });

  testWidgets('Alpha sticker wall loads, saves and stays honest', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final actions = <Map<String, dynamic>>[];
    final c = AlphaController((action, payload) async {
      actions.add({'action': action, 'payload': payload});
      if (action == 'profile.avatar') return {'image': null};
      if (action == 'stickers.load') {
        return {
          'inventory': [],
          'wall': [],
          'revision': 3
        };
      }
      if (action == 'stickers.save') {
        return {
          'inventory': [],
          'wall': payload['wall'],
          'revision': 4
        };
      }
      return null;
    });
    final data = <String, dynamic>{
      'account': 'alice',
      'selected': null,
      'connected': true,
      'peers': <Map<String, dynamic>>[],
      'messages': <Map<String, dynamic>>[],
    };
    c.apply(data);
    await tester.pumpWidget(ShadeAlphaApp(controller: c));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Профиль'));
    await tester.pumpAndSettle();
    // The aluminium wall renders even with an empty inventory; the longer
    // parity profile scrolls the lazy list to it first. The load is
    // owner-scoped through the real adapter action.
    await tester.dragUntilVisible(find.byType(ReferenceLid),
        find.byType(ListView).first, const Offset(0, -300));
    await tester.pumpAndSettle();
    expect(find.byType(ReferenceLid), findsOneWidget);
    final load = actions.lastWhere((entry) => entry['action'] == 'stickers.load');
    expect((load['payload'] as Map)['owner'], true);
    // The gift entry point must not exist: the v2 contract is missing.
    expect(find.text('Подарить'), findsNothing);
    // The dev hint is gone in the shipped profile.
    expect(find.textContaining('Обмен подарками появится'), findsNothing);
    // Editing an empty wall saves a real revision through the adapter.
    await tester.dragUntilVisible(
        find.text('Оформить'), find.byType(ListView).first,
        const Offset(0, -200));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Оформить'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Готово'));
    await tester.pumpAndSettle();
    final save = actions.lastWhere((entry) => entry['action'] == 'stickers.save');
    final payload = save['payload'] as Map;
    expect(payload['revision'], 3);
    expect(payload['wall'], isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });

  for (final width in [320.0, 390.0, 430.0, 768.0, 1440.0]) {
    testWidgets('Alpha chat, list and profile fit $width with large text',
        (tester) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        tester.view.resetViewInsets();
        tester.platformDispatcher.clearTextScaleFactorTestValue();
      });
      final actions = <String>[];
      final c = AlphaController((action, payload) async {
        actions.add(action);
        return null;
      });
      final now = DateTime.now().millisecondsSinceEpoch;
      final data = <String, dynamic>{
        'account': 'alice',
        'connected': false,
        'connection': 'Нет сети · история сохранена',
        'selected': null,
        'peers': [
          {'account': 'long_username_12345678901234567890', 'pinned': true},
          {'account': 'directory_only', 'pinned': false},
        ],
        'messages': [
          {
            'ref': 'first',
            'from': 'long_username_12345678901234567890',
            'to': 'alice',
            'text': 'Длинное сообщение ${'безпробелов' * 90}',
            'createdAt': now,
            'status': 'received',
            'devices': []
          },
          {
            'ref': 'second',
            'from': 'alice',
            'to': 'long_username_12345678901234567890',
            'text': 'Ответ с сервера',
            'createdAt': now + 1,
            'status': 'accepted',
            'devices': []
          },
        ],
        'devices': [
          {'id': 'browser-device-id', 'current': true}
        ],
      };
      c.apply(data);
      await tester.pumpWidget(ShadeAlphaApp(controller: c));
      await tester.pumpAndSettle();
      expect(find.text('Сообщения'), findsOneWidget);
      expect(find.text('directory_only'), findsNothing);
      expect(tester.takeException(), isNull);
      c.apply({...data, 'selected': 'long_username_12345678901234567890'});
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('message-field')), findsOneWidget);
      expect(find.byIcon(Icons.done_all_rounded), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.enterText(find.byKey(const Key('message-field')),
          'Отправить из настоящего ввода');
      tester.view.viewInsets = const FakeViewPadding(bottom: 340);
      await tester.pumpAndSettle();
      expect(tester.getBottomRight(find.byKey(const Key('message-field'))).dy,
          lessThanOrEqualTo(560));
      await tester.tap(find.byKey(const Key('send-message')));
      await tester.pumpAndSettle();
      expect(actions, contains('send'));
      expect(tester.takeException(), isNull);
      tester.view.resetViewInsets();
      c.apply(data);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Профиль'));
      await tester.pumpAndSettle();
      // The longer parity profile scrolls the lazy list to the key card.
      await tester.dragUntilVisible(find.text('Ключ шифрования'),
          find.byType(ListView).first, const Offset(0, -300));
      await tester.pumpAndSettle();
      expect(find.text('Ключ шифрования'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      c.dispose();
    });
  }

  testWidgets('Alpha mobile: single pane navigation and system back to list',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final actions = <String>[];
    final c = AlphaController((action, payload) async {
      actions.add(action);
      return null;
    });
    final data = <String, dynamic>{
      'account': 'alice',
      'selected': null,
      'connected': true,
      'peers': [
        {'account': 'bob', 'pinned': true}
      ],
      'messages': [
        {
          'ref': '1',
          'from': 'bob',
          'to': 'alice',
          'text': 'Мобильная навигация',
          'createdAt': 1700000000000,
          'status': 'received',
          'devices': [],
        },
      ],
    };
    c.apply(data);
    await tester.pumpWidget(ShadeAlphaApp(controller: c));
    await tester.pumpAndSettle();
    // Narrow viewport shows the list only; the home screen allows a system pop.
    expect(find.text('Сообщения'), findsOneWidget);
    expect(find.byKey(const Key('message-field')), findsNothing);
    expect(popScope(tester).canPop, isTrue);
    // Opening a chat hides the list (single pane) and blocks the system pop,
    // so the Android back gesture returns to the list instead of leaving.
    c.apply({...data, 'selected': 'bob'});
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('message-field')), findsOneWidget);
    expect(find.text('Сообщения'), findsNothing);
    expect(popScope(tester).canPop, isFalse);
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    await navigator.maybePop();
    await tester.pumpAndSettle();
    expect(actions, contains('back'));
    // The JS projection acknowledges 'back' with selected: null.
    c.apply(data);
    await tester.pumpAndSettle();
    expect(find.text('Сообщения'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });

  testWidgets('Alpha wide layout keeps list and conversation side by side',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final actions = <String>[];
    final c = AlphaController((action, payload) async {
      actions.add(action);
      return null;
    });
    final data = <String, dynamic>{
      'account': 'alice',
      'selected': null,
      'connected': true,
      'peers': [
        {'account': 'bob', 'pinned': true}
      ],
      'messages': [
        {
          'ref': '1',
          'from': 'bob',
          'to': 'alice',
          'text': 'Двухпанельный макет',
          'createdAt': 1700000000000,
          'status': 'received',
          'devices': [],
        },
      ],
    };
    c.apply(data);
    await tester.pumpWidget(ShadeAlphaApp(controller: c));
    await tester.pumpAndSettle();
    expect(find.text('Сообщения'), findsOneWidget);
    expect(find.textContaining('Выберите диалог слева'), findsOneWidget);
    c.apply({...data, 'selected': 'bob'});
    await tester.pumpAndSettle();
    // Both panes stay mounted: the list header and the composer coexist.
    expect(find.text('Сообщения'), findsOneWidget);
    expect(find.byKey(const Key('message-field')), findsOneWidget);
    // The profile replaces only the right pane.
    await tester.tap(find.byTooltip('Профиль'));
    await tester.pumpAndSettle();
    // The longer parity profile scrolls the lazy list to the key card.
    await tester.dragUntilVisible(find.text('Ключ шифрования'),
        find.byType(ListView).first, const Offset(0, -300));
    await tester.pumpAndSettle();
    expect(find.text('Ключ шифрования'), findsOneWidget);
    expect(find.text('Сообщения'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });

  testWidgets('Alpha composer adapts maxLines to the keyboard viewport',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final c = AlphaController((_, __) async { return null; });
    final data = <String, dynamic>{
      'account': 'alice',
      'selected': 'bob',
      'connected': true,
      'peers': [
        {'account': 'bob', 'pinned': true}
      ],
      'messages': [
        {
          'ref': '1',
          'from': 'bob',
          'to': 'alice',
          'text': 'Композер',
          'createdAt': 1700000000000,
          'status': 'received',
          'devices': [],
        },
      ],
    };
    c.apply(data);
    await tester.pumpWidget(ShadeAlphaApp(controller: c));
    await tester.pumpAndSettle();
    int maxLines() => tester
        .widget<TextField>(find.byKey(const Key('message-field')))
        .maxLines!;
    expect(maxLines(), 5);
    // A raised keyboard is injected through MediaQuery directly: the test
    // binding moves the render surface for tester.view.viewInsets but keeps
    // MediaQuery.viewInsetsOf at zero, and the real browser delivers the
    // inset through MediaQuery.
    await tester.pumpWidget(MediaQuery(
        data: const MediaQueryData(viewInsets: EdgeInsets.only(bottom: 340)),
        child: ShadeAlphaApp(controller: c)));
    await tester.pumpAndSettle();
    expect(maxLines(), 3);
    await tester.pumpWidget(ShadeAlphaApp(controller: c));
    await tester.pumpAndSettle();
    expect(maxLines(), 5);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });
}

// Fake platform for the photo-pick regression tests: returns a self-contained
// XFile (bytes-backed) without touching the real gallery or the DOM input.
class _StaticPhotoPlatform extends ImagePickerPlatform {
  final Uint8List bytes;
  _StaticPhotoPlatform(this.bytes);
  @override
  Future<XFile?> getImageFromSource({
    required ImageSource source,
    ImagePickerOptions options = const ImagePickerOptions(),
  }) =>
      Future.value(XFile.fromData(bytes, name: 'avatar.png', mimeType: 'image/png'));
}
