import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shade/features/chats/presentation/widgets/message_input.dart';
import 'package:shade/features/devices/data/alpha_v2_backend.dart';
import 'package:shade/features/devices/presentation/alpha_v2_screen.dart';

class FakeBackend implements AlphaV2Backend {
  bool session = false;
  bool isEnrolled = false;
  bool rotation = false;
  String? connectError;
  String? enrollError;
  List<Map<String, dynamic>> contactList = [];
  List<Map<String, dynamic>> messageList = [];
  List<String> sent = [];
  List<String> deleted = [];
  Map<String, dynamic>? lastReply;

  @override
  Future<void> initialize() async {}
  @override
  bool get hasSession => session;
  @override
  bool get enrolled => isEnrolled;
  @override
  String? get account => 'native_android';
  @override
  String? get ownGenesisDigest => isEnrolled ? 'ab' * 32 : null;
  @override
  int? get catalogRevision => isEnrolled ? 1 : null;
  @override
  int? get leaseExpiresAt =>
      isEnrolled ? DateTime.now().millisecondsSinceEpoch + 86400000 : null;
  @override
  Future<String> requestGoogleIdToken(String origin) async => 'synthetic-id-token';
  @override
  Future<void> connect(String origin, String idToken) async {
    if (connectError != null) throw StateError(connectError!);
    session = true;
  }

  @override
  Future<void> connectWithLegacyKey(String origin) async {
    if (connectError != null) throw StateError(connectError!);
    session = true;
  }

  @override
  Future<Map<String, dynamic>> enroll(String passphrase) async {
    if (enrollError != null) throw StateError(enrollError!);
    isEnrolled = true;
    return {
      'revision': 1,
      'recovery': {'version': 2, 'account': 'native_android', 'publicKey': 'synthetic'},
      if (rotation) 'rotated': true
    };
  }

  @override
  bool get rotationPending => rotation;

  @override
  Future<List<Map<String, dynamic>>> contacts() async => contactList;
  @override
  Future<void> confirmContact(String account, String digest) async {
    contactList.add({'account': account, 'genesisDigest': digest, 'confirmed': true});
  }

  @override
  Future<List<Map<String, dynamic>>> messages(String peer) async => messageList;
  @override
  Future<bool> peerUpgradeBlocked(String peer) async => false;
  @override
  Future<void> send(String peer, String text, {Map<String, dynamic>? reply}) async {
    sent.add(text);
    lastReply = reply;
    messageList.add({
      'ref': 'native_android:primary:sent${sent.length}',
      'peer': peer,
      'direction': 'out',
      'messageId': 'sent${sent.length}',
      'createdAt': DateTime.now().millisecondsSinceEpoch,
      'text': text,
      'reply': reply,
      'status': 'server',
      'acked': true
    });
  }

  @override
  Future<void> deleteLocal(String ref) async {
    deleted.add(ref);
    messageList.removeWhere((m) => m['ref'] == ref);
  }

  List<String> readRefs = [];
  List<String> retracted = [];
  List<String> typingSent = [];
  List<String> watched = [];
  List<List<int>> mediaSent = [];
  @override
  void Function(String account, int until)? onTyping;
  @override
  void Function(String account, bool online)? onPresence;
  @override
  Future<void> markRead(List<String> refs) async => readRefs.addAll(refs);
  @override
  Future<void> retract(String ref) async {
    retracted.add(ref);
    messageList.firstWhere((m) => m['ref'] == ref)['status'] = 'retracted';
  }

  @override
  Future<String> sendMedia(String peer, List<int> bytes,
      {String mime = 'image/jpeg'}) async {
    mediaSent.add(bytes);
    messageList.add({
      'ref': 'native_android:primary:media${mediaSent.length}',
      'peer': peer,
      'direction': 'out',
      'messageId': 'media${mediaSent.length}',
      'createdAt': DateTime.now().millisecondsSinceEpoch,
      'text': '',
      'reply': null,
      'status': 'server',
      'acked': true,
      'isImage': true,
      'imageData': Uint8List.fromList(bytes)
    });
    return 'media${mediaSent.length}';
  }

  @override
  void watch(String peer) => watched.add(peer);
  @override
  void unwatch(String peer) => watched.remove(peer);
  @override
  void sendTyping(String peer) => typingSent.add(peer);

  @override
  Future<int> sync() async => 0;
  @override
  Future<List<Map<String, dynamic>>> delivery(String ref) async =>
      [{'deviceId': 'webdevice', 'acknowledgedAt': 123}];
  @override
  Future<void> renewLease() async {}
  @override
  void dispose() {}
}

Widget _wrap(AlphaV2Backend backend) => ProviderScope(
    child: MaterialApp(
        theme: ThemeData.dark(), home: AlphaV2Screen(backend: backend)));

void main() {
  testWidgets('connect stage validates origin and advances to enrollment',
      (tester) async {
    final backend = FakeBackend();
    await tester.pumpWidget(_wrap(backend));
    await tester.pumpAndSettle();
    expect(find.text('Войти через Google'), findsOneWidget);

    await tester.tap(find.text('Войти через Google'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Укажите origin'), findsOneWidget);

    await tester.enterText(find.byType(TextField).first, 'https://alpha.test');
    await tester.tap(find.text('Войти через Google'));
    await tester.pumpAndSettle();
    expect(backend.session, true);
    expect(find.text('Регистрация устройства'), findsOneWidget);
  });

  testWidgets('legacy-key login (без Google) advances to enrollment',
      (tester) async {
    final backend = FakeBackend();
    await tester.pumpWidget(_wrap(backend));
    await tester.pumpAndSettle();
    expect(find.text('Войти ключом v1 (без Google)'), findsOneWidget);

    await tester.enterText(find.byType(TextField).first, 'https://alpha.test');
    await tester.tap(find.text('Войти ключом v1 (без Google)'));
    await tester.pumpAndSettle();
    expect(backend.session, true);
    expect(find.text('Регистрация устройства'), findsOneWidget);
  });

  testWidgets('enrollment requires a strong phrase and shows the recovery package',
      (tester) async {
    final backend = FakeBackend()..session = true;
    await tester.pumpWidget(_wrap(backend));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, 'short');
    await tester.tap(find.text('Зарегистрировать устройство'));
    await tester.pumpAndSettle();
    expect(find.textContaining('минимум 24 символа'), findsOneWidget);
    expect(backend.isEnrolled, false);

    await tester.enterText(
        find.byType(TextField).first, 'synthetic recovery phrase 24+');
    await tester.tap(find.text('Зарегистрировать устройство'));
    await tester.pumpAndSettle();
    expect(backend.isEnrolled, true);
    expect(find.text('Сохраните recovery-пакет'), findsOneWidget);
    expect(find.textContaining('"publicKey": "synthetic"'), findsOneWidget);

    await tester.tap(find.text('Я сохранил пакет и фразу'));
    await tester.pumpAndSettle();
    expect(find.text('@native_android'), findsOneWidget);
  });

  testWidgets('home lists confirmed contacts and validates the genesis dialog',
      (tester) async {
    final backend = FakeBackend()
      ..session = true
      ..isEnrolled = true
      ..contactList = [
        {'account': 'native_web', 'genesisDigest': 'cd' * 32, 'confirmed': true}
      ];
    await tester.pumpWidget(_wrap(backend));
    await tester.pumpAndSettle();
    expect(find.text('@native_web'), findsOneWidget);
    expect(find.textContaining('genesis сверен'), findsOneWidget);

    await tester.tap(find.text('Добавить'));
    await tester.pumpAndSettle();
    final dialogFields = find.descendant(
        of: find.byType(AlertDialog), matching: find.byType(TextField));
    await tester.enterText(dialogFields.at(0), 'Bad Name!');
    await tester.enterText(dialogFields.at(1), 'cd' * 32);
    await tester.tap(find.text('Сверить'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Аккаунт: 3–32'), findsOneWidget);

    await tester.tap(find.text('Добавить'));
    await tester.pumpAndSettle();
    await tester.enterText(dialogFields.at(0), 'second_web');
    await tester.enterText(dialogFields.at(1), 'ef' * 32);
    await tester.tap(find.text('Сверить'));
    await tester.pumpAndSettle();
    expect(backend.contactList.length, 2);
    expect(find.text('@second_web'), findsOneWidget);
  });

  testWidgets('chat renders reply/delivery, sends replies and deletes locally',
      (tester) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final backend = FakeBackend()
      ..session = true
      ..isEnrolled = true
      ..contactList = [
        {'account': 'native_web', 'genesisDigest': 'cd' * 32, 'confirmed': true}
      ]
      ..messageList = [
        {
          'ref': 'native_web:webdev:in1',
          'peer': 'native_web',
          'direction': 'in',
          'messageId': 'in1',
          'createdAt': now,
          'text': 'привет с Web',
          'reply': {'ref': 'r0', 'from': 'native_android', 'text': 'цитата'},
          'status': 'received',
          'acked': true
        },
        {
          'ref': 'native_android:primary:out1',
          'peer': 'native_web',
          'direction': 'out',
          'messageId': 'out1',
          'createdAt': now + 1,
          'text': 'привет с Android',
          'reply': null,
          'status': 'server',
          'acked': true
        }
      ];
    await tester.pumpWidget(_wrap(backend));
    await tester.pumpAndSettle();
    await tester.tap(find.text('@native_web'));
    await tester.pumpAndSettle();

    expect(find.text('привет с Web'), findsOneWidget);
    expect(find.text('привет с Android'), findsOneWidget);
    // Статус delivered (ACK 1/1) — иконка done_all; N/M передаётся в
    // semantics-метку MessageBubble.deliveryLabel.
    expect(find.byIcon(Icons.done_all_rounded), findsOneWidget);
    expect(find.text('цитата'), findsOneWidget);

    // Reply через long-press: панель цитаты и отправка с контрактом ZCODE.
    await tester.longPress(find.text('привет с Web'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ответить'));
    await tester.pumpAndSettle();
    expect(find.text('@native_web'), findsWidgets);
    await tester.enterText(
        find.descendant(
            of: find.byType(MessageInput), matching: find.byType(TextField)),
        'ответ');
    await tester.pumpAndSettle();
    final sendButton = tester.widget<IconButton>(
        find.byKey(const Key('send-message')));
    expect(sendButton.onPressed, isNotNull, reason: 'send button disabled');
    await tester.tap(find.byKey(const Key('send-message')));
    await tester.pumpAndSettle();
    expect(backend.sent, ['ответ']);
    expect(backend.lastReply, {
      'ref': 'native_web:webdev:in1',
      'from': 'native_web',
      'text': 'привет с Web'
    });

    // «Удалить у себя» removes the local copy only.
    await tester.longPress(find.text('привет с Web').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Удалить у себя'));
    await tester.pumpAndSettle();
    expect(backend.deleted, ['native_web:webdev:in1']);
    // Остаётся только цитата в reply отправленного сообщения.
    expect(find.text('привет с Web'), findsOneWidget);
  });

  testWidgets('favorites self-chat opens without contact confirmation',
      (tester) async {
    final backend = FakeBackend()
      ..session = true
      ..isEnrolled = true;
    await tester.pumpWidget(_wrap(backend));
    await tester.pumpAndSettle();
    expect(find.text('Избранное'), findsOneWidget);
    await tester.tap(find.text('Избранное'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.descendant(
            of: find.byType(MessageInput), matching: find.byType(TextField)),
        'заметка');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('send-message')));
    await tester.pumpAndSettle();
    expect(backend.sent, ['заметка']);
    expect(backend.contactList, isEmpty);
  });

  testWidgets('retract menu, read receipts and typing signal are wired',
      (tester) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final backend = FakeBackend()
      ..session = true
      ..isEnrolled = true
      ..contactList = [
        {'account': 'native_web', 'genesisDigest': 'cd' * 32, 'confirmed': true}
      ]
      ..messageList = [
        {
          'ref': 'native_web:webdev:in1',
          'peer': 'native_web',
          'direction': 'in',
          'messageId': 'in1',
          'createdAt': now,
          'text': 'входящее',
          'reply': null,
          'status': 'received',
          'acked': true
        },
        {
          'ref': 'native_android:primary:out1',
          'peer': 'native_web',
          'direction': 'out',
          'messageId': 'out1',
          'createdAt': now + 1,
          'text': 'исходящее',
          'reply': null,
          'status': 'server',
          'acked': true
        }
      ];
    await tester.pumpWidget(_wrap(backend));
    await tester.pumpAndSettle();
    await tester.tap(find.text('@native_web'));
    await tester.pumpAndSettle();
    // Presence watch and read receipts fired on open.
    expect(backend.watched, contains('native_web'));
    expect(backend.readRefs, contains('native_web:webdev:in1'));

    // Typing signal from the reused MessageInput.
    await tester.enterText(
        find.descendant(
            of: find.byType(MessageInput), matching: find.byType(TextField)),
        'печатаю');
    await tester.pumpAndSettle();
    expect(backend.typingSent, contains('native_web'));

    // Retract-for-all from the long-press menu.
    await tester.longPress(find.text('исходящее'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Отозвать у всех'));
    await tester.pumpAndSettle();
    expect(backend.retracted, ['native_android:primary:out1']);
    expect(find.text('Сообщение отозвано отправителем'), findsOneWidget);

    // Incoming typing hint renders the indicator.
    backend.onTyping?.call('native_web', now + 3000);
    await tester.pump();
    expect(find.text('печатает…'), findsOneWidget);
  });
}