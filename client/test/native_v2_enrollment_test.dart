import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fast_rsa/fast_rsa.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shade/core/database/database_service.dart';
import 'package:shade/core/services/crypto_service.dart';
import 'package:shade/core/services/device_v2/crypto.dart';
import 'package:shade/core/services/device_v2/history_import.dart';
import 'package:shade/core/services/device_v2/protocol.dart';
import 'package:shade/core/services/device_v2/repository.dart';
import 'package:shade/core/services/device_v2/store.dart';
import 'package:shade/core/services/device_v2/transport.dart';
import 'package:shade/features/devices/presentation/enrollment_screen.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Продакшн enrollment v1 → v2: локальный импорт истории на реальном
/// SQLCipher ffi (синтетические v1-данные) и widget-тесты мастера enrollment.
/// Импорт не использует сеть: plaintext не покидает устройство.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  // Синтетические ключи переиспользуются тестами: генерация RSA дорогая,
  // лишняя параллельная нагрузка замедляет соседние тестовые файлы.
  Future<KeyPair>? v1Future;
  Future<KeyPair> v1Keys() => v1Future ??= RSA.generate(2048);
  Future<KeyPair>? anchorFuture;
  Future<KeyPair> anchorKeys() => anchorFuture ??= RSA.generate(4096);

  // ── Импорт истории: реальный SQLCipher ffi ──────────────────────────────

  test('импорт v1 → v2: метаданные, reply и IMG читаются через getMessages',
      () async {
    FlutterSecureStorage.setMockInitialValues({});
    final crypto = CryptoService();
    final kp = await v1Keys();
    final root = await publicSpki(kp.publicKey);
    final (db, store, repo, cleanup) =
        await _setup(crypto, 'import_user', root, kp.privateKey);
    addTearDown(cleanup);

    final conv = await db.createConversation('import_peer');
    final photo = List.generate(64, (i) => i);
    await db.insertMessage(
        conversationId: conv,
        senderId: 42,
        encryptedContent: await crypto.encryptData('привет из v1', kp.publicKey),
        networkId: 'net000000000001',
        networkSender: 'import_peer',
        timestamp: 1700000000000);
    await db.insertMessage(
        conversationId: conv,
        senderId: 42,
        encryptedContent:
            await crypto.encryptData('IMG:${base64.encode(photo)}', kp.publicKey),
        networkId: 'net000000000002',
        networkSender: 'import_peer',
        timestamp: 1700000000001);
    await db.insertMessage(
        conversationId: conv,
        senderId: 42,
        encryptedContent: await crypto.encryptData(
            jsonEncode({
              't': 'ответ',
              'r': {'s': 'import_peer', 't': 'исходное'}
            }),
            kp.publicKey),
        networkId: 'net000000000003',
        networkSender: 'import_peer',
        timestamp: 1700000000002);
    await db.insertMessage(
        conversationId: conv,
        senderId: 7,
        encryptedContent: await crypto.encryptData('мой ответ', kp.publicKey),
        networkId: 'net000000000004',
        networkSender: 'import_user',
        outgoing: true,
        status: 'delivered',
        timestamp: 1700000000003);
    // «Избранное» (self-chat, conversation id 1 из схемы v1).
    await db.insertMessage(
        conversationId: 1,
        senderId: 7,
        encryptedContent: await crypto.encryptData('заметка', kp.publicKey),
        networkId: 'net000000000005',
        networkSender: 'import_user',
        outgoing: true,
        status: 'read',
        timestamp: 1700000000004);
    // Локальная запись без network_id: id выводится из rowid.
    await db.insertMessage(
        conversationId: conv,
        senderId: 42,
        encryptedContent: await crypto.encryptData('локальное', kp.publicKey),
        networkSender: 'import_peer',
        timestamp: 1700000000005);

    final before = await _v1Checksum(db);
    final result =
        await V1HistoryImporter.forRepository(repo, database: db).run();
    expect(result.done, true);
    expect(result.imported, 6);
    expect(result.failed, 0);
    expect(result.pendingLeft, 0);
    expect(result.resumed, false);

    final msgs = await repo.getMessages('import_peer');
    expect(msgs.length, 5);
    final text = msgs.firstWhere((m) => m['messageId'] == 'net000000000001');
    expect(text['text'], 'привет из v1');
    expect(text['direction'], 'in');
    expect(text['peer'], 'import_peer');
    expect(text['createdAt'], 1700000000000);
    final img = msgs.firstWhere((m) => m['messageId'] == 'net000000000002');
    expect(img['isImage'], true);
    expect(img['imageData'], photo);
    final reply = msgs.firstWhere((m) => m['messageId'] == 'net000000000003');
    expect(reply['text'], 'ответ');
    expect(reply['reply'], {'from': 'import_peer', 'text': 'исходное'});
    final out = msgs.firstWhere((m) => m['messageId'] == 'net000000000004');
    expect(out['direction'], 'out');
    expect(out['text'], 'мой ответ');
    final local = msgs.firstWhere((m) => m['text'] == 'локальное');
    expect((local['messageId'] as String).startsWith('local:'), true);
    expect(local['createdAt'], 1700000000005);

    final self = await repo.getMessages('import_user');
    expect(self.single['text'], 'заметка');
    expect(self.single['direction'], 'out');

    // v1-хранилище не изменено ни одной записью.
    expect(await _v1Checksum(db), before);

    // Повторный импорт идемпотентен: курсор в конце, дублей нет.
    final again =
        await V1HistoryImporter.forRepository(repo, database: db).run();
    expect(again.done, true);
    expect(again.resumed, true);
    expect(again.imported, 6);
    expect((await repo.getMessages('import_peer')).length, 5);
    expect((await repo.getMessages('import_user')).length, 1);
    expect(await _v1Checksum(db), before);
    expect(
        await V1HistoryImporter.forRepository(repo, database: db).completed(),
        true);
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('дедуп с мостом: уже доставленная запись не дублируется', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final crypto = CryptoService();
    final kp = await v1Keys();
    final root = await publicSpki(kp.publicKey);
    final (db, store, repo, cleanup) =
        await _setup(crypto, 'import_user', root, kp.privateKey);
    addTearDown(cleanup);

    final conv = await db.createConversation('import_peer');
    final envelope = await crypto.encryptData('уже доставлено', kp.publicKey);
    await db.insertMessage(
        conversationId: conv,
        senderId: 42,
        encryptedContent: envelope,
        networkId: 'net000000000001',
        networkSender: 'import_peer',
        timestamp: 1700000000000);
    await db.insertMessage(
        conversationId: conv,
        senderId: 42,
        encryptedContent: await crypto.encryptData('новое', kp.publicKey),
        networkId: 'net000000000002',
        networkSender: 'import_peer',
        timestamp: 1700000000001);
    // Мост уже сохранил первую запись тем же ref `v1:<from>:<id>`.
    await store.insertReceived(
        ref: 'v1:import_peer:net000000000001',
        peer: 'import_peer',
        messageId: 'net000000000001',
        createdAt: 1700000000000,
        payload: Map<String, dynamic>.from(jsonDecode(envelope) as Map));

    final result =
        await V1HistoryImporter.forRepository(repo, database: db).run();
    expect(result.imported, 1);
    expect(result.duplicates, 1);
    final msgs = await repo.getMessages('import_peer');
    expect(msgs.length, 2);
    expect(msgs.first['text'], 'уже доставлено');
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('crash-resume: сбой посередине батча продолжается без дублей и потерь',
      () async {
    FlutterSecureStorage.setMockInitialValues({});
    final crypto = CryptoService();
    final kp = await v1Keys();
    final root = await publicSpki(kp.publicKey);
    final (db, store, repo, cleanup) =
        await _setup(crypto, 'import_user', root, kp.privateKey);
    addTearDown(cleanup);

    final conv = await db.createConversation('import_peer');
    for (var i = 0; i < 12; i++) {
      await db.insertMessage(
          conversationId: conv,
          senderId: 42,
          encryptedContent:
              await crypto.encryptData('сообщение $i', kp.publicKey),
          networkId: 'net${i.toString().padLeft(12, '0')}',
          networkSender: 'import_peer',
          timestamp: 1700000000000 + i);
    }
    final before = await _v1Checksum(db);

    // Crash на 7-й записи: первый батч (5) зафиксирован в журнале, второй
    // начат (записи 6-7 вставлены), но курсор ещё не обновлён.
    final crashImporter = _CrashImporter(
        database: db,
        store: store,
        crypto: crypto,
        account: 'import_user',
        privateKey: kp.privateKey,
        batchSize: 5,
        crashAt: 7);
    await expectLater(crashImporter.run(), throwsA(isA<StateError>()));
    expect(crashImporter.crashed, true);
    final journal = await (await db.database).query('v2_history_import_journal',
        where: 'account = ?', whereArgs: ['import_user']);
    expect(journal.single['phase'], 'running');
    expect(journal.single['last_id'], 5);
    expect(await _v1Checksum(db), before);

    // «Перезапуск»: новый импортёр, то же хранилище. Записи 6-7 уже в v2 —
    // дедуп по ref отсекает их, остальные досканируются.
    final resumed = V1HistoryImporter(
        database: db,
        store: store,
        crypto: crypto,
        account: 'import_user',
        privateKey: kp.privateKey,
        batchSize: 5);
    final result = await resumed.run();
    expect(result.done, true);
    expect(result.resumed, true);
    expect(result.duplicates, 2);
    expect(result.imported, 10);
    final msgs = await repo.getMessages('import_peer');
    expect(msgs.length, 12);
    for (var i = 0; i < 12; i++) {
      expect(msgs[i]['text'], 'сообщение $i');
      expect(msgs[i]['createdAt'], 1700000000000 + i);
    }
    expect(await _v1Checksum(db), before);

    // Третий запуск ничего не меняет.
    final again = await resumed.run();
    expect(again.imported, 10);
    expect((await repo.getMessages('import_peer')).length, 12);
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('недоставленные исходящие остаются в v1; сбойные записи фиксируются',
      () async {
    FlutterSecureStorage.setMockInitialValues({});
    final crypto = CryptoService();
    final kp = await v1Keys();
    final root = await publicSpki(kp.publicKey);
    final (db, store, repo, cleanup) =
        await _setup(crypto, 'import_user', root, kp.privateKey);
    addTearDown(cleanup);

    final conv = await db.createConversation('import_peer');
    // queued + запись в outbox v1: сообщение ещё не принято сервером.
    await db.insertMessage(
        conversationId: conv,
        senderId: 7,
        encryptedContent: await crypto.encryptData('в очереди', kp.publicKey),
        networkId: 'net000000000001',
        networkSender: 'import_user',
        outgoing: true,
        status: 'queued',
        recipient: 'import_peer',
        networkPayload: await crypto.encryptData('в очереди', kp.publicKey),
        timestamp: 1700000000000);
    // Получатель уже на v2: доставка по v1 невозможна.
    await db.insertMessage(
        conversationId: conv,
        senderId: 7,
        encryptedContent:
            await crypto.encryptData('upgrade_required', kp.publicKey),
        networkId: 'net000000000002',
        networkSender: 'import_user',
        outgoing: true,
        status: 'upgrade_required',
        timestamp: 1700000000001);
    // Повреждённая запись: расшифровка невозможна.
    await db.insertMessage(
        conversationId: conv,
        senderId: 42,
        encryptedContent: 'не-json',
        networkId: 'net000000000003',
        networkSender: 'import_peer',
        timestamp: 1700000000002);
    await db.insertMessage(
        conversationId: conv,
        senderId: 42,
        encryptedContent: await crypto.encryptData('целое', kp.publicKey),
        networkId: 'net000000000004',
        networkSender: 'import_peer',
        timestamp: 1700000000003);

    final before = await _v1Checksum(db);
    final importer = V1HistoryImporter.forRepository(repo, database: db);
    final result = await importer.run();
    expect(result.done, true);
    expect(result.imported, 1);
    expect(result.pendingLeft, 2);
    expect(result.failed, 1);
    expect((await repo.getMessages('import_peer')).single['text'], 'целое');
    // Очередь v1 и все записи остались нетронутыми.
    expect(await _v1Checksum(db), before);
    expect(await db.getOutbox(), hasLength(1));

    // Повтор: сбойная запись повторяется и снова фиксируется, дублей нет.
    final again = await importer.run();
    expect(again.failed, 1);
    expect(again.imported, 1);
    expect(again.pendingLeft, 2);
    expect((await repo.getMessages('import_peer')).length, 1);
    expect(await _v1Checksum(db), before);
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('rotation: старая история читается legacy-ключом после импорта',
      () async {
    FlutterSecureStorage.setMockInitialValues({});
    final crypto = CryptoService();
    final old = await v1Keys();
    final anchor = await anchorKeys();
    final newRoot = await publicSpki(anchor.publicKey);
    final folder = await Directory.systemTemp.createTemp('shade-import-rot-');
    final db = await DatabaseService.openForTest(
        databaseFactoryFfi, '${folder.path}/db');
    final store = V2Store(db);
    addTearDown(() async {
      await db.close();
      await folder.delete(recursive: true);
    });
    // Аккаунт после rotation: новый якорь + исходный v1-ключ.
    await store.saveAccount(
        account: 'rot_user',
        root: newRoot,
        genesis: {'version': 2, 'account': 'rot_user'},
        history: [
          {'revision': 1}
        ],
        checkpoint: {'revision': 1},
        sessionId: 'primary',
        anchorKey: anchor.privateKey,
        legacyKey: old.privateKey);
    final transport = AlphaTransport('http://127.0.0.1:1', crypto);
    addTearDown(transport.dispose);
    final repo = V2ChatRepository(
        transport: transport,
        crypto: crypto,
        store: store,
        account: 'rot_user',
        root: newRoot,
        privateKey: anchor.privateKey);
    await repo.load();
    expect(repo.legacyPrivateKey, old.privateKey);

    final conv = await db.createConversation('rot_peer');
    await db.insertMessage(
        conversationId: conv,
        senderId: 42,
        encryptedContent: await crypto.encryptData('старая история', old.publicKey),
        networkId: 'netrot0000000001',
        networkSender: 'rot_peer',
        timestamp: 1700000000000);
    final before = await _v1Checksum(db);

    final result =
        await V1HistoryImporter.forRepository(repo, database: db).run();
    expect(result.imported, 1);
    // Чтение штатным путём getMessages: legacy-ключ расшифрует перешифровку.
    final msgs = await repo.getMessages('rot_peer');
    expect(msgs.single['text'], 'старая история');
    // Перешифровка выполнена исходным v1-ключом (не новым якорем).
    final stored = await store.messageByRef('v1:rot_peer:netrot0000000001');
    expect(
        await crypto.decryptData(stored!['payload'] as String, old.privateKey),
        'старая история');
    expect(await _v1Checksum(db), before);
  }, timeout: const Timeout(Duration(minutes: 4)));

  test('импорт до enrollment отклонён без создания журнала', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final crypto = CryptoService();
    final kp = await v1Keys();
    final folder = await Directory.systemTemp.createTemp('shade-import-noacc-');
    final db = await DatabaseService.openForTest(
        databaseFactoryFfi, '${folder.path}/db');
    final store = V2Store(db);
    addTearDown(() async {
      await db.close();
      await folder.delete(recursive: true);
    });
    final importer = V1HistoryImporter(
        database: db,
        store: store,
        crypto: crypto,
        account: 'import_user',
        privateKey: kp.privateKey);
    await expectLater(
        importer.run(),
        throwsA(predicate(
            (e) => e.toString().contains('регистрации устройства'))));
    final tables = await (await db.database).rawQuery(
        "SELECT name FROM sqlite_master WHERE name = 'v2_history_import_journal'");
    expect(tables, isEmpty);
  }, timeout: const Timeout(Duration(minutes: 2)));

  // ── Widget-тесты мастера enrollment (фейковый backend, без сети) ────────

  Future<_FakeEnrollmentBackend> pumpScreen(
      WidgetTester tester, _FakeEnrollmentBackend backend,
      {VoidCallback? onFinished}) async {
    await tester.pumpWidget(MaterialApp(
        home: EnrollmentScreen(backend: backend, onFinished: onFinished)));
    await tester.pump();
    return backend;
  }

  /// Тап по ключу с предварительной прокруткой: длинный шаг enrollment
  /// уходит за пределы тестового viewport.
  Future<void> tapKey(WidgetTester tester, Key key) async {
    final finder = find.byKey(key);
    await tester.ensureVisible(finder);
    await tester.pump();
    await tester.tap(finder);
    await tester.pump();
  }

  testWidgets('полный мастер: challenge → enrollment → импорт → готово',
      (tester) async {
    final backend = _FakeEnrollmentBackend();
    var finished = false;
    await pumpScreen(tester, backend, onFinished: () => finished = true);

    // Шаг challenge: честное объяснение и кнопка подключения.
    expect(find.text('Подключиться'), findsOneWidget);
    expect(find.byKey(const Key('enrollment-step-challenge')), findsOneWidget);
    await tapKey(tester, const Key('enrollment-connect'));
    expect(backend.sessionCalls, 1);

    // Шаг enrollment: что переносится / что не переносится.
    expect(find.text('Что переносится'), findsOneWidget);
    expect(find.text('Что не переносится сразу'), findsOneWidget);
    expect(find.textContaining('останутся в очередях v1'), findsOneWidget);
    expect(find.textContaining('тем же RSA-ключом'), findsWidgets);

    // Короткая фраза: русская ошибка, вызова enroll нет.
    await tester.enterText(
        find.byKey(const Key('enrollment-passphrase')), 'короткая');
    await tapKey(tester, const Key('enrollment-enroll'));
    expect(
        find.textContaining('Recovery-фраза: минимум 24 символа'), findsOneWidget);
    expect(backend.enrollCalls, 0);

    // Валидная фраза: enrollment выполнен, шаг истории.
    const phrase = 'synthetic enrollment recovery phrase 24+';
    await tester.enterText(
        find.byKey(const Key('enrollment-passphrase')), phrase);
    await tapKey(tester, const Key('enrollment-enroll'));
    expect(backend.enrollCalls, 1);
    expect(backend.lastPhrase, phrase);
    expect(find.text('Перенести историю'), findsOneWidget);
    expect(find.text('Пропустить'), findsOneWidget);

    // Импорт: итог с счётчиками и недоставленными в v1.
    await tapKey(tester, const Key('enrollment-import'));
    expect(backend.importCalls, 1);
    expect(find.text('Перенесено сообщений: 10.'), findsOneWidget);
    expect(
        find.textContaining('Недоставленных осталось в очередях v1: 1'),
        findsOneWidget);

    await tapKey(tester, const Key('enrollment-finish'));
    expect(finished, true);
  });

  testWidgets('ошибка сети на challenge: русская ошибка и успешный повтор',
      (tester) async {
    final backend = _FakeEnrollmentBackend()
      ..sessionError = const SocketException('offline');
    await pumpScreen(tester, backend);
    await tapKey(tester, const Key('enrollment-connect'));
    expect(find.text('Нет связи с сервером. Проверьте сеть и повторите.'),
        findsOneWidget);
    expect(find.text('Подключиться'), findsOneWidget);
    expect(backend.enrollCalls, 0);

    backend.sessionError = null;
    await tapKey(tester, const Key('enrollment-connect'));
    expect(find.text('Зарегистрировать устройство'), findsOneWidget);
  });

  testWidgets('rotation_required: честное сообщение без тихой ротации',
      (tester) async {
    final backend = _FakeEnrollmentBackend()
      ..sessionError = RotationRequiredException(
          'Этот аккаунт использует ключ RSA-2048 и требует смены ключа.');
    await pumpScreen(tester, backend);
    await tapKey(tester, const Key('enrollment-connect'));
    expect(find.textContaining('RSA-2048'), findsOneWidget);
    expect(find.text('Подключиться'), findsOneWidget);
    expect(backend.enrollCalls, 0);
  });

  testWidgets('уже enrolled: идемпотентный вход сразу на шаг истории',
      (tester) async {
    final backend = _FakeEnrollmentBackend(enrolled: true, hasSession: true);
    await pumpScreen(tester, backend);
    expect(backend.sessionCalls, 0);
    expect(backend.enrollCalls, 0);
    expect(find.text('Перенести историю'), findsOneWidget);

    // Пропуск импорта: готово с честной заметкой, импорт не вызывался.
    await tapKey(tester, const Key('enrollment-skip-import'));
    expect(backend.importCalls, 0);
    expect(find.textContaining('Импорт истории пропущен'), findsOneWidget);
  });

  testWidgets('уже enrolled + история перенесена: сразу готово',
      (tester) async {
    final backend =
        _FakeEnrollmentBackend(enrolled: true, historyDone: true);
    await pumpScreen(tester, backend);
    expect(backend.sessionCalls, 0);
    expect(backend.enrollCalls, 0);
    expect(backend.importCalls, 0);
    expect(find.text('История уже перенесена ранее.'), findsOneWidget);
    expect(find.text('Завершить'), findsOneWidget);
  });

  testWidgets('ошибка enrollment не теряет шаг; повтор успешен',
      (tester) async {
    final backend = _FakeEnrollmentBackend(hasSession: true)
      ..enrollError = StateError('Recovery-фраза не совпадает с журналом');
    await pumpScreen(tester, backend);
    // Сессия уже есть: challenge пропущен.
    expect(find.text('Зарегистрировать устройство'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('enrollment-passphrase')),
        'synthetic enrollment recovery phrase 24+');
    await tapKey(tester, const Key('enrollment-enroll'));
    expect(find.textContaining('Recovery-фраза не совпадает'), findsOneWidget);
    expect(find.text('Зарегистрировать устройство'), findsOneWidget);

    backend.enrollError = null;
    await tapKey(tester, const Key('enrollment-enroll'));
    expect(backend.enrollCalls, 2);
    expect(find.text('Перенести историю'), findsOneWidget);
  });

  testWidgets('прогресс импорта отображается до завершения', (tester) async {
    final gate = Completer<HistoryImportResult>();
    final backend = _FakeEnrollmentBackend(hasSession: true)
      ..importGate = gate;
    await pumpScreen(tester, backend);
    await tester.enterText(find.byKey(const Key('enrollment-passphrase')),
        'synthetic enrollment recovery phrase 24+');
    await tapKey(tester, const Key('enrollment-enroll'));
    await tapKey(tester, const Key('enrollment-import'));
    expect(find.byKey(const Key('enrollment-import-progress')), findsOneWidget);
    expect(find.text('Перенесено 4 из 10'), findsOneWidget);
    // Кнопки заблокированы на время импорта.
    expect(
        tester
            .widget<FilledButton>(find.descendant(
                of: find.byKey(const Key('enrollment-import')),
                matching: find.byType(FilledButton)))
            .onPressed,
        isNull);

    gate.complete(const HistoryImportResult(
        total: 10,
        imported: 10,
        duplicates: 0,
        pendingLeft: 0,
        failed: 0,
        resumed: false,
        done: true));
    await tester.pump();
    expect(find.text('Перенесено сообщений: 10.'), findsOneWidget);
  });

  testWidgets('нерасшифрованные записи: предупреждение что они остались в v1',
      (tester) async {
    final backend = _FakeEnrollmentBackend(hasSession: true)
      ..result = const HistoryImportResult(
          total: 5,
          imported: 3,
          duplicates: 0,
          pendingLeft: 0,
          failed: 2,
          resumed: false,
          done: true);
    await pumpScreen(tester, backend);
    await tester.enterText(find.byKey(const Key('enrollment-passphrase')),
        'synthetic enrollment recovery phrase 24+');
    await tapKey(tester, const Key('enrollment-enroll'));
    await tapKey(tester, const Key('enrollment-import'));
    expect(find.textContaining('Не удалось расшифровать записей: 2'),
        findsOneWidget);
    expect(find.textContaining('остались в хранилище v1 без изменений'),
        findsOneWidget);
  });

  testWidgets('узкий экран и крупный шрифт: без overflow', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final backend = _FakeEnrollmentBackend(hasSession: true);
    await tester.pumpWidget(MaterialApp(
        builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(1.3)),
            child: child!),
        home: EnrollmentScreen(backend: backend)));
    await tester.pump();
    expect(tester.takeException(), isNull);
    // Самый длинный шаг (enrollment) и переход на историю — без overflow.
    await tester.enterText(find.byKey(const Key('enrollment-passphrase')),
        'synthetic enrollment recovery phrase 24+');
    await tapKey(tester, const Key('enrollment-enroll'));
    expect(tester.takeException(), isNull);
    expect(find.text('Перенести историю'), findsOneWidget);
    await tapKey(tester, const Key('enrollment-skip-import'));
    expect(tester.takeException(), isNull);
    expect(find.text('Завершить'), findsOneWidget);
  });

  testWidgets('enrollmentRoute: навигационная точка открывает мастер',
      (tester) async {
    final backend = _FakeEnrollmentBackend();
    await tester.pumpWidget(MaterialApp(
        home: Builder(
            builder: (context) => Scaffold(
                body: Center(
                    child: FilledButton(
                        onPressed: () => Navigator.of(context)
                            .push(enrollmentRoute(backend)),
                        child: const Text('Открыть мастер')))))));
    await tester.tap(find.text('Открыть мастер'));
    await tester.pumpAndSettle();
    expect(find.byType(EnrollmentScreen), findsOneWidget);
    expect(find.text('Подключиться'), findsOneWidget);
  });
}

/// Свежая БД (ffi factory) + enrolled-аккаунт + репозиторий без сети.
Future<
    (
      DatabaseService,
      V2Store,
      V2ChatRepository,
      Future<void> Function()
    )> _setup(CryptoService crypto, String account, String root,
    String privateKey) async {
  final folder = await Directory.systemTemp.createTemp('shade-import-');
  final db =
      await DatabaseService.openForTest(databaseFactoryFfi, '${folder.path}/db');
  final store = V2Store(db);
  await store.saveAccount(
      account: account,
      root: root,
      genesis: {'version': 2, 'account': account},
      history: [
        {'revision': 1}
      ],
      checkpoint: {'revision': 1},
      sessionId: 'primary');
  final transport = AlphaTransport('http://127.0.0.1:1', crypto);
  final repo = V2ChatRepository(
      transport: transport,
      crypto: crypto,
      store: store,
      account: account,
      root: root,
      privateKey: privateKey);
  await repo.load();
  return (
    db,
    store,
    repo,
    () async {
      transport.dispose();
      await db.close();
      await folder.delete(recursive: true);
    }
  );
}

/// Контрольная сумма всех v1-таблиц: импорт не должен изменить ни байта.
Future<String> _v1Checksum(DatabaseService db) async {
  final database = await db.database;
  final tables = [
    'users',
    'contacts',
    'conversations',
    'messages',
    'outbox',
    'groups',
    'group_members',
    'group_messages'
  ];
  final dump = <String, dynamic>{};
  for (final table in tables) {
    dump[table] = await database.rawQuery('SELECT * FROM $table ORDER BY rowid');
  }
  return sha256Hex(jsonEncode(dump));
}

/// Имитация сбоя посередине импорта: processRow бросает исключение после
/// crashAt записей (журнал батча ещё не зафиксирован).
class _CrashImporter extends V1HistoryImporter {
  _CrashImporter({
    required super.database,
    required super.store,
    required super.crypto,
    required super.account,
    required super.privateKey,
    super.batchSize,
    this.crashAt = 7,
  });

  final int crashAt;
  int seen = 0;
  bool crashed = false;

  @override
  Future<void> processRow(Map<String, dynamic> row) async {
    await super.processRow(row);
    seen++;
    if (!crashed && seen == crashAt) {
      crashed = true;
      throw StateError('simulated crash');
    }
  }
}

/// Фейковый backend мастера: счётчики вызовов, управляемые ошибки и гейт
/// импорта для проверки прогресса.
class _FakeEnrollmentBackend implements EnrollmentBackend {
  _FakeEnrollmentBackend({
    this.enrolled = false,
    this.hasSession = false,
    this.historyDone = false,
  });

  @override
  bool enrolled;
  @override
  bool hasSession;
  bool historyDone;

  int sessionCalls = 0;
  int enrollCalls = 0;
  int importCalls = 0;
  String? lastPhrase;
  Object? sessionError;
  Object? enrollError;
  Object? importError;
  Completer<HistoryImportResult>? importGate;
  HistoryImportResult result = const HistoryImportResult(
      total: 10,
      imported: 10,
      duplicates: 0,
      pendingLeft: 1,
      failed: 0,
      resumed: false,
      done: true);

  @override
  String get account => 'fake_user';

  @override
  Future<void> openLegacySession() async {
    sessionCalls++;
    if (sessionError != null) throw sessionError!;
    hasSession = true;
  }

  @override
  Future<Map<String, dynamic>> enroll(String recoveryPassphrase) async {
    enrollCalls++;
    lastPhrase = recoveryPassphrase;
    if (enrollError != null) throw enrollError!;
    enrolled = true;
    return {'revision': 1};
  }

  @override
  Future<bool> historyImportCompleted() async => historyDone;

  @override
  Future<HistoryImportResult> importHistory(
      {HistoryImportProgress? onProgress}) async {
    importCalls++;
    if (importError != null) throw importError!;
    onProgress?.call(4, 10);
    if (importGate != null) return importGate!.future;
    return result;
  }
}