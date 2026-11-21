import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fast_rsa/fast_rsa.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shade/core/database/database_service.dart';
import 'package:shade/core/services/crypto_service.dart';
import 'package:shade/core/services/device_v2/crypto.dart';
import 'package:shade/core/services/device_v2/protocol.dart';
import 'package:shade/core/services/device_v2/repository.dart';
import 'package:shade/core/services/device_v2/store.dart';
import 'package:shade/core/services/device_v2/transport.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Миграционные тесты клиента: crash-safe legacy-enrollment с долговечным
/// журналом, перенятие серверного каталога после сбоя, one-way мост v1-очереди
/// и аддитивная schema-миграция v9→v10. Синтетические данные; реальный alpha
/// запускается локально через tools/alpha-native-transport.mjs.
class _RealNetworkBinding extends AutomatedTestWidgetsFlutterBinding {
  @override
  bool get overrideHttpClient => false;
}

/// Имитация сбоя сети ПОСЛЕ коммита enrollment на сервере: ответ не доходит,
/// сессионная проверка тоже недоступна. Журнал должен позволить повтор.
class _CrashAfterCommitTransport extends AlphaTransport {
  _CrashAfterCommitTransport(super.origin, super.crypto);
  bool crashed = false;

  @override
  Future<Map<String, dynamic>> legacyEnrollment(
      Map<String, dynamic> genesis, Map<String, dynamic> manifest) async {
    await super.legacyEnrollment(genesis, manifest);
    crashed = true;
    throw AlphaTransportException(500, 'simulated_network_drop');
  }

  @override
  Future<Map<String, dynamic>> session() async {
    if (crashed) throw AlphaTransportException(503, 'simulated_offline');
    return super.session();
  }
}

/// Фейковый мост v1 для локального теста без сервера: очередь выдаётся один
/// раз, ACK по полному ref `from:id` опустошает её (как на реальном сервере).
class _FakeBridgeTransport extends AlphaTransport {
  _FakeBridgeTransport(super.origin, super.crypto, this.envelopes);
  List<Map<String, dynamic>> envelopes;
  final ackedRefs = <String>[];

  @override
  Future<List<dynamic>> legacyInbox(
          {required String account, required String id, required String privateKey}) async =>
      envelopes
          .where((e) => !ackedRefs.contains('${e['from']}:${e['id']}'))
          .map((e) => Map<String, dynamic>.from(e))
          .toList();

  @override
  Future<Map<String, dynamic>> legacyAck(List<String> refs,
      {required String account, required String id, required String privateKey}) async {
    ackedRefs.addAll(refs);
    return {'acknowledged': refs.length};
  }
}

void main() {
  _RealNetworkBinding();
  sqfliteFfiInit();

  test('clean native registration persists the first device and recovery package', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final folder = await Directory.systemTemp.createTemp('shade-native-signup-');
    final db = await DatabaseService.openForTest(databaseFactoryFfi, '${folder.path}/db');
    addTearDown(() async {
      await db.close();
      await folder.delete(recursive: true);
    });
    final process = await Process.start('node', ['../server/tools/alpha-native-transport.mjs']);
    final lines = StreamIterator(process.stdout.transform(utf8.decoder).transform(const LineSplitter()));
    final errors = process.stderr.drain<void>();
    addTearDown(() async {
      await process.stdin.close();
      expect(await process.exitCode.timeout(const Duration(seconds: 10)), 0);
      await lines.cancel();
      await errors;
    });
    expect(await lines.moveNext(), isTrue);
    process.stdin.writeln(jsonEncode({'action': 'init-registration'}));
    expect(await lines.moveNext().timeout(const Duration(seconds: 15)), isTrue);
    final fixture = jsonDecode(lines.current) as Map<String, dynamic>;
    expect(fixture['ok'], isTrue, reason: fixture['error']?.toString());
    final info = fixture['result'] as Map<String, dynamic>;
    final crypto = CryptoService();
    final transport = AlphaTransport(info['origin'] as String, crypto);
    transport.sessionCookie = info['cookie'] as String;
    addTearDown(transport.dispose);
    final store = V2Store(db);
    V2ChatRepository repository() => V2ChatRepository.pairing(
        transport: transport, crypto: crypto, store: store, account: 'native_fresh');
    expect((await transport.session())['account'], isNull);
    const phrase = 'synthetic recovery phrase for native registration';
    final package = await repository().registerNewAccount(phrase);
    expect((await transport.session())['account'], 'native_fresh');
    final restored = repository();
    await restored.load();
    expect(restored.enrolled, isTrue);
    expect(restored.session.id, isNot('primary'));
    expect(restored.session.encryptionKey, isNot(restored.session.signingKey));
    expect(package['genesis'], restored.accountSnapshot!['genesis']);
    expect(package['backup'], restored.accountSnapshot!['recovery']);
    expect(await store.loadEnrollmentJournal('native_fresh'), isNull);
    await transport.deviceSession('native_fresh', restored.session.id, restored.session.signingPrivateKey);
  }, timeout: const Timeout(Duration(seconds: 120)));

  test('schema v9→v10 upgrade preserves history and adds enrollment journal',
      () async {
    FlutterSecureStorage.setMockInitialValues({});
    final folder = await Directory.systemTemp.createTemp('shade-v10-');
    final path = '${folder.path}/db';
    var db = await DatabaseService.openForTest(databaseFactoryFfi, path,
        schemaVersion: 9);
    final old = V2Store(db);
    await old.saveAccount(
        account: 'upgrade_user',
        root: 'cm9vdA==',
        genesis: {'version': 2},
        history: [
          {'revision': 1}
        ],
        checkpoint: {'revision': 1},
        sessionId: 'primary');
    await db.close();

    db = await DatabaseService.openForTest(databaseFactoryFfi, path);
    final store = V2Store(db);
    final acc = await store.loadAccount('upgrade_user');
    expect(acc, isNotNull, reason: 'v9 account must survive the upgrade');
    expect(acc!['sessionId'], 'primary');

    await store.saveEnrollmentJournal(
        account: 'upgrade_user',
        root: 'cm9vdA==',
        genesis: {'version': 2, 'account': 'upgrade_user'},
        manifest: {'revision': 1},
        recoveryBackup: {'version': 2, 'ciphertext': 'encrypted-only'});
    final journal = await store.loadEnrollmentJournal('upgrade_user');
    expect(journal!['phase'], 'prepared');
    expect((journal['recoveryBackup'] as Map)['ciphertext'], 'encrypted-only');
    await store.deleteEnrollmentJournal('upgrade_user');
    expect(await store.loadEnrollmentJournal('upgrade_user'), isNull);
    await db.close();
    await folder.delete(recursive: true);
  });

  test('crash after server commit: journal resumes enrollment without key loss',
      () async {
    FlutterSecureStorage.setMockInitialValues({});
    final crypto = CryptoService();
    final kp = await RSA.generate(4096);
    final root = await publicSpki(kp.publicKey);
    final folder = await Directory.systemTemp.createTemp('shade-v2-crash-');
    final db = await DatabaseService.openForTest(
        databaseFactoryFfi, '${folder.path}/db');
    final store = V2Store(db);

    final process = await Process.start(
        'node', ['../server/tools/alpha-native-transport.mjs']);
    final lines = StreamIterator(process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter()));
    final stderr = process.stderr.transform(utf8.decoder).join();
    addTearDown(() async {
      await process.stdin.close();
      final exit = await process.exitCode.timeout(const Duration(seconds: 20),
          onTimeout: () {
        process.kill();
        return -1;
      });
      await lines.cancel();
      expect(exit, 0, reason: await stderr);
      await db.close();
      await folder.delete(recursive: true);
    });
    Future<Map<String, dynamic>> next() async {
      expect(await lines.moveNext().timeout(const Duration(seconds: 90)), true);
      return jsonDecode(lines.current) as Map<String, dynamic>;
    }

    Future<Map<String, dynamic>> request(Map<String, dynamic> value) async {
      process.stdin.writeln(jsonEncode(value));
      final result = await next();
      expect(result['ok'], true, reason: result['error']?.toString());
      return result['result'] as Map<String, dynamic>;
    }

    expect((await next())['ready'], true);
    final init = await request({'action': 'init', 'publicKey': kp.publicKey});
    const phrase = 'synthetic crash recovery phrase only';

    final crashTransport =
        _CrashAfterCommitTransport(init['origin'] as String, crypto);
    crashTransport.sessionCookie = init['nativeCookie'] as String;
    addTearDown(crashTransport.dispose);
    final repo = V2ChatRepository(
        transport: crashTransport,
        crypto: crypto,
        store: store,
        account: 'native_android',
        root: root,
        privateKey: kp.privateKey);
    await repo.load();

    // Сбой после коммита: сервер enrolled, локально аккаунта нет, журнал есть.
    await expectLater(
        repo.enrollLegacy(recoveryPassphrase: phrase),
        throwsA(isA<AlphaTransportException>()));
    expect(crashTransport.crashed, true);
    expect(repo.enrolled, false);
    final journal = await store.loadEnrollmentJournal('native_android');
    expect(journal, isNotNull);
    expect(journal!['phase'], 'prepared');
    final journaledGenesis =
        Map<String, dynamic>.from(journal['genesis'] as Map);

    // «Перезапуск»: новый транспорт/репозиторий, то же хранилище и ключ.
    final transport = AlphaTransport(init['origin'] as String, crypto);
    transport.sessionCookie = init['nativeCookie'] as String;
    addTearDown(transport.dispose);
    final resumed = V2ChatRepository(
        transport: transport,
        crypto: crypto,
        store: store,
        account: 'native_android',
        root: root,
        privateKey: kp.privateKey);
    await resumed.load();

    // Неверная фраза не повреждает журнал и не создаёт новый genesis.
    await expectLater(
        resumed.enrollLegacy(recoveryPassphrase: 'wrong passphrase wrong passphrase'),
        throwsA(predicate((e) => e.toString().contains('Recovery-фраза'))));
    expect(await store.loadEnrollmentJournal('native_android'), isNotNull);
    expect(resumed.enrolled, false);

    // Верная фраза: каталог перенимается, recovery разблокируется, журнал удалён.
    final result = await resumed.enrollLegacy(recoveryPassphrase: phrase);
    expect(result['revision'], 1);
    expect(result['adopted'], true);
    expect(resumed.enrolled, true);
    expect(await store.loadEnrollmentJournal('native_android'), isNull);
    final acc = await store.loadAccount('native_android');
    expect(sha256Hex(genesisText(acc!['genesis'] as Map<String, dynamic>)),
        sha256Hex(genesisText(journaledGenesis)));
    final v2 = DeviceV2Crypto(crypto);
    final pem = await v2.unlockRecoveryBackup(
        acc['recovery'] as Map<String, dynamic>,
        phrase,
        acc['genesis'] as Map<String, dynamic>);
    expect(pem, contains('BEGIN PRIVATE KEY'));

    // Повторный enroll не дублирует каталог (идемпотентный resume).
    final again = await resumed.enrollLegacy(recoveryPassphrase: phrase);
    expect(again['revision'], 1);
    expect((await store.loadAccount('native_android'))!['history'] as List,
        hasLength(1));
  }, timeout: const Timeout(Duration(minutes: 6)));

  test('E2E bridge: real v1 store → alpha → Dart client drains queued ciphertext',
      () async {
    FlutterSecureStorage.setMockInitialValues({});
    final crypto = CryptoService();
    final kp = await RSA.generate(4096);
    final root = await publicSpki(kp.publicKey);
    final folder = await Directory.systemTemp.createTemp('shade-e2e-bridge-');
    final db = await DatabaseService.openForTest(
        databaseFactoryFfi, '${folder.path}/db');
    final store = V2Store(db);

    final process = await Process.start(
        'node', ['../server/tools/alpha-native-transport.mjs']);
    final lines = StreamIterator(process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter()));
    final stderr = process.stderr.transform(utf8.decoder).join();
    addTearDown(() async {
      await process.stdin.close();
      final exit = await process.exitCode.timeout(const Duration(seconds: 20),
          onTimeout: () {
        process.kill();
        return -1;
      });
      await lines.cancel();
      expect(exit, 0, reason: await stderr);
      await db.close();
      await folder.delete(recursive: true);
    });
    Future<Map<String, dynamic>> next() async {
      expect(await lines.moveNext().timeout(const Duration(seconds: 120)), true);
      return jsonDecode(lines.current) as Map<String, dynamic>;
    }

    Future<Map<String, dynamic>> request(Map<String, dynamic> value) async {
      process.stdin.writeln(jsonEncode(value));
      final result = await next();
      expect(result['ok'], true, reason: result['error']?.toString());
      return result['result'] as Map<String, dynamic>;
    }

    expect((await next())['ready'], true);
    final init =
        await request({'action': 'init-bridge', 'publicKey': kp.publicKey});
    expect(init['keyMatch'], true, reason: 'v1 fixture must use the device RSA');
    final transport = AlphaTransport(init['origin'] as String, crypto);
    transport.sessionCookie = init['nativeCookie'] as String;
    addTearDown(transport.dispose);
    final repo = V2ChatRepository(
        transport: transport,
        crypto: crypto,
        store: store,
        account: 'native_android',
        root: root,
        privateKey: kp.privateKey);
    await repo.load();

    // Enrollment тем же аккаунтом (Google-сессия подготовленного legacy).
    final enrolled = await repo.enrollLegacy(
        recoveryPassphrase: 'synthetic e2e bridge recovery phrase');
    expect(enrolled['revision'], 1);
    final acc = await store.loadAccount('native_android');
    await request({
      'action': 'accept-native',
      'genesis': acc!['genesis'],
      'manifest': (acc['history'] as List).first
    });

    // Недошедшая v1-очередь (текст + IMG) доставлена мостом и расшифрована
    // тем же исходным RSA; сервер видел только ciphertext.
    expect(await repo.syncLegacyInbox(), 2);
    final msgs = await repo.getMessages('v1_peer');
    expect(msgs.length, 2);
    final textMsg = msgs.firstWhere((m) => m['isImage'] != true);
    expect(textMsg['text'], 'v1 текст до миграции');
    final imgMsg = msgs.firstWhere((m) => m['isImage'] == true);
    expect((imgMsg['imageData'] as List<int>).length, 64);

    // Bridge-ack экспортирован для v1-сервера (очередь v1 будет подрезана).
    final ackJson = jsonDecode(
        await File(init['bridgeAckPath'] as String).readAsString());
    final acked =
        (ackJson['accounts']['native_android']['acked'] as List).cast<String>();
    for (final id in (init['queuedIds'] as List).cast<String>()) {
      expect(acked, contains('v1_peer:$id'));
    }

    // v1-отправитель пишет ПОСЛЕ enrollment: live top-up доставляет без дублей.
    final late = await request({'action': 'v1-send', 'text': 'позднее v1 сообщение'});
    expect(await repo.syncLegacyInbox(), 1);
    final all = await repo.getMessages('v1_peer');
    expect(all.length, 3);
    expect(all.last['text'], 'позднее v1 сообщение');
    expect(all.last['messageId'], late['id']);
    expect(await repo.syncLegacyInbox(), 0);
    expect((await repo.getMessages('v1_peer')).length, 3);

    // v2-переписка после миграции работает (Web-собеседник).
    final webGenesis = init['web']['genesis'] as Map<String, dynamic>;
    await repo.confirmContact('native_web', sha256Hex(genesisText(webGenesis)));
    await repo.sendMessage('native_web', 'v2 после моста');
    final opened = await request({'action': 'web-fetch-open'});
    expect(opened['plaintext'], 'v2 после моста');
  }, timeout: const Timeout(Duration(minutes: 6)));

  test('legacy v1 inbox bridge: ciphertext stored, dedup, ACK, IMG decode',
      () async {
    FlutterSecureStorage.setMockInitialValues({});
    final crypto = CryptoService();
    final kp = await RSA.generate(4096);
    final root = await publicSpki(kp.publicKey);
    final folder = await Directory.systemTemp.createTemp('shade-v1-bridge-');
    final db = await DatabaseService.openForTest(
        databaseFactoryFfi, '${folder.path}/db');
    final store = V2Store(db);
    addTearDown(() async {
      await db.close();
      await folder.delete(recursive: true);
    });

    // Минимальная запись enrolled-аккаунта для локального теста моста.
    await store.saveAccount(
        account: 'bridge_user',
        root: root,
        genesis: {'version': 2, 'account': 'bridge_user'},
        history: [
          {'revision': 1}
        ],
        checkpoint: {'revision': 1},
        sessionId: 'primary');

    const text = 'старое сообщение v1';
    final photoB64 = base64.encode(List.generate(64, (i) => i));
    final envelopes = [
      {
        'id': 'v1msg000000000001',
        'from': 'bridge_peer',
        'timestamp': 1700000000000,
        'data': await crypto.encryptData(text, kp.publicKey)
      },
      {
        'id': 'v1msg000000000002',
        'from': 'bridge_peer',
        'timestamp': 1700000000001,
        'data': await crypto.encryptData('IMG:$photoB64', kp.publicKey)
      },
    ];
    final transport =
        _FakeBridgeTransport('http://127.0.0.1:1', crypto, envelopes);
    addTearDown(transport.dispose);
    final repo = V2ChatRepository(
        transport: transport,
        crypto: crypto,
        store: store,
        account: 'bridge_user',
        root: root,
        privateKey: kp.privateKey);
    await repo.load();

    expect(await repo.syncLegacyInbox(), 2);
    expect(transport.ackedRefs, hasLength(2));
    expect(transport.ackedRefs, contains('bridge_peer:v1msg000000000001'));
    final messages = await repo.getMessages('bridge_peer');
    expect(messages.length, 2);
    expect(messages.first['text'], text);
    expect(messages.first['direction'], 'in');
    expect(messages.last['isImage'], true);
    expect(base64.encode(messages.last['imageData'] as List<int>), photoB64);

    // Повторная синхронизация (перезапуск/потерянный ACK) не дублирует.
    expect(await repo.syncLegacyInbox(), 0);
    expect((await repo.getMessages('bridge_peer')).length, 2);

    // Новое сообщение v1, пришедшее после первой синхронизации, доставляется.
    envelopes.add({
      'id': 'v1msg000000000003',
      'from': 'bridge_peer',
      'timestamp': 1700000000002,
      'data': await crypto.encryptData('позднее v1', kp.publicKey)
    });
    expect(await repo.syncLegacyInbox(), 1);
    expect((await repo.getMessages('bridge_peer')).length, 3);

    // Коллизия id двух отправителей: ACK одного НЕ удаляет сообщение другого.
    envelopes.add({
      'id': 'v1msg000000000001',
      'from': 'other_peer',
      'timestamp': 1700000000003,
      'data': await crypto.encryptData('чужой id', kp.publicKey)
    });
    expect(await repo.syncLegacyInbox(), 1);
    expect((await repo.getMessages('other_peer')).length, 1);
    expect(transport.ackedRefs, contains('other_peer:v1msg000000000001'));
  }, timeout: const Timeout(Duration(minutes: 3)));

  test(
      'RSA-2048 → RSA-4096 rotation: old-key attestation, new anchor, legacy decryption',
      () async {
    FlutterSecureStorage.setMockInitialValues({});
    final crypto = CryptoService();
    final old = await RSA.generate(2048);
    final oldRoot = await publicSpki(old.publicKey);
    final folder = await Directory.systemTemp.createTemp('shade-rot-');
    final db = await DatabaseService.openForTest(
        databaseFactoryFfi, '${folder.path}/db');
    final store = V2Store(db);
    final transport =
        _FakeRotationTransport('http://127.0.0.1:1', crypto, oldRoot);
    addTearDown(transport.dispose);
    final repo = V2ChatRepository(
        transport: transport,
        crypto: crypto,
        store: store,
        account: 'rot_user',
        root: oldRoot,
        privateKey: old.privateKey);
    await repo.load();

    const phrase = 'synthetic rotation recovery phrase 24+';
    final result = await repo.enrollWithRotation(recoveryPassphrase: phrase);
    expect(result['rotated'], true);
    expect(repo.root, isNot(oldRoot));
    expect(repo.privateKey, isNot(old.privateKey));
    expect(repo.legacyPrivateKey, old.privateKey);

    // Аттестация подписана СТАРЫМ ключом и связывает точные digest каталога.
    final a = transport.capturedAttestation!;
    expect(a['oldRootFingerprint'], spkiFingerprint(oldRoot));
    expect(a['newRoot'], repo.root);
    expect(a['genesisDigest'],
        sha256Hex(genesisText(transport.capturedGenesis!)));
    expect(a['manifestDigest'],
        sha256Hex(manifestText(transport.capturedManifest!)));
    expect(
        await crypto.verifySignature(
            rotationText(a), a['signature'] as String, old.publicKey),
        true);

    // Новый якорь и legacy-ключ сохранены (SQLCipher); журнал удалён.
    final acc = await store.loadAccount('rot_user');
    expect(acc!['anchorKey'], repo.privateKey);
    expect(acc['legacyKey'], old.privateKey);
    expect(await store.loadEnrollmentJournal('rot_user'), isNull);

    // Старый v1-ciphertext расшифровывается legacy-ключом после rotation.
    transport.envelopes.add({
      'id': 'rotmsg0000000001',
      'from': 'old_peer',
      'timestamp': 1700000000000,
      'data': await crypto.encryptData('старое сообщение', old.publicKey)
    });
    expect(await repo.syncLegacyInbox(), 1);
    final messages = await repo.getMessages('old_peer');
    expect(messages.single['text'], 'старое сообщение');

    // Идемпотентность: повтор не пересоздаёт ключи.
    final again = await repo.enrollWithRotation(recoveryPassphrase: phrase);
    expect(again['alreadyEnrolled'], true);
    await db.close();
    await folder.delete(recursive: true);
  }, timeout: const Timeout(Duration(minutes: 4)));

  test(
      'rotation crash after server commit: journal resumes; wrong phrase never corrupts state',
      () async {
    FlutterSecureStorage.setMockInitialValues({});
    final crypto = CryptoService();
    final old = await RSA.generate(2048);
    final oldRoot = await publicSpki(old.publicKey);
    final folder = await Directory.systemTemp.createTemp('shade-rot-crash-');
    final db = await DatabaseService.openForTest(
        databaseFactoryFfi, '${folder.path}/db');
    final store = V2Store(db);
    final transport = _FakeRotationTransport(
        'http://127.0.0.1:1', crypto, oldRoot,
        crashOnce: true);
    addTearDown(transport.dispose);
    final repo = V2ChatRepository(
        transport: transport,
        crypto: crypto,
        store: store,
        account: 'rot_user',
        root: oldRoot,
        privateKey: old.privateKey);
    await repo.load();

    const phrase = 'synthetic rotation recovery phrase 24+';
    // Первый вызов: сервер «уже закоммитил», ответ потерялся → adoption.
    final result = await repo.enrollWithRotation(recoveryPassphrase: phrase);
    expect(result['adopted'], true);
    expect(repo.enrolled, true);
    expect(repo.legacyPrivateKey, old.privateKey);
    expect(await store.loadEnrollmentJournal('rot_user'), isNull);

    // Второй сценарий: crash ДО коммита, затем неверная фраза на повторе.
    final folder2 = await Directory.systemTemp.createTemp('shade-rot-crash2-');
    final db2 = await DatabaseService.openForTest(
        databaseFactoryFfi, '${folder2.path}/db');
    final store2 = V2Store(db2);
    final transport2 = _FakeRotationTransport(
        'http://127.0.0.1:1', crypto, oldRoot,
        crashBeforeCommit: true);
    addTearDown(transport2.dispose);
    final repo2 = V2ChatRepository(
        transport: transport2,
        crypto: crypto,
        store: store2,
        account: 'rot_user',
        root: oldRoot,
        privateKey: old.privateKey);
    await repo2.load();
    // Crash ДО коммита: серверного каталога нет, повтор не подтверждается.
    await expectLater(
        repo2.enrollWithRotation(recoveryPassphrase: phrase),
        throwsA(isA<StateError>()));
    final journal = await store2.loadEnrollmentJournal('rot_user');
    expect(journal, isNotNull);
    expect(journal!['anchorKey'], isNotNull);
    final anchorBefore = journal['anchorKey'];
    // Сервер «доступен», но фраза не совпадает с журнальным recovery-пакетом:
    // состояние не повреждается, ключи не пересоздаются.
    transport2.crashBeforeCommit = false;
    await expectLater(
        repo2.enrollWithRotation(recoveryPassphrase: 'wrong phrase wrong phrase wrong'),
        throwsA(isA<StateError>()));
    final journal2 = await store2.loadEnrollmentJournal('rot_user');
    expect(journal2!['anchorKey'], anchorBefore);
    // Та же фраза, что и при первой попытке → успешное завершение.
    final ok = await repo2.enrollWithRotation(recoveryPassphrase: phrase);
    expect(ok['revision'], 1);
    expect(repo2.enrolled, true);
    await db.close();
    await db2.close();
    await folder.delete(recursive: true);
    await folder2.delete(recursive: true);
  }, timeout: const Timeout(Duration(minutes: 5)));
}

/// Фейковый rotation-транспорт: фиксирует аттестацию/genesis/manifest,
/// имитирует crash после коммита (adoption через сессию новым ключом)
/// и crash до коммита (журнал + повтор).
class _FakeRotationTransport extends AlphaTransport {
  _FakeRotationTransport(super.origin, super.crypto, this.oldRoot,
      {this.crashOnce = false, this.crashBeforeCommit = false});
  final String oldRoot;
  bool crashOnce;
  bool crashBeforeCommit;
  Map<String, dynamic>? capturedGenesis;
  Map<String, dynamic>? capturedManifest;
  Map<String, dynamic>? capturedAttestation;
  final ackedRefs = <String>[];
  List<Map<String, dynamic>> envelopes = [];

  @override
  Future<Map<String, dynamic>> rotationChallenge(String account) async => {
        'nonce': 'a' * 64,
        'oldRootFingerprint': spkiFingerprint(oldRoot)
      };

  @override
  Future<Map<String, dynamic>> legacyRotation(
      String account,
      String nonce,
      Map<String, dynamic> attestation,
      Map<String, dynamic> genesis,
      Map<String, dynamic> manifest) async {
    capturedGenesis = genesis;
    capturedManifest = manifest;
    capturedAttestation = attestation;
    if (crashBeforeCommit) {
      throw AlphaTransportException(503, 'simulated_offline_before_commit');
    }
    if (crashOnce) {
      crashOnce = false;
      throw AlphaTransportException(503, 'simulated_offline_after_commit');
    }
    return {'revision': 1, 'digest': sha256Hex(manifestText(manifest))};
  }

  @override
  Future<String> legacyChallenge(String account) async => 'b' * 64;

  @override
  Future<Map<String, dynamic>> legacySession(
          String account, String nonce, String proof) async =>
      {'authenticated': true, 'account': account};

  @override
  Future<Map<String, dynamic>> session() async => {
        'account': 'rot_user',
        'directory': (capturedGenesis == null || crashBeforeCommit)
            ? null
            : {
                'root': capturedGenesis!['firstDevice']['encryptionKey'],
                'genesis': capturedGenesis,
                'history': [capturedManifest]
              }
      };

  @override
  Future<List<dynamic>> legacyInbox(
          {required String account,
          required String id,
          required String privateKey}) async =>
      envelopes
          .where((e) => !ackedRefs.contains('${e['from']}:${e['id']}'))
          .map((e) => Map<String, dynamic>.from(e))
          .toList();

  @override
  Future<Map<String, dynamic>> legacyAck(List<String> refs,
      {required String account,
      required String id,
      required String privateKey}) async {
    ackedRefs.addAll(refs);
    return {'acknowledged': refs.length};
  }
}