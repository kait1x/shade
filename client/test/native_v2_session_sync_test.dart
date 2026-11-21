/// Session-aware sync (D2): вторичное устройство (completePairing) и
/// восстановленное (recoverWithBackup) отправляют/получают/ACK-ают/продлевают
/// lease СВОЕЙ сессией, а не якорем 'primary'; restore() поднимает v2-only
/// сессию без v1-профиля и переживает «перезапуск» на той же БД.
///
/// Scripted transport проверяет auth/proof/verifyMessage/verifyHistory той же
/// криптографией, что и server/alpha.mjs + registry.mjs (неверный ключ сессии
/// отклоняется как на сервере). Хранилище — РЕАЛЬНЫЙ V2Store (SQLCipher ffi).
/// Регрессии: primary/self-chat/offline-очередь без дублей, legacy-мост
/// primary-only. Только синтетические ключи.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fast_rsa/fast_rsa.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shade/core/database/database_service.dart';
import 'package:shade/core/services/crypto_service.dart';
import 'package:shade/core/services/device_v2/crypto.dart';
import 'package:shade/core/services/device_v2/pairing.dart';
import 'package:shade/core/services/device_v2/protocol.dart';
import 'package:shade/core/services/device_v2/repository.dart';
import 'package:shade/core/services/device_v2/store.dart';
import 'package:shade/core/services/device_v2/transport.dart';
import 'package:shade/features/auth/data/repositories/auth_notifier.dart'
    show cryptoServiceProvider, databaseServiceProvider;
import 'package:shade/features/v2/presentation/v2_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _account = 'sess_native';
const _peerAccount = 'sess_peer';
const _phrase = 'synthetic session sync recovery passphrase only';
const _origin = 'https://session.fake';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  // Генерация RSA-4096 дорогая — идентичности мемоизируются на весь файл;
  // каждый тест получает свежую БД и свежий in-memory реестр.
  Future<_Fixture>? fixtureFuture;
  Future<_Fixture> shared() => fixtureFuture ??= _buildFixture();

  test(
      'вторичное устройство: send→fetch→ack→delivered/read своей сессией, '
      'без дублей; restore после перезапуска поднимает ту же сессию',
      () async {
    final f = await shared();
    final reg = _Registry(f.crypto)
      ..seed(f.own)
      ..seed(f.peer);
    final (storeA, dbA, _, closeA) = await openStore('shade-sess-a-');
    final (storeB, dbB, _, closeB) = await openStore('shade-sess-b-');
    final (storeC, dbC, _, closeC) = await openStore('shade-sess-c-');
    final transportA = _SessionTransport(reg, f.crypto);
    final transportB = _SessionTransport(reg, f.crypto);
    final transportC = _SessionTransport(reg, f.crypto);
    addTearDown(() async {
      transportA.dispose();
      transportB.dispose();
      transportC.dispose();
      await closeA();
      await closeB();
      await closeC();
    });
    final trusted = await _seedPrimary(f, f.own, storeA, transportA);
    final peerRepo = await _seedPrimary(f, f.peer, storeC, transportC);
    final newcomer = V2ChatRepository.pairing(
        transport: transportB,
        crypto: f.crypto,
        store: storeB,
        account: _account);
    await newcomer.load();
    final deviceId = await _pairSecondary(f, trusted, newcomer);
    expect(deviceId, isNot('primary'));
    expect(newcomer.pairedSession!.id, deviceId);

    final syncA = V2SyncService(repository: trusted, database: dbA);
    final syncB = V2SyncService(repository: newcomer, database: dbB);
    final syncC = V2SyncService(repository: peerRepo, database: dbC);
    addTearDown(() {
      syncA.dispose();
      syncB.dispose();
      syncC.dispose();
    });

    // Сверка контактов: directory-auth подписывается сессией каждого устройства.
    await syncB.confirmContact(_peerAccount, f.peer.genesisDigest);
    await syncC.confirmContact(_account, f.own.genesisDigest);
    await syncA.confirmContact(_peerAccount, f.peer.genesisDigest);

    // 1) Отправка вторичным: конверт адресован его device id, fanout полон.
    const text = 'привет с вторичного устройства 🔐';
    final id = await syncB.send(_peerAccount, text);
    final sent = reg.lastSent!;
    expect(sent['deviceId'], deviceId);
    expect(messageRef(sent), '$_account:$deviceId:$id');
    expect(
        (sent['envelopes'] as List).map((e) => '${e['account']}:${e['deviceId']}'),
        containsAll([
          '$_account:primary',
          '$_account:$deviceId',
          '$_peerAccount:primary'
        ]));
    expect(reg.queues['$_peerAccount:primary']!.length, 1);

    // 2) Свой fanout-конверт вторичное ACK-ает само (hasRef-ветка syncInbox):
    //    это НЕ доставка собеседнику — статус остаётся sent до ACK peer-а.
    await syncB.syncNow();
    var conv = await syncB.conversation(_peerAccount);
    expect(conv.single.text, text);
    expect(conv.single.status, 'sent');
    expect(await storeB.outboxAll(), isEmpty);

    // 3) Peer получает и ACK-ает → вторичное видит delivered по проекции.
    await syncC.syncNow();
    final peerConv = await syncC.conversation(_account);
    expect(peerConv.single.text, text);
    await syncB.syncNow();
    conv = await syncB.conversation(_peerAccount);
    expect(conv.single.status, 'delivered');

    // 4) Read-ACK peer-а → read у вторичного отправителя.
    await syncC.markRead([messageRef(sent)]);
    await syncB.syncNow();
    conv = await syncB.conversation(_peerAccount);
    expect(conv.single.status, 'read');

    // 5) Обратное направление: peer → вторичное. Расшифровка ключом сессии,
    //    read-ACK фиксируется ДЛЯ вторичного устройства; primary получает
    //    свою копию тем же якорем (регрессия fanout).
    const reply = 'ответ peer-а вторичному';
    await syncC.send(_account, reply);
    await syncB.syncNow();
    conv = await syncB.conversation(_peerAccount);
    expect(conv.length, 2);
    final incoming = conv.firstWhere((m) => !m.mine);
    expect(incoming.text, reply);
    expect(incoming.status, 'received');
    await syncB.markRead([incoming.ref]);
    final readDevices =
        reg.delivery[incoming.ref]!['devices'] as List;
    final secondaryRead = readDevices
        .cast<Map<String, dynamic>>()
        .firstWhere((d) => d['id'] == deviceId);
    expect(secondaryRead['readAt'], isA<int>());
    await syncA.syncNow();
    final primaryConv = await syncA.conversation(_peerAccount);
    expect(primaryConv.any((m) => m.text == reply && !m.mine), true);
    // Копия исходящего, отправленного вторичным, хранится у primary как своё.
    expect(primaryConv.any((m) => m.text == text && m.mine), true);

    // 6) Повторные циклы не плодят дублей и не переотправляют принятое.
    final sentBefore = reg.sendAttempts;
    await syncB.syncNow();
    await syncB.syncNow();
    expect(reg.sendAttempts, sentBefore);
    expect((await syncB.conversation(_peerAccount)).length, 2);
    expect((await storeB.messagesByPeer(_peerAccount)).length, 2);
    expect(await storeB.outboxAll(), isEmpty);

    // 7) Весь auth вторичного стека — его device id, никогда 'primary';
    //    legacy-мост вторичным не вызывается (primary-only контракт сервера).
    expect(transportB.authIds, isNotEmpty);
    expect(transportB.authIds.every((id) => id == deviceId), true);
    expect(
        reg.authLog
            .where((e) => e.$1 == 'legacy.inbox' || e.$1 == 'legacy.ack')
            .every((e) => e.$3 == 'primary'),
        true);
    expect(syncB.lastError, isNull);

    // 8) «Перезапуск»: новый provider/store instance на той же БД. v1-профиля
    //    нет (secure storage пуст) — restore поднимает вторичную сессию из
    //    v2_device_keys и prefs, история сохраняется, отправка работает.
    await persistSessionPrefs(_account, 'shade-alpha=secondary');
    final restoredTransports = <_SessionTransport>[];
    final container = _sessionContainer(f, dbB,
        transportFactory: (origin, crypto) {
      expect(origin, _origin);
      final t = _SessionTransport(reg, crypto);
      restoredTransports.add(t);
      return t;
    });
    addTearDown(container.dispose);
    final state = await waitSession(container);
    expect(state.status, V2SessionStatus.ready);
    expect(state.account, _account);
    final notifier = container.read(v2SessionProvider.notifier);
    expect(notifier.repository!.pairedSession!.id, deviceId);
    expect(notifier.repository!.session.id, deviceId);
    final restoredSync = notifier.sync!;
    final restoredConv = await restoredSync.conversation(_peerAccount);
    expect(restoredConv.length, 2);
    expect(restoredConv.any((m) => m.text == text), true);
    final id2 = await restoredSync.send(_peerAccount, 'после перезапуска');
    await syncC.syncNow();
    expect(
        (await syncC.conversation(_account)).any((m) => m.text == 'после перезапуска'),
        true);
    expect(reg.lastSent!['deviceId'], deviceId);
    expect(reg.lastSent!['id'], id2);
    await restoredSync.syncNow();
    expect(restoredSync.lastError, isNull);
    expect(restoredTransports.single.authIds.every((id) => id == deviceId),
        true);
  }, timeout: const Timeout(Duration(minutes: 6)));

  test(
      'lease-refresh вторичным устройством: signer его же, каталог обновлён; '
      'устройство вне ростера lease не продлевает', () async {
    final f = await shared();
    final reg = _Registry(f.crypto)..seed(f.own);
    final (storeA, dbA, _, closeA) = await openStore('shade-sess-lease-a-');
    final (storeB, dbB, _, closeB) = await openStore('shade-sess-lease-b-');
    final transportA = _SessionTransport(reg, f.crypto);
    final transportB = _SessionTransport(reg, f.crypto);
    addTearDown(() async {
      transportA.dispose();
      transportB.dispose();
      await closeA();
      await closeB();
    });
    final trusted = await _seedPrimary(f, f.own, storeA, transportA);
    final newcomer = V2ChatRepository.pairing(
        transport: transportB,
        crypto: f.crypto,
        store: storeB,
        account: _account);
    await newcomer.load();
    final deviceId = await _pairSecondary(f, trusted, newcomer);
    expect(reg.installs, 1);

    // Продление ТЕКУЩИМ (вторичным) устройством: манифест подписан его ключом,
    // auth install — его id, sessionId и ключи сессии не теряются.
    await newcomer.renewLease(force: true);
    expect(reg.installs, 2);
    final tip = reg.historyOf(_account).last;
    expect(tip['signer'], deviceId);
    expect(tip['revision'], 3);
    expect((tip['devices'] as List).map((d) => d['id']),
        containsAll(['primary', deviceId]));
    final acc = await storeB.loadAccount(_account);
    expect(acc!['sessionId'], deviceId);
    expect((acc['checkpoint'] as Map)['revision'], 3);
    expect((acc['history'] as List).length, 3);
    expect((await storeB.loadDeviceKeys(_account))!['deviceId'], deviceId);
    expect(newcomer.pairedSession!.id, deviceId);
    expect(transportB.authIds.last, deviceId);
    // После продления отправка вторичным по-прежнему работает.
    final syncB = V2SyncService(repository: newcomer, database: dbB);
    addTearDown(syncB.dispose);
    await syncB.send(_account, 'заметка после продления lease');
    expect(reg.lastSent!['deviceId'], deviceId);

    // Устройство вне ростера (отозвано другим устройством/recovery):
    // renewLease не устанавливает манифест и не трогает локальный каталог.
    final (storeD, _, _, closeD) = await openStore('shade-sess-lease-d-');
    final transportD = _SessionTransport(reg, f.crypto);
    addTearDown(() async {
      transportD.dispose();
      await closeD();
    });
    final outsider = await f.pairing.generateDeviceSession(_account);
    await storeD.saveDeviceKeys(
        account: _account,
        deviceId: outsider.id,
        encryptionKey: outsider.encryptionKey,
        signingKey: outsider.signingKey,
        encryptionPrivate: outsider.encryptionPrivateKey,
        signingPrivate: outsider.signingPrivateKey);
    await storeD.saveAccount(
        account: _account,
        root: f.own.root,
        genesis: f.own.genesis,
        history: [f.own.manifest],
        checkpoint: f.own.checkpoint,
        sessionId: outsider.id);
    final revoked = V2ChatRepository.pairing(
        transport: transportD,
        crypto: f.crypto,
        store: storeD,
        account: _account);
    await revoked.load();
    expect(revoked.pairedSession!.id, outsider.id);
    final installsBefore = reg.installs;
    await revoked.renewLease(force: true);
    expect(reg.installs, installsBefore);
    expect((await storeD.loadAccount(_account))!['checkpoint'],
        f.own.checkpoint);
    expect(transportD.authIds, isEmpty);
  }, timeout: const Timeout(Duration(minutes: 6)));

  test(
      'recovery-устройство: send после restore() без v1-профиля; '
      'повторный перезапуск на той же БД поднимает восстановленную сессию',
      () async {
    final f = await shared();
    final reg = _Registry(f.crypto)
      ..seed(f.own)
      ..seed(f.peer);
    final (store, db, path, close) = await openStore('shade-sess-rec-');
    final (storeC, dbC, _, closeC) = await openStore('shade-sess-rec-peer-');
    final transport = _SessionTransport(reg, f.crypto);
    final transportC = _SessionTransport(reg, f.crypto);
    addTearDown(() async {
      transport.dispose();
      transportC.dispose();
      await close();
      await closeC();
    });
    final peerRepo = await _seedPrimary(f, f.peer, storeC, transportC);
    final syncC = V2SyncService(repository: peerRepo, database: dbC);
    addTearDown(syncC.dispose);

    // Recovery-фиксация: новые ключи, ростер заменён, старое устройство retired.
    final repo = V2ChatRepository.pairing(
        transport: transport, crypto: f.crypto, store: store, account: '');
    await repo.load();
    final result = await repo.recoverWithBackup(f.own.package, _phrase);
    final deviceId = result['deviceId'] as String;
    expect(result['revision'], 2);
    expect(reg.retiredOf(_account), contains('primary'));
    expect((reg.historyOf(_account).last['devices'] as List).single['id'],
        deviceId);
    expect((await store.loadAccount(_account))!['sessionId'], deviceId);
    expect((await store.loadDeviceKeys(_account))!['deviceId'], deviceId);

    // Экран recovery фиксирует prefs origin/account/cookie; v1-профиля нет.
    // restore() создаёт транспорт через фабрику — тот же scripted реестр.
    await persistSessionPrefs(_account, 'shade-alpha=recovered');
    final restoredTransports = <_SessionTransport>[];
    AlphaTransport scriptedFactory(String origin, CryptoService crypto) {
      expect(origin, _origin);
      final t = _SessionTransport(reg, crypto);
      restoredTransports.add(t);
      return t;
    }

    final container =
        _sessionContainer(f, db, transportFactory: scriptedFactory);
    final state = await waitSession(container);
    expect(state.status, V2SessionStatus.ready);
    expect(state.account, _account);
    final notifier = container.read(v2SessionProvider.notifier);
    expect(notifier.repository!.pairedSession!.id, deviceId);
    final sync = notifier.sync!;

    // Self-chat восстановленного устройства: запечатка/отправка/ACK своей
    // сессией, legacy-мост не вызывается (устройство не primary).
    final id = await sync.send(_account, 'заметка после recovery');
    await sync.syncNow();
    var conv = await sync.conversation(_account);
    expect(conv.single.text, 'заметка после recovery');
    expect(conv.single.status, 'delivered');
    expect(reg.lastSent!['deviceId'], deviceId);
    expect(reg.lastSent!['id'], id);
    expect(sync.lastError, isNull);
    expect(
        reg.authLog.where((e) => e.$1 == 'legacy.inbox'), isEmpty);

    // Peer-send восстановленного устройства: контакт сверяется и сообщение
    // доставляется peer-у; весь auth — восстановленным device id.
    await sync.confirmContact(_peerAccount, f.peer.genesisDigest);
    await syncC.confirmContact(_account, f.own.genesisDigest);
    final id2 = await sync.send(_peerAccount, 'привет после recovery');
    await syncC.syncNow();
    expect(
        (await syncC.conversation(_account))
            .any((m) => m.text == 'привет после recovery'),
        true);
    expect(reg.lastSent!['id'], id2);
    await sync.syncNow();
    conv = await sync.conversation(_peerAccount);
    expect(conv.single.status, 'delivered');
    expect(transport.authIds.every((id) => id == deviceId), true);
    expect(
        restoredTransports.every(
            (t) => t.authIds.every((id) => id == deviceId)),
        true);
    // Старое устройство больше не авторизуется сервером.
    Object? negativeError;
    try {
      await transport.operation('fetch', null,
          account: _account, id: 'primary', privateKey: f.own.privateKey);
    } catch (error) {
      negativeError = error;
    }
    expect(negativeError, isA<AlphaTransportException>());

    // «Перезапуск» приложения: стек освобождён, БД закрыта и открыта заново,
    // новый provider/store instance — восстановленное устройство поднимается.
    container.dispose();
    await db.close();
    final db2 = await DatabaseService.openForTest(databaseFactoryFfi, path);
    final container2 =
        _sessionContainer(f, db2, transportFactory: scriptedFactory);
    addTearDown(() async {
      container2.dispose();
      await db2.close();
    });
    final state2 = await waitSession(container2);
    expect(state2.status, V2SessionStatus.ready);
    final notifier2 = container2.read(v2SessionProvider.notifier);
    expect(notifier2.repository!.pairedSession!.id, deviceId);
    final sync2 = notifier2.sync!;
    final conv2 = await sync2.conversation(_account);
    expect(conv2.single.text, 'заметка после recovery');
    final id3 = await sync2.send(_account, 'после второго перезапуска');
    expect(reg.lastSent!['id'], id3);
    expect(reg.lastSent!['deviceId'], deviceId);
    await sync2.syncNow();
    expect((await sync2.conversation(_account)).length, 2);
    expect(sync2.lastError, isNull);
  }, timeout: const Timeout(Duration(minutes: 6)));

  test('restore без ключей: честный disconnected/needsEnrollment/error',
      () async {
    final f = await shared();
    final (store, db, _, close) = await openStore('shade-sess-empty-');
    addTearDown(close);

    // Нет prefs — disconnected без ошибки.
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    final c1 = _sessionContainer(f, db);
    addTearDown(c1.dispose);
    final s1 = await waitSession(c1);
    expect(s1.status, V2SessionStatus.disconnected);
    expect(s1.error, isNull);

    // Prefs есть, но нет ни v1-профиля, ни v2-аккаунта — честный disconnected.
    await persistSessionPrefs(_account, 'shade-alpha=none');
    final c2 = _sessionContainer(f, db);
    addTearDown(c2.dispose);
    final s2 = await waitSession(c2);
    expect(s2.status, V2SessionStatus.disconnected);
    expect(s2.error, contains('профиль Shade'));

    // v1-профиль есть, v2-аккаунта нет — прежний путь needsEnrollment.
    SharedPreferences.setMockInitialValues(
        {'alpha_v2_origin': _origin, 'alpha_v2_account': _account});
    FlutterSecureStorage.setMockInitialValues({
      'alpha_v2_cookie': 'shade-alpha=v1',
      'rsa_public_key': f.own.publicPem,
      'rsa_private_key': f.own.privateKey
    });
    final c3 = _sessionContainer(f, db);
    addTearDown(c3.dispose);
    final s3 = await waitSession(c3);
    expect(s3.status, V2SessionStatus.needsEnrollment);
    expect(s3.account, _account);

    // v2-аккаунт вторичного устройства без долговечных ключей — честная
    // ошибка вместо тихой подмены якорем.
    await store.saveAccount(
        account: _account,
        root: f.own.root,
        genesis: f.own.genesis,
        history: [f.own.manifest],
        checkpoint: f.own.checkpoint,
        sessionId: 'ab' * 32);
    await persistSessionPrefs(_account, 'shade-alpha=broken');
    final c4 = _sessionContainer(f, db);
    addTearDown(c4.dispose);
    final s4 = await waitSession(c4);
    expect(s4.status, V2SessionStatus.error);
    expect(s4.error, contains('Ключи устройства v2 не найдены'));
  }, timeout: const Timeout(Duration(minutes: 6)));

  test(
      'регрессия primary: self-chat/offline-очередь без дублей, queued→blocked→sent, '
      'legacy-мост и lease primary, restore с v1-профилем', () async {
    final f = await shared();
    final reg = _Registry(f.crypto)
      ..seed(f.own)
      ..seed(f.peer);
    final (store, db, _, close) = await openStore('shade-sess-primary-');
    final (storeC, dbC, _, closeC) = await openStore('shade-sess-primary-c-');
    final transport = _SessionTransport(reg, f.crypto);
    final transportC = _SessionTransport(reg, f.crypto);
    addTearDown(() async {
      transport.dispose();
      transportC.dispose();
      await close();
      await closeC();
    });
    final repo = await _seedPrimary(f, f.own, store, transport);
    final peerRepo = await _seedPrimary(f, f.peer, storeC, transportC);
    final sync = V2SyncService(repository: repo, database: db);
    final syncC = V2SyncService(repository: peerRepo, database: dbC);
    addTearDown(() {
      sync.dispose();
      syncC.dispose();
    });

    // 1) Offline self-send: конверт долговечно закоммичен, статус queued.
    reg.networkDown = true;
    final id = await sync.send(_account, 'заметка offline');
    expect((await store.outboxAll()).single['id'], id);
    var conv = await sync.conversation(_account);
    expect(conv.single.text, 'заметка offline');
    expect(conv.single.status, 'queued');

    // 2) Сеть появилась: retry ТОГО ЖЕ ciphertext/ID, без дублей.
    final sealedOffline =
        _copyMap((await store.outboxAll()).single['message'] as Map);
    reg.networkDown = false;
    await sync.syncNow();
    expect(reg.lastSent!['id'], id);
    expect(jsonEncode(reg.lastSent), jsonEncode(sealedOffline),
        reason: 'retry обязан повторять тот же запечатанный конверт');
    expect(await store.outboxAll(), isEmpty);
    conv = await sync.conversation(_account);
    expect(conv.length, 1);
    // Self-chat: собственная копия ACK-нута устройством → delivered (web-контракт).
    expect(conv.single.status, 'delivered');
    await sync.syncNow();
    await sync.syncNow();
    expect((await sync.conversation(_account)).length, 1);
    expect((await store.messagesByPeer(_account)).length, 1);

    // 3) Серверный отказ 409: blocked с честной меткой, конверт в очереди;
    //    после смены условий доставляется тем же ID.
    reg.failNextSend = 'peer_upgrade_required';
    final blockedId = await sync.send(_account, 'заблокированное');
    conv = await sync.conversation(_account);
    final blocked = conv.firstWhere((m) => m.text == 'заблокированное');
    expect(blocked.status, 'blocked');
    expect(blocked.statusLabel, contains('v2'));
    expect(await sync.peerUpgradeBlocked(_account), true);
    expect((await store.outboxAll()).single['id'], blockedId);
    await sync.syncNow();
    conv = await sync.conversation(_account);
    expect(conv.length, 2);
    expect(conv.every((m) => m.status == 'delivered'), true);
    expect(reg.lastSent!['id'], blockedId);
    expect(await store.outboxAll(), isEmpty);

    // 4) Offline peer-seal против проверенной history контакта.
    await sync.confirmContact(_peerAccount, f.peer.genesisDigest);
    await syncC.confirmContact(_account, f.own.genesisDigest);
    reg.networkDown = true;
    final peerId = await sync.send(_peerAccount, 'peer offline заметка');
    expect(reg.sendAttempts, 3); // сетевых попыток offline не было
    final outbox = await store.outboxAll();
    expect(outbox.single['id'], peerId);
    conv = await sync.conversation(_peerAccount);
    expect(conv.single.status, 'queued');
    // Собеседник расшифровывает offline-конверт своим ключом.
    final sealed = outbox.single['message'] as Map<String, dynamic>;
    final plain = await f.v2.openMessage(
        {
          'message': sealed,
          'senderHistory': repo.ownHistory,
          'recipientHistory': [f.peer.manifest]
        },
        DeviceV2Session(
            account: _peerAccount,
            id: 'primary',
            encryptionKey: f.peer.root,
            signingKey: f.peer.root,
            encryptionPrivateKey: f.peer.privateKey,
            signingPrivateKey: f.peer.privateKey),
        AccountTrust(root: f.own.root, genesis: f.own.genesis),
        AccountTrust(root: f.peer.root, genesis: f.peer.genesis));
    expect(plain, 'peer offline заметка');
    reg.networkDown = false;
    await sync.syncNow();
    expect(await store.outboxAll(), isEmpty);
    await syncC.syncNow();
    expect(
        (await syncC.conversation(_account))
            .any((m) => m.text == 'peer offline заметка'),
        true);
    await sync.syncNow();
    conv = await sync.conversation(_peerAccount);
    expect(conv.single.status, 'delivered');
    expect((await store.messagesByPeer(_peerAccount)).length, 1);

    // 5) Legacy-мост primary работает (auth 'primary'), lease продлевается
    //    primary-якорем; sessionId остаётся 'primary'.
    expect(
        reg.authLog
            .where((e) => e.$1 == 'legacy.inbox' && e.$2 == _account)
            .every((e) => e.$3 == 'primary'),
        true);
    expect(
        reg.authLog.where((e) => e.$1 == 'legacy.inbox' && e.$2 == _account),
        isNotEmpty);
    await repo.renewLease(force: true);
    expect(reg.historyOf(_account).last['signer'], 'primary');
    expect((await store.loadAccount(_account))!['sessionId'], 'primary');
    await sync.send(_account, 'после продления lease');
    expect(reg.lastSent!['deviceId'], 'primary');

    // 6) Restore primary с v1-профилем (прежнее поведение не сломано).
    SharedPreferences.setMockInitialValues(
        {'alpha_v2_origin': _origin, 'alpha_v2_account': _account});
    FlutterSecureStorage.setMockInitialValues({
      'alpha_v2_cookie': 'shade-alpha=primary',
      'rsa_public_key': f.own.publicPem,
      'rsa_private_key': f.own.privateKey
    });
    final container = _sessionContainer(f, db,
        transportFactory: (origin, crypto) => _SessionTransport(reg, crypto));
    addTearDown(container.dispose);
    final state = await waitSession(container);
    expect(state.status, V2SessionStatus.ready);
    final notifier = container.read(v2SessionProvider.notifier);
    expect(notifier.repository!.pairedSession, isNull);
    expect(notifier.repository!.session.id, 'primary');
    final restoredConv = await notifier.sync!.conversation(_account);
    expect(restoredConv.length, 3);
    await notifier.sync!.send(_account, 'после restore primary');
    await notifier.sync!.syncNow();
    expect(notifier.sync!.lastError, isNull);
    expect(reg.lastSent!['deviceId'], 'primary');
    expect((await notifier.sync!.conversation(_account)).length, 4);
  }, timeout: const Timeout(Duration(minutes: 6)));
}

// ── Фикстуры ────────────────────────────────────────────────────────────────

/// Легитимная legacy-идентичность: genesis/manifest подписаны исходным RSA,
/// recovery-ключ независим, пакет финализирован (привязан к точному genesis).
class _Identity {
  final String account;
  final String root;
  final String publicPem;
  final String privateKey;
  final Map<String, dynamic> genesis;
  final Map<String, dynamic> manifest;
  final Map<String, dynamic> backup;
  final Map<String, dynamic> checkpoint;

  const _Identity({
    required this.account,
    required this.root,
    required this.publicPem,
    required this.privateKey,
    required this.genesis,
    required this.manifest,
    required this.backup,
    required this.checkpoint,
  });

  Map<String, dynamic> get package => {'backup': backup, 'genesis': genesis};
  String get genesisDigest => sha256Hex(genesisText(genesis));
}

class _Fixture {
  final CryptoService crypto;
  final DeviceV2Crypto v2;
  final DeviceV2Pairing pairing;
  final _Identity own;
  final _Identity peer;
  const _Fixture(this.crypto, this.v2, this.pairing, this.own, this.peer);
}

Future<_Fixture> _buildFixture() async {
  FlutterSecureStorage.setMockInitialValues({});
  final crypto = CryptoService();
  final v2 = DeviceV2Crypto(crypto);
  final pairing = DeviceV2Pairing(crypto);
  final ownKp = await RSA.generate(4096);
  final peerKp = await RSA.generate(4096);
  final own = await _buildIdentity(crypto, v2, _account, ownKp);
  final peer = await _buildIdentity(crypto, v2, _peerAccount, peerKp);
  return _Fixture(crypto, v2, pairing, own, peer);
}

Future<_Identity> _buildIdentity(CryptoService crypto, DeviceV2Crypto v2,
    String account, KeyPair kp) async {
  final root = await publicSpki(kp.publicKey);
  // Recovery-ключ генерируется внутри пакета: genesis обязан ссылаться на
  // ТОТ ЖЕ publicKey, иначе finalize/unlock отклонят пакет.
  final backup = await v2.createRecoveryBackup(account, root, _phrase);
  final genesis =
      v2.buildLegacyGenesis(account, root, backup['publicKey'] as String);
  genesis['signature'] =
      await crypto.signData(genesisText(genesis), kp.privateKey);
  final finalized =
      await v2.finalizeRecoveryBackup(backup, _phrase, genesis);
  final manifest = v2.buildLegacyManifest(account, root);
  manifest['signature'] =
      await crypto.signData(manifestText(manifest), kp.privateKey);
  return _Identity(
      account: account,
      root: root,
      publicPem: kp.publicKey,
      privateKey: kp.privateKey,
      genesis: genesis,
      manifest: manifest,
      backup: finalized,
      checkpoint: {
        'account': account,
        'rootFingerprint': spkiFingerprint(root),
        'revision': 1,
        'digest': sha256Hex(manifestText(manifest)),
        'genesisDigest': sha256Hex(genesisText(genesis))
      });
}

/// Свежая SQLCipher-БД (ffi factory) во временной папке + очистка.
Future<(V2Store, DatabaseService, String, Future<void> Function())> openStore(
    String prefix) async {
  final folder = await Directory.systemTemp.createTemp(prefix);
  final path = '${folder.path}/db';
  final db = await DatabaseService.openForTest(databaseFactoryFfi, path);
  return (
    V2Store(db),
    db,
    path,
    () async {
      await db.close();
      await folder.delete(recursive: true);
    }
  );
}

/// Доверенное primary-устройство: legacy-аккаунт в реестре и в store.
Future<V2ChatRepository> _seedPrimary(_Fixture f, _Identity id, V2Store store,
    AlphaTransport transport) async {
  await store.saveAccount(
      account: id.account,
      root: id.root,
      genesis: id.genesis,
      history: [id.manifest],
      checkpoint: id.checkpoint,
      sessionId: 'primary');
  final repo = V2ChatRepository(
      transport: transport,
      crypto: f.crypto,
      store: store,
      account: id.account,
      root: id.root,
      privateKey: id.privateKey);
  await repo.load();
  return repo;
}

/// Полный pairing-цикл: challenge → offer → approve → complete.
Future<String> _pairSecondary(_Fixture f, V2ChatRepository trusted,
    V2ChatRepository newcomer) async {
  final challenge = trusted.pairingChallenge();
  final started = await newcomer.startPairing(
      challengeCode: challenge['code'] as String);
  final confirmText =
      await trusted.approvePairing(started['offerText'] as String);
  final completed = await newcomer.completePairing(confirmText);
  return completed['deviceId'] as String;
}

/// Долговечная связка сессии, как её фиксируют экраны recovery/pairing.
/// Secure storage без v1-ключей — условие v2-only устройства.
Future<void> persistSessionPrefs(String account, String cookie) async {
  SharedPreferences.setMockInitialValues(
      {'alpha_v2_origin': _origin, 'alpha_v2_account': account});
  FlutterSecureStorage.setMockInitialValues({'alpha_v2_cookie': cookie});
}

/// Контейнер сессии: restore() создаёт транспорт через фабрику — тесты
/// подменяют её scripted-транспортом на том же in-memory реестре.
ProviderContainer _sessionContainer(_Fixture f, DatabaseService db,
        {AlphaTransport Function(String origin, CryptoService crypto)?
            transportFactory}) =>
    ProviderContainer(overrides: [
      cryptoServiceProvider.overrideWithValue(f.crypto),
      databaseServiceProvider.overrideWithValue(db),
      if (transportFactory != null)
        v2TransportFactoryProvider.overrideWithValue(transportFactory)
    ]);

/// Ожидание завершения restore(): первый не-loading статус сессии.
Future<V2SessionState> waitSession(ProviderContainer container) async {
  final completer = Completer<V2SessionState>();
  final sub = container.listen<V2SessionState>(v2SessionProvider,
      (previous, next) {
    if (next.status != V2SessionStatus.loading && !completer.isCompleted) {
      completer.complete(next);
    }
  }, fireImmediately: true);
  try {
    return await completer.future.timeout(const Duration(seconds: 60));
  } finally {
    sub.close();
  }
}

// ── Scripted реестр alpha-процесса ──────────────────────────────────────────

Map<String, dynamic> _copyMap(Map value) =>
    jsonDecode(jsonEncode(value)) as Map<String, dynamic>;
List<dynamic> _copyList(List value) =>
    jsonDecode(jsonEncode(value)) as List<dynamic>;

/// In-memory реестр: каталоги, очереди устройств, delivery-проекция, receipts.
/// Auth проверяется криптографически (proof ключом устройства из ростера),
/// send — verifyMessage, install — verifyHistory + possession proofs,
/// legacy-мост разрешён только primary (контракт server/alpha.mjs).
class _Registry {
  final CryptoService crypto;
  final DeviceV2Verifier verifier;
  final Map<String, Map<String, dynamic>> accounts = {};
  final Map<String, List<Map<String, dynamic>>> queues = {};
  final Map<String, Map<String, dynamic>> delivery = {};
  final Map<String, Map<String, dynamic>> tombstones = {};
  final Set<String> receipts = {};
  // Отзыв устройства — в рамках ЕГО аккаунта (tombstones цепочки), не глобально.
  final Map<String, Set<String>> retired = {};
  final List<(String, String, String)> authLog = [];
  final Map<String, (String, int)> recoveryChallenges = {};
  String? recoveryAccount;
  int installs = 0;
  int sendAttempts = 0;
  int legacyInboxCalls = 0;
  String? failNextSend;
  bool networkDown = false;
  Map<String, dynamic>? lastSent;

  _Registry(this.crypto) : verifier = DeviceV2Verifier(crypto);

  void seed(_Identity id) {
    accounts[id.account] = {
      'genesis': _copyMap(id.genesis),
      'history': [_copyMap(id.manifest)]
    };
  }

  List<Map<String, dynamic>> historyOf(String account) =>
      (accounts[account]!['history'] as List).cast<Map<String, dynamic>>();

  Set<String> retiredOf(String account) => retired[account] ?? const {};

  Map<String, dynamic> tipOf(String account) => historyOf(account).last;

  String rootOf(String account) =>
      (accounts[account]!['genesis'] as Map)['firstDevice']['signingKey']
          as String;

  Map<String, dynamic> directory(String account) => {
        'root': rootOf(account),
        'genesis': accounts[account]!['genesis'],
        'history': accounts[account]!['history']
      };

  Never _reject(int status, String code) =>
      throw AlphaTransportException(status, code);

  /// Серверная авторизация: устройство в ростере, proof подписан ЕГО ключом.
  Future<void> authenticate(String account, String id, String nonce,
      String proof, String operation) async {
    final acc = accounts[account];
    if (acc == null) _reject(400, 'operation_rejected');
    final tip = tipOf(account);
    final device = (tip['devices'] as List)
        .cast<Map<String, dynamic>>()
        .where((d) => d['id'] == id)
        .firstOrNull;
    if (device == null || retiredOf(account).contains(id)) {
      _reject(400, 'operation_rejected'); // Revoked or unknown device
    }
    if (!await verifier.verify(requestText(account, id, nonce, operation),
        proof, device['signingKey'] as String)) {
      _reject(400, 'operation_rejected'); // Invalid device proof
    }
  }

  Future<Map<String, dynamic>> install(
      String account, Map<String, dynamic> payload) async {
    final manifest = _copyMap(payload['manifest'] as Map);
    final proofs = (payload['proofs'] as List?) ?? [];
    final acc = accounts[account];
    if (acc == null || manifest['account'] != account) {
      _reject(400, 'operation_rejected');
    }
    final history = historyOf(account);
    final tip = history.last;
    final signer = manifest['signer'] as String;
    if (signer == 'recovery' &&
        !(manifest['devices'] as List).every((d) =>
            !(tip['devices'] as List).any((o) => o['id'] == d['id']))) {
      _reject(400, 'operation_rejected'); // Recovery must replace the roster
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    try {
      check(manifest['revision'] == (tip['revision'] as int) + 1,
          'Stale revision');
      check(manifest['previous'] == sha256Hex(manifestText(tip)),
          'Stale previous');
      await verifier.verifyHistory([...history, manifest], rootOf(account),
          null,
          now: manifest['issuedAt'] as int,
          genesis: acc['genesis'] as Map<String, dynamic>);
      for (final raw in proofs) {
        final proof = raw as Map<String, dynamic>;
        final device = (manifest['devices'] as List)
            .cast<Map<String, dynamic>>()
            .firstWhere((d) => d['id'] == proof['id']);
        check((proof['expiresAt'] as int) > now, 'Stale proof');
        final text = proof['pairingVersion'] == 2
            ? pairingTextV2(
                account,
                device,
                proof['nonce'] as String,
                proof['expiresAt'] as int,
                proof['challenge'] as String)
            : pairingText(account, device, proof['nonce'] as String,
                proof['expiresAt'] as int);
        check(
            await verifier.verify(text, proof['signature'] as String,
                device['signingKey'] as String),
            'Invalid pairing proof');
      }
    } on ProtocolException {
      _reject(400, 'operation_rejected');
    }
    if (signer == 'recovery') {
      final accountRetired = retired.putIfAbsent(account, () => {});
      for (final d in tip['devices']) {
        accountRetired.add(d['id'] as String);
      }
    }
    history.add(manifest);
    installs++;
    return {
      'revision': manifest['revision'],
      'digest': sha256Hex(manifestText(manifest))
    };
  }

  Future<Map<String, dynamic>> send(
      String account, String id, Map<String, dynamic> message) async {
    if (account != message['from'] || id != message['deviceId']) {
      _reject(400, 'operation_rejected'); // Wrong sending device
    }
    if (failNextSend != null) {
      final code = failNextSend!;
      failNextSend = null;
      _reject(409, code);
    }
    final sender = accounts[message['from']];
    final recipient = accounts[message['to']];
    if (sender == null || recipient == null) {
      _reject(409, 'peer_upgrade_required');
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    try {
      check(tipOf(message['from'] as String)['expiresAt'] as int > now,
          'Expired directory lease');
      check(tipOf(message['to'] as String)['expiresAt'] as int > now,
          'Expired directory lease');
      await verifier.verifyMessage(
          message, tipOf(message['from'] as String),
          tipOf(message['to'] as String),
          now: now);
    } on ProtocolException {
      _reject(400, 'operation_rejected');
    }
    final ref = messageRef(message);
    if (receipts.contains(ref)) {
      return {'accepted': true, 'duplicate': true};
    }
    for (final e in (message['envelopes'] as List)
        .cast<Map<String, dynamic>>()) {
      final key = '${e['account']}:${e['deviceId']}';
      final queue = queues[key] ??= [];
      if (!queue.any((q) => q['id'] == message['id'])) {
        queue.add(_copyMap(message));
      }
    }
    receipts.add(ref);
    delivery[ref] = {
      'from': message['from'],
      'devices': [
        for (final e in (message['envelopes'] as List)
            .cast<Map<String, dynamic>>()
            .where((e) => e['account'] == message['to']))
          {
            'account': e['account'],
            'id': e['deviceId'],
            'acknowledgedAt': null,
            'readAt': null
          }
      ]
    };
    lastSent = _copyMap(message);
    return {'accepted': true, 'duplicate': false};
  }
}

/// Scripted transport: повторяет контракт AlphaTransport.operation (challenge
/// → proof переданным ключом → серверная проверка) и dispatch операций.
/// Неверный ключ сессии отклоняется proof-проверкой как на реальном сервере.
class _SessionTransport extends AlphaTransport {
  final _Registry reg;
  final List<String> authIds = [];

  _SessionTransport(this.reg, CryptoService crypto)
      : super(_origin, crypto);

  @override
  Future<dynamic> operation(String op, Object? body,
      {required String account,
      required String id,
      required String privateKey}) async {
    if (reg.networkDown) throw const SocketException('нет сети');
    final operation = operationDigest(
        op,
        op == 'send'
            ? sha256Hex(messageText(body as Map<String, dynamic>))
            : body);
    final nonce = randomHex(32);
    final proof = await crypto.signData(
        requestText(account, id, nonce, operation), privateKey);
    await reg.authenticate(account, id, nonce, proof, operation);
    authIds.add(id);
    reg.authLog.add((op, account, id));
    final now = DateTime.now().millisecondsSinceEpoch;
    switch (op) {
      case 'directory':
        final target = body as String;
        if (!reg.accounts.containsKey(target)) {
          throw AlphaTransportException(400, 'operation_rejected');
        }
        return _copyMap(reg.directory(target));
      case 'install':
        return await reg.install(
            account, Map<String, dynamic>.from(body as Map));
      case 'send':
        reg.sendAttempts++;
        return await reg.send(
            account, id, Map<String, dynamic>.from(body as Map));
      case 'fetch':
        final tip = reg.tipOf(account);
        if ((tip['expiresAt'] as int) <= now) {
          throw AlphaTransportException(400, 'operation_rejected');
        }
        final queue = reg.queues['$account:$id'] ?? [];
        return [
          for (final m in queue)
            {
              'message': _copyMap(m),
              'senderHistory':
                  _copyList(reg.accounts[m['from']]!['history'] as List),
              'recipientHistory':
                  _copyList(reg.accounts[m['to']]!['history'] as List)
            }
        ];
      case 'ack':
        final refs = (body as List).cast<String>();
        final key = '$account:$id';
        final queue = reg.queues[key] ?? [];
        final kept = <Map<String, dynamic>>[];
        var acked = 0;
        for (final m in queue) {
          final ref = messageRef(m);
          if (refs.contains(ref)) {
            acked++;
            final devices =
                (reg.delivery[ref]?['devices'] as List?) ?? [];
            for (final d in devices.cast<Map<String, dynamic>>()) {
              if (d['account'] == account && d['id'] == id) {
                d['acknowledgedAt'] ??= now;
              }
            }
          } else {
            kept.add(m);
          }
        }
        reg.queues[key] = kept;
        return {'acknowledged': acked};
      case 'read':
        final refs = (body as List).cast<String>();
        var read = 0;
        for (final ref in refs) {
          final devices =
              (reg.delivery[ref]?['devices'] as List?) ?? [];
          for (final d in devices.cast<Map<String, dynamic>>()) {
            if (d['account'] == account && d['id'] == id && d['readAt'] == null) {
              d['readAt'] = now;
              read++;
            }
          }
        }
        return {'read': read};
      case 'status':
        final refs = (body as List).cast<String>();
        return {
          for (final ref in refs)
            ref: reg.delivery[ref]?['from'] == account
                ? _copyList(reg.delivery[ref]!['devices'] as List)
                : []
        };
      case 'retract':
        final refs = (body as List).cast<String>();
        if (!refs.every((r) => r.split(':')[0] == account)) {
          throw AlphaTransportException(400, 'operation_rejected');
        }
        var retracted = 0;
        for (final ref in refs) {
          if (!reg.receipts.contains(ref) ||
              reg.tombstones.containsKey(ref)) {
            continue;
          }
          reg.tombstones[ref] = {
            'ref': ref,
            'from': account,
            'deletedAt': now
          };
          retracted++;
        }
        return {'retracted': retracted};
      case 'retractions':
        final since = (body as Map)['since'] as int? ?? 0;
        return {
          'retractions': [
            for (final t in reg.tombstones.values)
              if ((t['deletedAt'] as int) > since) _copyMap(t)
          ]
        };
      case 'legacy.inbox':
        // Контракт сервера: мост v1 разрешён ТОЛЬКО primary-устройству.
        if (id != 'primary') {
          throw AlphaTransportException(400, 'operation_rejected');
        }
        reg.legacyInboxCalls++;
        return [];
      case 'legacy.ack':
        if (id != 'primary') {
          throw AlphaTransportException(400, 'operation_rejected');
        }
        return {};
      default:
        throw UnimplementedError('op $op');
    }
  }

  @override
  Future<Map<String, dynamic>> deviceSession(
      String account, String id, String privateKey) async {
    if (reg.networkDown) throw const SocketException('нет сети');
    final operation = operationDigest('device-session', null);
    final nonce = randomHex(32);
    final proof = await crypto.signData(
        requestText(account, id, nonce, operation), privateKey);
    await reg.authenticate(account, id, nonce, proof, operation);
    authIds.add(id);
    reg.authLog.add(('device-session', account, id));
    reg.recoveryAccount = null;
    return {
      'authenticated': true,
      'account': account,
      'directory': _copyMap(reg.directory(account))
    };
  }

  @override
  Future<String> recoveryChallenge(String account) async {
    if (reg.networkDown) throw const SocketException('нет сети');
    if (!reg.accounts.containsKey(account)) {
      throw AlphaTransportException(400, 'operation_rejected');
    }
    final nonce = randomHex(32);
    reg.recoveryChallenges[nonce] = (
      account,
      DateTime.now().millisecondsSinceEpoch + 60000
    );
    return nonce;
  }

  @override
  Future<Map<String, dynamic>> recoverySession(String account,
      Map<String, dynamic> genesis, String nonce, String proof) async {
    if (reg.networkDown) throw const SocketException('нет сети');
    final now = DateTime.now().millisecondsSinceEpoch;
    final challenge = reg.recoveryChallenges.remove(nonce);
    if (challenge == null ||
        challenge.$1 != account ||
        challenge.$2 <= now) {
      throw AlphaTransportException(400, 'operation_rejected');
    }
    final stored = reg.accounts[account];
    if (stored == null) {
      throw AlphaTransportException(400, 'operation_rejected');
    }
    final storedGenesis = stored['genesis'] as Map<String, dynamic>;
    if (sha256Hex(genesisText(genesis)) !=
            sha256Hex(genesisText(storedGenesis)) ||
        genesis['recoveryKey'] != storedGenesis['recoveryKey']) {
      throw AlphaTransportException(400, 'operation_rejected');
    }
    final operation = operationDigest(
        'recovery-session', sha256Hex(genesisText(genesis)));
    if (!await reg.verifier.verify(
        requestText(account, 'primary', nonce, operation),
        proof,
        storedGenesis['recoveryKey'] as String)) {
      throw AlphaTransportException(400, 'operation_rejected');
    }
    reg.recoveryAccount = account;
    return {
      'authenticated': true,
      'account': account,
      'kind': 'recovery',
      'directory': _copyMap(reg.directory(account))
    };
  }

  @override
  Future<dynamic> recoveryOperation(String op, Object? body,
      {required String account}) async {
    if (reg.networkDown) throw const SocketException('нет сети');
    if (reg.recoveryAccount != account) {
      throw AlphaTransportException(401, 'login_required');
    }
    if (op == 'directory') {
      if (body != account) {
        throw AlphaTransportException(400, 'operation_rejected');
      }
      return _copyMap(reg.directory(account));
    }
    if (op == 'install') {
      final payload = Map<String, dynamic>.from(body as Map);
      if ((payload['manifest'] as Map)['signer'] != 'recovery') {
        throw AlphaTransportException(400, 'operation_rejected');
      }
      return await reg.install(account, payload);
    }
    throw AlphaTransportException(400, 'operation_rejected');
  }

  @override
  Future<void> connectSocket(
      {required String account,
      required String id,
      required String privateKey}) async {}
}