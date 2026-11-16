import 'package:flutter/material.dart';
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
    final restored = AlphaController((_, __) async {});
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
