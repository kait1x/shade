import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shade/features/web/presentation/alpha_app.dart';
import 'package:shade/features/web/presentation/alpha_controller.dart';

void main() {
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
    expect(actions, contains('refresh'));
    // Directory mode replaces the empty headline.
    expect(find.text('Новый диалог'), findsOneWidget);
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
    // Self profile: logout needs an explicit confirmation.
    await tester.tap(find.byTooltip('Профиль'));
    await tester.pumpAndSettle();
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
    expect(find.text('Добавить имя'), findsOneWidget);
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
    await tester.tap(find.text('Добавить имя'));
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
      expect(find.text('Ключ шифрования'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      c.dispose();
    });
  }
}
