/// Widget-тесты native v2 UI на fake sync-сервисе плюс интеграционный тест
/// offline-очереди на РЕАЛЬНЫХ V2Store (SQLCipher ffi) + V2ChatRepository +
/// scripted transport: идемпотентный повтор тем же ciphertext/ID, статусы
/// queued/blocked/sent, отсутствие дублей после повторных sync-циклов.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:fast_rsa/fast_rsa.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shade/core/database/database_service.dart';
import 'package:shade/core/services/crypto_service.dart';
import 'package:shade/core/services/device_v2/crypto.dart';
import 'package:shade/core/services/device_v2/protocol.dart';
import 'package:shade/core/services/device_v2/repository.dart';
import 'package:shade/core/services/device_v2/store.dart';
import 'package:shade/core/services/device_v2/sync.dart';
import 'package:shade/core/services/device_v2/transport.dart';
import 'package:shade/core/theme/shade_theme.dart';
import 'package:shade/core/widgets/shade_logo.dart';
import 'package:shade/features/v2/presentation/v2_chat_screen.dart';
import 'package:shade/features/v2/presentation/v2_chats_screen.dart';
import 'package:shade/features/v2/presentation/v2_connect_screen.dart';
import 'package:shade/features/v2/presentation/v2_devices_screen.dart';
import 'package:shade/features/v2/presentation/v2_profile_screen.dart';
import 'package:shade/features/v2/presentation/v2_providers.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Fake поверх UI-контракта V2SyncService (как FakeBackend в alpha-тестах).
class FakeSync implements V2SyncService {
  @override
  final String account;
  FakeSync({this.account = 'native_android'});

  final _changes = StreamController<void>.broadcast();
  final _typing = StreamController<V2TypingEvent>.broadcast();
  final _presence = StreamController<V2PresenceEvent>.broadcast();

  List<V2ChatSummary> chatList = [];
  Map<String, List<V2MessageView>> conversations = {};
  V2ProfileView? profileView;
  List<V2DeviceView> deviceList = [];

  String? chatsError;
  String? conversationError;
  String? devicesError;
  String? sendError;
  bool queueSends = false;
  bool blocked = false;

  final sent = <String>[];
  final sentReplies = <Map<String, dynamic>?>[];
  final deleted = <String>[];
  final retracted = <String>[];
  final readRefs = <String>[];
  final watched = <String>[];
  final typingSent = <String>[];
  final confirmed = <String>[];
  bool devicesRefreshed = false;
  bool started = false;
  int syncCalls = 0;

  void emit() => _changes.add(null);
  void typingEvent(String account, int until) =>
      _typing.add(V2TypingEvent(account, until));
  void presenceEvent(String account, bool online) =>
      _presence.add(V2PresenceEvent(account, online));

  /// Сеть появилась: queued-записи принимаются ТЕМ ЖЕ ref (без дублей).
  void acceptQueued() {
    for (final key in conversations.keys.toList()) {
      conversations[key] = [
        for (final m in conversations[key]!)
          m.status == 'queued'
              ? V2MessageView(
                  ref: m.ref,
                  peer: m.peer,
                  mine: m.mine,
                  createdAt: m.createdAt,
                  text: m.text,
                  reply: m.reply,
                  isImage: m.isImage,
                  imageData: m.imageData,
                  status: 'sent')
              : m
      ];
    }
    emit();
  }

  @override
  bool get syncing => false;
  @override
  String? get lastError => null;
  @override
  Stream<void> get changes => _changes.stream;
  @override
  Stream<V2TypingEvent> get typing => _typing.stream;
  @override
  Stream<V2PresenceEvent> get presence => _presence.stream;

  @override
  void start() => started = true;
  @override
  Future<void> syncNow() async => syncCalls++;

  @override
  Future<List<V2ChatSummary>> chats() async {
    if (chatsError != null) throw StateError(chatsError!);
    return chatList;
  }

  @override
  Future<List<V2MessageView>> conversation(String peer) async {
    if (conversationError != null) throw StateError(conversationError!);
    return conversations[peer] ?? [];
  }

  @override
  Future<String> send(String peer, String text,
      {Map<String, dynamic>? reply}) async {
    if (sendError != null) throw StateError(sendError!);
    sent.add(text);
    sentReplies.add(reply);
    final id = 'sent${sent.length}';
    (conversations[peer] ??= []).add(V2MessageView(
        ref: '$account:primary:$id',
        peer: peer,
        mine: true,
        createdAt: DateTime.now().millisecondsSinceEpoch,
        text: text,
        reply: reply,
        status: queueSends ? 'queued' : 'sent'));
    emit();
    return id;
  }

  @override
  Future<void> sendImage(String peer, List<int> bytes) async {}
  @override
  Future<void> confirmContact(String peer, String? genesisDigest) async =>
      confirmed.add('$peer:$genesisDigest');
  @override
  Future<bool> peerUpgradeBlocked(String peer) async => blocked;
  @override
  Future<void> markRead(List<String> refs) async => readRefs.addAll(refs);
  @override
  Future<void> deleteLocal(String ref) async {
    deleted.add(ref);
    for (final list in conversations.values) {
      list.removeWhere((m) => m.ref == ref);
    }
    emit();
  }

  @override
  Future<void> retract(String ref) async {
    retracted.add(ref);
    for (final key in conversations.keys.toList()) {
      conversations[key] = [
        for (final m in conversations[key]!)
          m.ref == ref
              ? V2MessageView(
                  ref: m.ref,
                  peer: m.peer,
                  mine: m.mine,
                  createdAt: m.createdAt,
                  text: m.text,
                  status: 'retracted')
              : m
      ];
    }
    emit();
  }

  @override
  void watch(String peer) => watched.add(peer);
  @override
  void unwatch(String peer) => watched.remove(peer);
  @override
  void sendTyping(String peer) => typingSent.add(peer);

  @override
  Future<V2ProfileView?> profile() async => profileView;
  @override
  Future<List<V2DeviceView>> devices({bool refresh = false}) async {
    if (devicesError != null) throw StateError(devicesError!);
    if (refresh) devicesRefreshed = true;
    return deviceList;
  }

  @override
  void dispose() {
    _changes.close();
    _typing.close();
    _presence.close();
  }
}

Widget _wrap(FakeSync sync, Widget home) => ProviderScope(
    overrides: [v2SyncProvider.overrideWithValue(sync)],
    child: MaterialApp(theme: buildShadeTheme(), home: home));

/// Scripted transport: send записывает КАЖДУЮ попытку (включая offline),
/// остальные операции пустые — реальный repository/store работают полностью.
class _ScriptedTransport extends AlphaTransport {
  _ScriptedTransport(CryptoService crypto)
      : super('https://alpha.invalid', crypto);

  String mode = 'offline'; // offline | accept | blocked
  final List<Map<String, dynamic>> sent = [];

  /// Программируемый каталог для онлайн-верификации контакта.
  Map<String, dynamic>? directoryResult;

  /// Программируемая status-проекция (ack/read устройств собеседника).
  Map<String, dynamic> statusResult = {};

  @override
  Future<Map<String, dynamic>> send(Map<String, dynamic> message,
      {required String privateKey}) async {
    sent.add(jsonDecode(jsonEncode(message)) as Map<String, dynamic>);
    if (mode == 'offline') throw const SocketException('нет сети');
    if (mode == 'blocked') {
      throw AlphaTransportException(409, 'peer_upgrade_required');
    }
    return {'accepted': true};
  }

  @override
  Future<List<dynamic>> fetch(
          {required String account,
          required String id,
          required String privateKey}) async =>
      [];
  @override
  Future<Map<String, dynamic>> ack(List<String> refs,
          {required String account,
          required String id,
          required String privateKey}) async =>
      {};
  @override
  Future<Map<String, dynamic>> status(List<String> refs,
          {required String account,
          required String id,
          required String privateKey}) async =>
      statusResult;
  @override
  Future<Map<String, dynamic>> read(List<String> refs,
          {required String account,
          required String id,
          required String privateKey}) async =>
      {};
  @override
  Future<List<dynamic>> retractions(
          {int since = 0,
          required String account,
          required String id,
          required String privateKey}) async =>
      [];
  @override
  Future<List<dynamic>> legacyInbox(
          {required String account,
          required String id,
          required String privateKey}) async =>
      [];
  @override
  Future<Map<String, dynamic>> legacyAck(List<String> ids,
          {required String account,
          required String id,
          required String privateKey}) async =>
      {};
  @override
  Future<Map<String, dynamic>> directory(String targetAccount,
          {required String account,
          required String id,
          required String privateKey}) async {
    if (mode != 'offline' && directoryResult != null) return directoryResult!;
    throw const SocketException('нет сети');
  }
  @override
  Future<Map<String, dynamic>> install(Map<String, dynamic> manifest,
          {List<dynamic> proofs = const [],
          Map<String, dynamic>? genesis,
          required String account,
          required String id,
          required String privateKey}) async =>
      throw const SocketException('нет сети');
  @override
  Future<void> connectSocket(
          {required String account,
          required String id,
          required String privateKey}) async {}
}

void main() {
  testWidgets('v2 welcome uses the full height of a tall phone', (tester) async {
    final view = tester.view;
    view.physicalSize = const Size(393, 920);
    view.devicePixelRatio = 1;
    addTearDown(view.resetPhysicalSize);
    addTearDown(view.resetDevicePixelRatio);
    await tester.pumpWidget(_wrap(FakeSync(), const V2ConnectScreen()));
    await tester.pumpAndSettle();
    expect(tester.getRect(find.text('shade')).top, lessThan(90));
    expect(tester.getRect(find.text('Как используется Google-аккаунт')).bottom, greaterThan(820));
    expect(find.widgetWithText(FilledButton, 'Продолжить с Google').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('branded v2 welcome fits a narrow phone and needs no form fields',
      (tester) async {
    final view = tester.view;
    view.physicalSize = const Size(320, 640);
    view.devicePixelRatio = 1;
    addTearDown(view.resetPhysicalSize);
    addTearDown(view.resetDevicePixelRatio);
    await tester.pumpWidget(_wrap(FakeSync(), const V2ConnectScreen()));
    await tester.pumpAndSettle();
    expect(find.text('Свои люди.\nЛичные разговоры.'), findsOneWidget);
    expect(find.byType(ShadeLogo), findsNWidgets(2));
    final google = find.widgetWithText(FilledButton, 'Продолжить с Google');
    expect(google, findsOneWidget);
    expect(tester.getRect(google).bottom, lessThan(640));
    expect(find.text('Восстановить доступ'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    expect(tester.takeException(), isNull);
  });

  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  final now = DateTime.now().millisecondsSinceEpoch;

  testWidgets('список чатов: избранное, статусы и локальный поиск',
      (tester) async {
    final sync = FakeSync()
      ..chatList = [
        V2ChatSummary(
            peer: 'native_android',
            confirmed: true,
            lastAt: now,
            lastText: 'заметка себе',
            lastMine: true,
            lastStatus: 'sent'),
        V2ChatSummary(
            peer: 'native_web',
            confirmed: true,
            lastAt: now - 1000,
            lastText: 'привет с Web',
            lastStatus: 'received'),
        V2ChatSummary(
            peer: 'queued_peer',
            confirmed: true,
            lastAt: now - 2000,
            lastText: 'ждёт сети',
            lastMine: true,
            lastStatus: 'queued',
            pendingCount: 1),
      ];
    await tester.pumpWidget(_wrap(sync, const V2ChatsScreen()));
    await tester.pumpAndSettle();

    expect(find.text('Избранное'), findsOneWidget);
    expect(find.text('@native_web'), findsOneWidget);
    expect(find.text('@queued_peer'), findsOneWidget);
    expect(find.text('Вы: ждёт сети'), findsOneWidget);
    expect(find.byIcon(Icons.schedule_rounded), findsOneWidget);
    expect(find.byIcon(Icons.done_rounded), findsOneWidget);

    // Локальный поиск по аккаунту.
    await tester.enterText(find.byKey(const Key('v2-chat-search')), 'web');
    await tester.pumpAndSettle();
    expect(find.text('@native_web'), findsOneWidget);
    expect(find.text('@queued_peer'), findsNothing);
    expect(find.text('Избранное'), findsNothing);

    await tester.enterText(find.byKey(const Key('v2-chat-search')), 'привет');
    await tester.pumpAndSettle();
    expect(find.text('@native_web'), findsOneWidget);
    expect(find.text('@queued_peer'), findsNothing);
    await tester.enterText(find.byKey(const Key('v2-chat-search')), '');
    await tester.tap(find.text('Только избранное'));
    await tester.pumpAndSettle();
    expect(find.text('@native_web'), findsNothing);
    expect(find.text('Избранное'), findsOneWidget);
    await tester.tap(find.text('Только избранное'));
    // «Избранное» ищется по названию.
    await tester.enterText(find.byKey(const Key('v2-chat-search')), 'избран');
    await tester.pumpAndSettle();
    expect(find.text('Избранное'), findsOneWidget);
    expect(find.text('@native_web'), findsNothing);

    // Пустой результат поиска — честное состояние.
    await tester.enterText(
        find.byKey(const Key('v2-chat-search')), 'нет_такого');
    await tester.pumpAndSettle();
    expect(find.text('Ничего не найдено'), findsOneWidget);
  });

  testWidgets('список чатов: empty и error с повтором', (tester) async {
    final empty = FakeSync();
    await tester.pumpWidget(_wrap(empty, const V2ChatsScreen()));
    await tester.pumpAndSettle();
    expect(find.text('Начните разговор'), findsOneWidget);

    final failing = FakeSync()..chatsError = 'сеть недоступна';
    await tester.pumpWidget(_wrap(failing, const V2ChatsScreen()));
    await tester.pumpAndSettle();
    expect(find.text('Не удалось открыть чаты'), findsOneWidget);

    failing.chatsError = null;
    failing.chatList = [
      const V2ChatSummary(peer: 'native_android', confirmed: true)
    ];
    await tester.tap(find.text('Повторить'));
    await tester.pumpAndSettle();
    expect(find.text('Избранное'), findsOneWidget);
    expect(find.text('Ваши личные заметки'), findsOneWidget);
  });

  testWidgets('диалог: история, статусы, отправка, reply, typing/presence',
      (tester) async {
    final sync = FakeSync();
    sync.conversations['native_web'] = [
      V2MessageView(
          ref: 'native_web:webdev:in1',
          peer: 'native_web',
          mine: false,
          createdAt: now,
          text: 'привет с Web',
          reply: {'ref': 'r0', 'from': 'native_android', 'text': 'цитата'},
          status: 'received'),
      V2MessageView(
          ref: 'native_android:primary:out1',
          peer: 'native_web',
          mine: true,
          createdAt: now + 1,
          text: 'привет с Android',
          status: 'read'),
    ];
    await tester.pumpWidget(_wrap(sync, const V2ChatScreen(peer: 'native_web')));
    await tester.pumpAndSettle();

    expect(find.text('привет с Web'), findsOneWidget);
    expect(find.text('привет с Android'), findsOneWidget);
    expect(find.text('цитата'), findsOneWidget);
    // Read-статус: done_all; read-ACK и presence-watch ушли в sync.
    expect(find.byIcon(Icons.done_all_rounded), findsOneWidget);
    expect(sync.readRefs, contains('native_web:webdev:in1'));
    expect(sync.watched, contains('native_web'));

    // Отправка текста через переиспользованный MessageInput.
    await tester.enterText(find.byKey(const Key('message-field')), 'ответное');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('send-message')));
    await tester.pumpAndSettle();
    expect(sync.sent, ['ответное']);
    expect(find.text('ответное'), findsOneWidget);

    // Reply через long-press: панель цитаты и контракт {ref, from, text}.
    await tester.longPress(find.text('привет с Web'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ответить'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('message-field')), 'с ответом');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('send-message')));
    await tester.pumpAndSettle();
    expect(sync.sentReplies.last, {
      'ref': 'native_web:webdev:in1',
      'from': 'native_web',
      'text': 'привет с Web'
    });

    // Typing-сигнал от MessageInput и входящий hint транспорта.
    await tester.enterText(find.byKey(const Key('message-field')), 'печатаю');
    await tester.pumpAndSettle();
    expect(sync.typingSent, contains('native_web'));
    sync.presenceEvent('native_web', true);
    await tester.pumpAndSettle();
    expect(find.text('в сети'), findsOneWidget);
    sync.typingEvent('native_web', DateTime.now().millisecondsSinceEpoch + 3000);
    await tester.pumpAndSettle();
    expect(find.text('печатает…'), findsOneWidget);
    // Hint истекает по until — индикатор гаснет сам.
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
    expect(find.text('печатает…'), findsNothing);
    expect(find.text('в сети'), findsOneWidget);
  });

  testWidgets('диалог: offline-очередь — queued виден, принятие без дублей',
      (tester) async {
    final sync = FakeSync()..queueSends = true;
    await tester.pumpWidget(_wrap(sync, const V2ChatScreen(peer: 'native_web')));
    await tester.pumpAndSettle();
    expect(find.text('Начните разговор'), findsOneWidget);

    await tester.enterText(
        find.byKey(const Key('message-field')), 'offline сообщение');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('send-message')));
    await tester.pumpAndSettle();
    expect(find.text('offline сообщение'), findsOneWidget);
    expect(find.byIcon(Icons.schedule_rounded), findsOneWidget);

    // Сеть появилась: ТОТ ЖЕ ref принимается, дубль не появляется.
    sync.acceptQueued();
    await tester.pumpAndSettle();
    expect(find.text('offline сообщение'), findsOneWidget);
    expect(find.byIcon(Icons.schedule_rounded), findsNothing);
    expect(find.byIcon(Icons.done_rounded), findsOneWidget);
  });

  testWidgets('диалог: сбой отправки сохраняет текст в поле ввода',
      (tester) async {
    final sync = FakeSync()..sendError = 'нет сети';
    await tester.pumpWidget(_wrap(sync, const V2ChatScreen(peer: 'native_web')));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const Key('message-field')), 'важный текст');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('send-message')));
    await tester.pumpAndSettle();
    final field =
        tester.widget<TextField>(find.byKey(const Key('message-field')));
    expect(field.controller!.text, 'важный текст');
    expect(sync.sent, isEmpty);
    expect(find.textContaining('Не удалось отправить'), findsOneWidget);
  });

  testWidgets('диалог: blocked-баннер, empty и error с повтором',
      (tester) async {
    final blockedSync = FakeSync()..blocked = true;
    await tester.pumpWidget(
        _wrap(blockedSync, const V2ChatScreen(peer: 'native_web')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Собеседник ещё не перешёл на v2'),
        findsOneWidget);

    final failing = FakeSync()..conversationError = 'нет сети';
    await tester.pumpWidget(_wrap(failing, const V2ChatScreen(peer: 'native_web')));
    await tester.pumpAndSettle();
    expect(find.text('Не удалось открыть переписку'), findsOneWidget);
    failing.conversationError = null;
    await tester.tap(find.text('Повторить'));
    await tester.pumpAndSettle();
    expect(find.text('Начните разговор'), findsOneWidget);
  });

  testWidgets('диалог: удаление у себя и отзыв у всех', (tester) async {
    final sync = FakeSync();
    sync.conversations['native_web'] = [
      V2MessageView(
          ref: 'native_web:webdev:in1',
          peer: 'native_web',
          mine: false,
          createdAt: now,
          text: 'входящее',
          status: 'received'),
      V2MessageView(
          ref: 'native_android:primary:out1',
          peer: 'native_web',
          mine: true,
          createdAt: now + 1,
          text: 'исходящее',
          status: 'sent'),
    ];
    await tester.pumpWidget(_wrap(sync, const V2ChatScreen(peer: 'native_web')));
    await tester.pumpAndSettle();

    await tester.longPress(find.text('входящее'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Удалить у себя'));
    await tester.pumpAndSettle();
    expect(sync.deleted, ['native_web:webdev:in1']);
    expect(find.text('входящее'), findsNothing);

    await tester.longPress(find.text('исходящее'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Отозвать у всех'));
    await tester.pumpAndSettle();
    expect(sync.retracted, ['native_android:primary:out1']);
    expect(find.text('Сообщение отозвано'), findsOneWidget);
  });

  testWidgets('профиль: быстрые действия, копирование кода и сведения об устройствах',
      (tester) async {
    final sync = FakeSync()
      ..profileView = V2ProfileView(
          account: 'native_android',
          rootFingerprint: 'ab' * 32,
          genesisDigest: 'cd' * 32,
          revision: 3,
          leaseExpiresAt: now + 86400000,
          deviceCount: 2,
          sessionId: 'primary');
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(393, 850);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final capturePath = Platform.environment['SHADE_PROFILE_CAPTURE'];
    if (capturePath != null) {
      await tester.runAsync(() async {
        await (FontLoader('Roboto')
              ..addFont(rootBundle.load('fonts/Roboto/Roboto-Regular.ttf'))
              ..addFont(rootBundle.load('fonts/Roboto/Roboto-Bold.ttf')))
            .load();
        await (FontLoader('MaterialIcons')
              ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf')))
            .load();
      });
    }
    const captureKey = Key('profile-preview');
    await tester.pumpWidget(_wrap(sync, const RepaintBoundary(key: captureKey, child: V2ProfileScreen())));
    await tester.pumpAndSettle();

    if (capturePath != null) {
      final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(captureKey));
      await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 2);
        try {
          final png = (await image.toByteData(format: ui.ImageByteFormat.png))!;
          await File(capturePath).writeAsBytes(png.buffer.asUint8List());
        } finally {
          image.dispose();
        }
      });
    }

    expect(find.text('Native_android'), findsOneWidget);
    expect(find.text('@native_android'), findsNWidgets(2));
    expect(find.text('Код безопасности'), findsOneWidget);
    expect(find.text('cd' * 32), findsNothing);

    String? copied;
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String;
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(SystemChannels.platform, null));

    await tester.tap(find.text('Скопировать'));
    await tester.pumpAndSettle();
    expect(copied, '@native_android');
    await tester.tap(find.text('Мой ключ'));
    await tester.pumpAndSettle();
    expect(find.text('cd' * 32), findsOneWidget);
    await tester.tap(find.text('Скопировать код'));
    await tester.pumpAndSettle();
    expect(copied, 'cd' * 32);
    await tester.tap(find.text('Отпечаток ключа аккаунта'));
    await tester.pumpAndSettle();
    expect(find.text('ab' * 32), findsOneWidget);
    Navigator.of(tester.element(find.text('Скопировать код'))).pop();
    await tester.pumpAndSettle();
    final messengerState = ScaffoldMessenger.of(tester.element(find.byType(V2ProfileScreen)));
    messengerState.clearSnackBars();
    messengerState.removeCurrentSnackBar();
    await tester.pumpAndSettle();
    final details = find.text('Сведения об устройствах');
    await tester.scrollUntilVisible(details, 150, scrollable: find.byType(Scrollable).first);
    await Scrollable.ensureVisible(tester.element(details), alignment: .5);
    await tester.pumpAndSettle();
    await tester.tap(details);
    await tester.pumpAndSettle();
    expect(find.text('Ревизия 3'), findsOneWidget);
    expect(find.text('2 в каталоге'), findsOneWidget);
  });

  testWidgets('устройства: ростер, текущее устройство, сверка и error',
      (tester) async {
    final sync = FakeSync()
      ..deviceList = [
        V2DeviceView(
            id: 'primary', fingerprint: 'ef' * 32, current: true, primary: true),
        V2DeviceView(
            id: 'a' * 64, fingerprint: '12' * 32, current: false, primary: false),
      ];
    await tester.pumpWidget(_wrap(sync, const V2DevicesScreen()));
    await tester.pumpAndSettle();

    expect(find.text('Основное устройство'), findsOneWidget);
    expect(find.text('Это устройство'), findsOneWidget);
    expect(find.text('Устройство aaaaaaaa…'), findsOneWidget);
    // Навигационные точки в существующие pairing-экраны.
    expect(find.text('Подключить другое устройство'), findsOneWidget);

    await tester.tap(find.byTooltip('Сверить с сервером'));
    await tester.pumpAndSettle();
    expect(sync.devicesRefreshed, true);

    final failing = FakeSync()..devicesError = 'нет сети';
    await tester.pumpWidget(_wrap(failing, const V2DevicesScreen()));
    await tester.pumpAndSettle();
    expect(find.text('Не удалось открыть каталог'), findsOneWidget);
    failing.devicesError = null;
    failing.deviceList = sync.deviceList;
    await tester.tap(find.text('Повторить'));
    await tester.pumpAndSettle();
    expect(find.text('Основное устройство'), findsOneWidget);
  });

  test(
      'offline-очередь на реальном store/repository: тот же ciphertext/id, '
      'queued → blocked → sent, без дублей', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final crypto = CryptoService();
    final kp = await RSA.generate(4096);
    final root = await publicSpki(kp.publicKey);
    final folder = await Directory.systemTemp.createTemp('shade-v2-ui-sync-');
    final db = await DatabaseService.openForTest(
        databaseFactoryFfi, '${folder.path}/db');
    final store = V2Store(db);
    final v2 = DeviceV2Crypto(crypto);
    const account = 'ui_native';

    // Легитимный legacy-аккаунт: genesis/manifest подписаны исходным RSA,
    // recovery-ключ независим (полная проверка verifyHistory при seal).
    final backup = await v2.createRecoveryBackup(
        account, root, 'synthetic ui offline recovery phrase');
    final genesis =
        v2.buildLegacyGenesis(account, root, backup['publicKey'] as String);
    genesis['signature'] =
        await crypto.signData(genesisText(genesis), kp.privateKey);
    final manifest = v2.buildLegacyManifest(account, root);
    manifest['signature'] =
        await crypto.signData(manifestText(manifest), kp.privateKey);
    await store.saveAccount(
        account: account,
        root: root,
        genesis: genesis,
        history: [manifest],
        checkpoint: {
          'account': account,
          'rootFingerprint': spkiFingerprint(root),
          'revision': 1,
          'digest': sha256Hex(manifestText(manifest)),
          'genesisDigest': sha256Hex(genesisText(genesis))
        },
        sessionId: 'primary');

    final transport = _ScriptedTransport(crypto);
    final repo = V2ChatRepository(
        transport: transport,
        crypto: crypto,
        store: store,
        account: account,
        root: root,
        privateKey: kp.privateKey);
    await repo.load();
    final sync = V2SyncService(repository: repo, database: db);
    addTearDown(() async {
      sync.dispose();
      transport.dispose();
      await db.close();
      await folder.delete(recursive: true);
    });

    // 1) Offline self-send: конверт запечатан и долговечно закоммичен,
    //    flush не прошёл — сообщение видно как queued.
    transport.mode = 'offline';
    final id = await sync.send(account, 'заметка offline');
    final outbox = await store.outboxAll();
    expect(outbox.length, 1);
    expect(outbox.single['id'], id);
    expect(transport.sent.length, 1);
    var conv = await sync.conversation(account);
    expect(conv.single.text, 'заметка offline');
    expect(conv.single.status, 'queued');

    // 2) Сеть появилась: повтор ТОГО ЖЕ ciphertext/ID, accepted → sent.
    transport.mode = 'accept';
    await sync.syncNow();
    expect(transport.sent.length, 2);
    expect(jsonEncode(transport.sent[0]), jsonEncode(transport.sent[1]),
        reason: 'retry обязан повторять тот же запечатанный конверт');
    expect(await store.outboxAll(), isEmpty);
    conv = await sync.conversation(account);
    expect(conv.length, 1);
    expect(conv.single.status, 'sent');

    // 3) Повторные циклы не плодят дубли и не переотправляют принятое.
    await sync.syncNow();
    await sync.syncNow();
    expect(transport.sent.length, 2);
    expect((await sync.conversation(account)).length, 1);
    expect((await store.messagesByPeer(account)).length, 1);

    // 4) Серверный отказ 409: статус blocked с честной меткой, конверт
    //    остаётся в очереди; после смены условий доставляется тем же ID.
    transport.mode = 'blocked';
    final blockedId = await sync.send(account, 'заблокированное');
    conv = await sync.conversation(account);
    final blockedMessage =
        conv.firstWhere((m) => m.text == 'заблокированное');
    expect(blockedMessage.status, 'blocked');
    expect(blockedMessage.statusLabel, contains('v2'));
    expect(await sync.peerUpgradeBlocked(account), true);
    expect((await store.outboxAll()).single['id'], blockedId);

    transport.mode = 'accept';
    await sync.syncNow();
    conv = await sync.conversation(account);
    expect(conv.length, 2);
    expect(conv.every((m) => m.status == 'sent'), true);
    expect(transport.sent.last['id'], blockedId);
    expect(await store.outboxAll(), isEmpty);
    expect((await store.messagesByPeer(account)).length, 2);
  }, timeout: const Timeout(Duration(minutes: 4)));

  test(
      'offline peer-seal через contactHistory: запечатка без сети, '
      'расшифровка собеседником, retry тем же конвертом, fail-closed',
      () async {
    FlutterSecureStorage.setMockInitialValues({});
    final crypto = CryptoService();
    final v2 = DeviceV2Crypto(crypto);
    final folder = await Directory.systemTemp.createTemp('shade-v2-ui-peer-');
    final db = await DatabaseService.openForTest(
        databaseFactoryFfi, '${folder.path}/db');
    final store = V2Store(db);

    final own = await _buildIdentity(crypto, v2, 'ui_native');
    await store.saveAccount(
        account: 'ui_native',
        root: own.root,
        genesis: own.genesis,
        history: [own.manifest],
        checkpoint: own.checkpoint,
        sessionId: 'primary');
    final peer = await _buildIdentity(crypto, v2, 'ui_peer');
    final peerDigest = sha256Hex(genesisText(peer.genesis));

    final transport = _ScriptedTransport(crypto);
    final repo = V2ChatRepository(
        transport: transport,
        crypto: crypto,
        store: store,
        account: 'ui_native',
        root: own.root,
        privateKey: own.privateKey);
    await repo.load();
    final sync = V2SyncService(repository: repo, database: db);
    addTearDown(() async {
      sync.dispose();
      transport.dispose();
      await db.close();
      await folder.delete(recursive: true);
    });

    // 0) ОНЛАЙН-верификация контакта: confirmContact сверяет genesis digest
    //    и цепочку, долговечно сохраняет проверенную history (schema v12).
    transport.mode = 'accept';
    transport.directoryResult = {
      'root': peer.root,
      'genesis': peer.genesis,
      'history': [peer.manifest]
    };
    await sync.confirmContact('ui_peer', peerDigest);
    final verifiedContact = await store.loadContact('ui_peer');
    expect(verifiedContact!['confirmed'], true);
    expect(verifiedContact['history'], isNotNull);

    // 1) Сеть выключена: peer-send запечатывается из сохранённой history и
    //    долговечно коммитится; сетевых попыток не было.
    transport.mode = 'offline';
    transport.directoryResult = null;
    final id = await sync.send('ui_peer', 'peer offline заметка');
    expect(transport.sent, isEmpty);
    final outbox = await store.outboxAll();
    expect(outbox.single['id'], id);
    var conv = await sync.conversation('ui_peer');
    expect(conv.single.text, 'peer offline заметка');
    expect(conv.single.status, 'queued');

    // 2) Собеседник расшифровывает конверт своим ключом (fanout корректен).
    final sealed = outbox.single['message'] as Map<String, dynamic>;
    final plain = await v2.openMessage(
        {
          'message': sealed,
          'senderHistory': [own.manifest],
          'recipientHistory': [peer.manifest]
        },
        DeviceV2Session(
            account: 'ui_peer',
            id: 'primary',
            encryptionKey: peer.root,
            signingKey: peer.root,
            encryptionPrivateKey: peer.privateKey,
            signingPrivateKey: peer.privateKey),
        AccountTrust(root: own.root, genesis: own.genesis),
        AccountTrust(root: peer.root, genesis: peer.genesis));
    expect(plain, 'peer offline заметка');

    // 3) Сеть вернулась: retry ТОГО ЖЕ конверта, accepted → sent; затем
    //    подписанная status-проекция собеседника даёт delivered. Без дублей.
    transport.mode = 'accept';
    await sync.syncNow();
    expect(transport.sent.single['id'], id);
    expect(await store.outboxAll(), isEmpty);
    conv = await sync.conversation('ui_peer');
    expect(conv.single.status, 'sent');
    transport.statusResult = {
      'ui_native:primary:$id': [
        {'id': 'primary', 'acknowledgedAt': DateTime.now().millisecondsSinceEpoch}
      ]
    };
    await sync.syncNow();
    conv = await sync.conversation('ui_peer');
    expect(conv.single.status, 'delivered');
    await sync.syncNow();
    expect(transport.sent.length, 1);
    expect((await store.messagesByPeer('ui_peer')).length, 1);

    // 4) Fail-closed: подтверждённый контакт БЕЗ history (старая запись) —
    //    честный отказ до первой онлайн-верификации, очередь пуста.
    await store.saveContact(
        account: 'old_peer',
        root: peer.root,
        genesis: peer.genesis,
        checkpoint: peer.checkpoint,
        genesisDigest: peerDigest,
        confirmed: true);
    await expectLater(
        sync.send('old_peer', 'не должно уйти'), throwsA(isA<StateError>()));
    expect(await store.outboxAll(), isEmpty);

    // 5) Fail-closed: history не сходится с checkpoint (подмена/rollback) —
    //    verifyHistory блокирует запечатку ДО коммита.
    await store.saveContact(
        account: 'evil_peer',
        root: peer.root,
        genesis: peer.genesis,
        checkpoint: {...peer.checkpoint, 'digest': 'ff' * 32},
        genesisDigest: peerDigest,
        confirmed: true,
        history: [peer.manifest]);
    await expectLater(sync.send('evil_peer', 'подмена'),
        throwsA(predicate((Object e) => '$e'.contains('fork'))));
    expect(await store.outboxAll(), isEmpty);
    expect(transport.sent.length, 1);
  }, timeout: const Timeout(Duration(minutes: 4)));
}

/// Легитимная legacy-идентичность для тестов: genesis/manifest подписаны
/// исходным RSA, recovery-ключ независим (полная проверка verifyHistory).
class _Identity {
  final String root;
  final String privateKey;
  final Map<String, dynamic> genesis;
  final Map<String, dynamic> manifest;
  final Map<String, dynamic> checkpoint;

  const _Identity({
    required this.root,
    required this.privateKey,
    required this.genesis,
    required this.manifest,
    required this.checkpoint,
  });
}

Future<_Identity> _buildIdentity(
    CryptoService crypto, DeviceV2Crypto v2, String account) async {
  final kp = await RSA.generate(4096);
  final root = await publicSpki(kp.publicKey);
  final backup = await v2.createRecoveryBackup(
      account, root, 'synthetic ui offline recovery phrase');
  final genesis =
      v2.buildLegacyGenesis(account, root, backup['publicKey'] as String);
  genesis['signature'] =
      await crypto.signData(genesisText(genesis), kp.privateKey);
  final manifest = v2.buildLegacyManifest(account, root);
  manifest['signature'] =
      await crypto.signData(manifestText(manifest), kp.privateKey);
  return _Identity(
      root: root,
      privateKey: kp.privateKey,
      genesis: genesis,
      manifest: manifest,
      checkpoint: {
        'account': account,
        'rootFingerprint': spkiFingerprint(root),
        'revision': 1,
        'digest': sha256Hex(manifestText(manifest)),
        'genesisDigest': sha256Hex(genesisText(genesis))
      });
}