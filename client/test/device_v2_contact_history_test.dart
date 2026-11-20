import 'dart:convert';
import 'dart:io';

import 'package:fast_rsa/fast_rsa.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shade/core/database/database_service.dart';
import 'package:shade/core/services/crypto_service.dart';
import 'package:shade/core/services/device_v2/crypto.dart';
import 'package:shade/core/services/device_v2/payload.dart';
import 'package:shade/core/services/device_v2/protocol.dart';
import 'package:shade/core/services/device_v2/repository.dart';
import 'package:shade/core/services/device_v2/store.dart';
import 'package:shade/core/services/device_v2/transport.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Долговечная проверенная history каталога контакта (расширение для
/// offline peer-seal в sync.dart): онлайн-верификация сохраняет цепочку,
/// offline-seal работает без сети, подмена chain отклоняется fail-closed,
/// старые записи без history не ломают загрузку.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  test('offline-seal после онлайн-верификации работает без сети', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final crypto = CryptoService();
    final v2 = DeviceV2Crypto(crypto);
    final ownKp = await RSA.generate(4096);
    final peerKp = await RSA.generate(4096);
    final recoveryKp = await RSA.generate(4096);
    final ownRoot = await publicSpki(ownKp.publicKey);
    final peerRoot = await publicSpki(peerKp.publicKey);
    final recoverySpki = await publicSpki(recoveryKp.publicKey);
    final folder = await Directory.systemTemp.createTemp('shade-history-');
    final db = await DatabaseService.openForTest(
        databaseFactoryFfi, '${folder.path}/db');
    addTearDown(() async {
      await db.close();
      await folder.delete(recursive: true);
    });
    final store = V2Store(db);
    final transport = DirectoryTransport(crypto);
    addTearDown(transport.dispose);

    // Собственный аккаунт: legacy genesis + каталог revision 1.
    final ownGenesis = v2.buildLegacyGenesis('own_history', ownRoot, recoverySpki);
    ownGenesis['signature'] =
        await crypto.signData(genesisText(ownGenesis), ownKp.privateKey);
    final ownManifest = v2.buildLegacyManifest('own_history', ownRoot);
    ownManifest['signature'] =
        await crypto.signData(manifestText(ownManifest), ownKp.privateKey);
    final ownCheckpoint = {
      'account': 'own_history',
      'rootFingerprint': spkiFingerprint(ownRoot),
      'revision': 1,
      'digest': sha256Hex(manifestText(ownManifest)),
      'genesisDigest': sha256Hex(genesisText(ownGenesis))
    };
    await store.saveAccount(
        account: 'own_history',
        root: ownRoot,
        genesis: ownGenesis,
        history: [ownManifest],
        checkpoint: ownCheckpoint,
        sessionId: 'primary');
    final repo = V2ChatRepository(
        transport: transport,
        crypto: crypto,
        store: store,
        account: 'own_history',
        root: ownRoot,
        privateKey: ownKp.privateKey);
    await repo.load();

    // Каталог контакта: genesis + tip, подписанные корневым ключом peer.
    final peerGenesis = v2.buildLegacyGenesis('peer_history', peerRoot, recoverySpki);
    peerGenesis['signature'] =
        await crypto.signData(genesisText(peerGenesis), peerKp.privateKey);
    final peerManifest = v2.buildLegacyManifest('peer_history', peerRoot);
    peerManifest['signature'] =
        await crypto.signData(manifestText(peerManifest), peerKp.privateKey);
    transport.dir = {
      'root': peerRoot,
      'genesis': peerGenesis,
      'history': [peerManifest]
    };

    // Онлайн-верификация: confirmContact сохраняет проверенную цепочку.
    await repo.confirmContact(
        'peer_history', sha256Hex(genesisText(peerGenesis)));
    final contact = await store.loadContact('peer_history');
    expect(contact!['confirmed'], true);
    expect((contact['history'] as List).length, 1);
    expect(sha256Hex(manifestText((contact['history'] as List).first)),
        digestOf(peerManifest));

    // Сеть выключена: сохранённая history доступна для offline-seal.
    transport.networkDown = true;
    final peerHistory = await repo.contactHistory('peer_history');
    expect(peerHistory, isNotNull);
    expect(repo.ownHistory, isNotNull);
    final peerCheckpoint = contact['checkpoint'] as Map<String, dynamic>;
    const text = 'offline-привет без сети 🔐';
    final message = await v2.sealMessage(
        encodePayload(text, null),
        repo.ownHistory!,
        peerHistory!,
        DeviceV2Session(
            account: 'own_history',
            id: 'primary',
            encryptionKey: ownRoot,
            signingKey: ownRoot,
            encryptionPrivateKey: ownKp.privateKey,
            signingPrivateKey: ownKp.privateKey),
        AccountTrust(
            root: ownRoot,
            genesis: ownGenesis,
            checkpoint: ownCheckpoint),
        AccountTrust(
            root: peerRoot,
            genesis: peerGenesis,
            checkpoint: peerCheckpoint));
    // Контакт реально расшифровывает offline-запечатанное сообщение.
    final opened = await v2.openMessage(
        {
          'message': message,
          'senderHistory': repo.ownHistory,
          'recipientHistory': peerHistory
        },
        DeviceV2Session(
            account: 'peer_history',
            id: 'primary',
            encryptionKey: peerRoot,
            signingKey: peerRoot,
            encryptionPrivateKey: peerKp.privateKey,
            signingPrivateKey: peerKp.privateKey),
        AccountTrust(
            root: ownRoot, genesis: ownGenesis, checkpoint: ownCheckpoint),
        AccountTrust(
            root: peerRoot, genesis: peerGenesis, checkpoint: peerCheckpoint));
    expect(opened, text);
    // Онлайн-путь при этом честно заблокирован без сети.
    await expectLater(repo.sendMessage('peer_history', 'ещё'),
        throwsA(isA<AlphaTransportException>()));
  }, timeout: const Timeout(Duration(minutes: 6)));

  test('подмена history отклоняется fail-closed, сохранённая не обновляется',
      () async {
    FlutterSecureStorage.setMockInitialValues({});
    final crypto = CryptoService();
    final v2 = DeviceV2Crypto(crypto);
    final ownKp = await RSA.generate(4096);
    final peerKp = await RSA.generate(4096);
    final recoveryKp = await RSA.generate(4096);
    final ownRoot = await publicSpki(ownKp.publicKey);
    final peerRoot = await publicSpki(peerKp.publicKey);
    final recoverySpki = await publicSpki(recoveryKp.publicKey);
    final folder = await Directory.systemTemp.createTemp('shade-history-');
    final db = await DatabaseService.openForTest(
        databaseFactoryFfi, '${folder.path}/db');
    addTearDown(() async {
      await db.close();
      await folder.delete(recursive: true);
    });
    final store = V2Store(db);
    final transport = DirectoryTransport(crypto);
    addTearDown(transport.dispose);
    final ownGenesis = v2.buildLegacyGenesis('own_history', ownRoot, recoverySpki);
    ownGenesis['signature'] =
        await crypto.signData(genesisText(ownGenesis), ownKp.privateKey);
    final ownManifest = v2.buildLegacyManifest('own_history', ownRoot);
    ownManifest['signature'] =
        await crypto.signData(manifestText(ownManifest), ownKp.privateKey);
    await store.saveAccount(
        account: 'own_history',
        root: ownRoot,
        genesis: ownGenesis,
        history: [ownManifest],
        checkpoint: {
          'account': 'own_history',
          'rootFingerprint': spkiFingerprint(ownRoot),
          'revision': 1,
          'digest': sha256Hex(manifestText(ownManifest)),
          'genesisDigest': sha256Hex(genesisText(ownGenesis))
        },
        sessionId: 'primary');
    final repo = V2ChatRepository(
        transport: transport,
        crypto: crypto,
        store: store,
        account: 'own_history',
        root: ownRoot,
        privateKey: ownKp.privateKey);
    await repo.load();
    final peerGenesis = v2.buildLegacyGenesis('peer_history', peerRoot, recoverySpki);
    peerGenesis['signature'] =
        await crypto.signData(genesisText(peerGenesis), peerKp.privateKey);
    final peerManifest = v2.buildLegacyManifest('peer_history', peerRoot);
    peerManifest['signature'] =
        await crypto.signData(manifestText(peerManifest), peerKp.privateKey);
    transport.dir = {
      'root': peerRoot,
      'genesis': peerGenesis,
      'history': [peerManifest]
    };
    await repo.confirmContact(
        'peer_history', sha256Hex(genesisText(peerGenesis)));
    final before = jsonEncode((await store.loadContact('peer_history'))!['history']);
    final checkpointBefore =
        jsonEncode((await store.loadContact('peer_history'))!['checkpoint']);

    // Форк на той же ревизии: подпись валидна, digest другой — rollback/fork.
    final fork = v2.buildLegacyManifest('peer_history', peerRoot,
        now: DateTime.now().millisecondsSinceEpoch + 5000);
    fork['signature'] =
        await crypto.signData(manifestText(fork), peerKp.privateKey);
    transport.dir = {
      'root': peerRoot,
      'genesis': peerGenesis,
      'history': [fork]
    };
    await expectLater(repo.sendMessage('peer_history', 'подмена'),
        throwsA(predicate((e) => e.toString().contains('rollback or fork'))));
    final after = await store.loadContact('peer_history');
    expect(jsonEncode(after!['history']), before);
    expect(jsonEncode(after['checkpoint']), checkpointBefore);

    // Легитимное продолжение цепочки (revision 2) обновляет history.
    final next = <String, dynamic>{
      'account': 'peer_history',
      'rootFingerprint': spkiFingerprint(peerRoot),
      'revision': 2,
      'previous': sha256Hex(manifestText(peerManifest)),
      'issuedAt': DateTime.now().millisecondsSinceEpoch,
      'expiresAt': DateTime.now().millisecondsSinceEpoch + maxLeaseMs,
      'devices': peerManifest['devices'],
      'signer': 'primary',
      'signature': ''
    };
    next['signature'] =
        await crypto.signData(manifestText(next), peerKp.privateKey);
    transport.dir = {
      'root': peerRoot,
      'genesis': peerGenesis,
      'history': [peerManifest, next]
    };
    await repo.sendMessage('peer_history', 'легитимное сообщение');
    final updated = await repo.contactHistory('peer_history');
    expect(updated!.length, 2);
    expect((updated.last as Map)['revision'], 2);
  }, timeout: const Timeout(Duration(minutes: 6)));

  test('старая запись без history не ломает загрузку и offline-seal', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final crypto = CryptoService();
    final folder = await Directory.systemTemp.createTemp('shade-history-');
    final db = await DatabaseService.openForTest(
        databaseFactoryFfi, '${folder.path}/db');
    addTearDown(() async {
      await db.close();
      await folder.delete(recursive: true);
    });
    final store = V2Store(db);
    final transport = DirectoryTransport(crypto);
    addTearDown(transport.dispose);
    // Запись старого формата: history отсутствует (NULL до первой верификации).
    await store.saveContact(
        account: 'legacy_peer',
        root: 'cm9vdA==',
        genesis: {'version': 2, 'account': 'legacy_peer'},
        checkpoint: {'revision': 1},
        genesisDigest: 'ab' * 32,
        confirmed: true);
    final loaded = await store.loadContact('legacy_peer');
    expect(loaded, isNotNull);
    expect(loaded!['history'], null);
    final repo = V2ChatRepository(
        transport: transport,
        crypto: crypto,
        store: store,
        account: 'own_history',
        root: 'cm9vdA==',
        privateKey: '');
    await repo.load();
    // Fail-closed: offline-seal недоступен до первой онлайн-верификации.
    expect(await repo.contactHistory('legacy_peer'), null);
    expect(await repo.contactHistory('unknown_peer'), null);
    // Не подтверждённый контакт тоже не отдаёт history.
    await store.saveContact(
        account: 'unconfirmed',
        root: 'cm9vdA==',
        genesis: {'version': 2},
        checkpoint: {'revision': 1},
        genesisDigest: 'cd' * 32,
        confirmed: false,
        history: [
          {'revision': 1}
        ]);
    expect(await repo.contactHistory('unconfirmed'), null);
  }, timeout: const Timeout(Duration(minutes: 3)));
}

String digestOf(Map<String, dynamic> manifest) =>
    sha256Hex(manifestText(manifest));

/// Транспорт-заглушка: только directory/send; networkDown имитирует offline.
class DirectoryTransport extends AlphaTransport {
  Map<String, dynamic>? dir;
  bool networkDown = false;

  DirectoryTransport(CryptoService crypto)
      : super('https://history.fake', crypto);

  @override
  Future<dynamic> operation(String op, Object? body,
      {required String account,
      required String id,
      required String privateKey}) async {
    if (networkDown) throw AlphaTransportException(0, 'offline');
    if (op == 'directory') return dir!;
    if (op == 'send') return {'accepted': true};
    throw UnimplementedError('op $op');
  }
}