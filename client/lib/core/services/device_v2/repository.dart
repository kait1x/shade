/// Репозиторий чата device-v2 для native Android-клиента.
///
/// Соединяет AlphaTransport (реальный alpha-процесс), DeviceV2Crypto и
/// локальное SQLCipher-хранилище: явная legacy-enrollment без замены ключей,
/// сверка genesis digest контакта, подписанный outbox с идемпотентным retry,
/// inbox с replay-дедупликацией и ACK только после атомарного сохранения.
library;

import '../crypto_service.dart';
import 'crypto.dart';
import 'payload.dart';
import 'protocol.dart';
import 'store.dart';
import 'transport.dart';

class V2ChatRepository {
  final AlphaTransport transport;
  final DeviceV2Crypto v2;
  final CryptoService crypto;
  final V2Store store;
  final String account;
  final String root; // SPKI base64 исходного RSA (primary)
  final String privateKey; // PEM, никогда не покидает устройство
  bool _syncing = false;

  V2ChatRepository({
    required this.transport,
    required this.crypto,
    required this.store,
    required this.account,
    required this.root,
    required this.privateKey,
  }) : v2 = DeviceV2Crypto(crypto);

  DeviceV2Session get _session => DeviceV2Session(
      account: account,
      id: 'primary',
      encryptionKey: root,
      signingKey: root,
      encryptionPrivateKey: privateKey,
      signingPrivateKey: privateKey);

  Map<String, dynamic>? _accountCache;

  Map<String, dynamic> _requireAccount() {
    final acc = _accountCache;
    if (acc == null) throw StateError('Аккаунт device-v2 не зарегистрирован');
    return acc;
  }

  Future<void> load() async {
    _accountCache = await store.loadAccount(account);
  }

  bool get enrolled => _accountCache != null;

  /// Снимок локального аккаунта (genesis/history/checkpoint) для UI.
  Map<String, dynamic>? get accountSnapshot => _accountCache;

  /// Явная миграция legacy-аккаунта: исходный RSA подписывает genesis и
  /// остаётся primary-якорем; recovery-ключ независим и шифруется фразой.
  Future<Map<String, dynamic>> enrollLegacy(
      {required String recoveryPassphrase}) async {
    final backup =
        await v2.createRecoveryBackup(account, root, recoveryPassphrase);
    final genesis =
        v2.buildLegacyGenesis(account, root, backup['publicKey'] as String);
    genesis['signature'] =
        await crypto.signData(genesisText(genesis), privateKey);
    final manifest = v2.buildLegacyManifest(account, root);
    manifest['signature'] =
        await crypto.signData(manifestText(manifest), privateKey);
    final result = await transport.legacyEnrollment(genesis, manifest);
    final finalized =
        await v2.finalizeRecoveryBackup(backup, recoveryPassphrase, genesis);
    final checkpoint = {
      'account': account,
      'rootFingerprint': spkiFingerprint(root),
      'revision': result['revision'],
      'digest': result['digest'],
      'genesisDigest': sha256Hex(genesisText(genesis))
    };
    await store.saveAccount(
        account: account,
        root: root,
        genesis: genesis,
        history: [manifest],
        checkpoint: checkpoint,
        sessionId: 'primary',
        recovery: finalized);
    await load();
    return {'revision': result['revision'], 'recovery': finalized};
  }

  /// Продление lease каталога тем же устройством (без смены ключей).
  Future<void> renewLease({bool force = false}) async {
    final acc = _requireAccount();
    final history = acc['history'] as List;
    final last = history.last as Map<String, dynamic>;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (!force && (last['expiresAt'] as int) - now > maxLeaseMs ~/ 2) return;
    final manifest = <String, dynamic>{
      'account': account,
      'rootFingerprint': spkiFingerprint(root),
      'revision': (last['revision'] as int) + 1,
      'previous': sha256Hex(manifestText(last)),
      'issuedAt': now,
      'expiresAt': now + maxLeaseMs,
      'devices': last['devices'],
      'signer': 'primary',
      'signature': ''
    };
    manifest['signature'] =
        await crypto.signData(manifestText(manifest), privateKey);
    final result = await transport.install(manifest,
        account: account, id: 'primary', privateKey: privateKey);
    final checkpoint = {
      ...acc['checkpoint'] as Map<String, dynamic>,
      'revision': result['revision'],
      'digest': result['digest']
    };
    await store.saveAccount(
        account: account,
        root: root,
        genesis: acc['genesis'] as Map<String, dynamic>,
        history: [...history, manifest],
        checkpoint: checkpoint,
        sessionId: 'primary',
        recovery: acc['recovery'] as Map<String, dynamic>?);
    await load();
  }

  /// Сверка genesis digest собеседника (введён пользователем вне relay).
  /// До подтверждения отправка и ACK входящих заблокированы.
  Future<void> confirmContact(String peer, String expectedGenesisDigest) async {
    final dir = await transport.directory(peer,
        account: account, id: 'primary', privateKey: privateKey);
    final peerRoot = dir['root'] as String;
    final genesis = dir['genesis'] as Map<String, dynamic>;
    final digest = await v2.verifier.verifyGenesis(genesis, peerRoot);
    check(digest == expectedGenesisDigest, 'Genesis digest mismatch');
    final verified = await v2.verifier
        .verifyHistory(dir['history'] as List, peerRoot, null, genesis: genesis);
    await store.saveContact(
        account: peer,
        root: peerRoot,
        genesis: genesis,
        checkpoint: {
          'account': peer,
          'rootFingerprint': verified['rootFingerprint'],
          'revision': verified['revision'],
          'digest': verified['digest'],
          'genesisDigest': digest
        },
        genesisDigest: digest,
        confirmed: true);
  }

  Future<Map<String, dynamic>> _peerDirectory(String peer) async {
    final contact = await store.loadContact(peer);
    if (contact == null || contact['confirmed'] != true) {
      throw StateError('Контакт не подтверждён: сверьте genesis digest');
    }
    final dir = await transport.directory(peer,
        account: account, id: 'primary', privateKey: privateKey);
    final verified = await v2.verifier.verifyHistory(dir['history'] as List,
        contact['root'] as String, contact['checkpoint'] as Map<String, dynamic>,
        genesis: contact['genesis'] as Map<String, dynamic>);
    final checkpoint = {
      ...contact['checkpoint'] as Map<String, dynamic>,
      'revision': verified['revision'],
      'digest': verified['digest']
    };
    await store.saveContact(
        account: peer,
        root: contact['root'] as String,
        genesis: contact['genesis'] as Map<String, dynamic>,
        checkpoint: checkpoint,
        genesisDigest: contact['genesisDigest'] as String,
        confirmed: true);
    return {
      'root': contact['root'],
      'genesis': contact['genesis'],
      'history': dir['history'],
      'checkpoint': checkpoint
    };
  }

  /// Отправка: seal → долговечный outbox → подписанный send. Retry повторяет
  /// тот же ciphertext/ID; очередь не перешифровывается молча.
  /// [reply] — {ref, from, text}: Alpha payload-схема {"shade":1,"t","r"},
  /// совместимая с PWA (zcode/pwa-parity). Без reply — plain text.
  Future<String> sendMessage(String peer, String text,
      {Map<String, dynamic>? reply}) async {
    check(text.trim().isNotEmpty, 'Введите сообщение');
    if (reply != null) {
      check((reply['text'] as String?)?.trim().isNotEmpty ?? false,
          'Некорректное сообщение для ответа');
    }
    await renewLease();
    final acc = _requireAccount();
    // Self-chat («Избранное»): свой же каталог, без подтверждения контакта.
    final peerData = peer == account
        ? {
            'root': root,
            'genesis': acc['genesis'],
            'history': acc['history'],
            'checkpoint': acc['checkpoint']
          }
        : await _peerDirectory(peer);
    final message = await v2.sealMessage(
        encodePayload(text, reply),
        acc['history'] as List,
        peerData['history'] as List,
        _session,
        AccountTrust(
            root: root,
            genesis: acc['genesis'] as Map<String, dynamic>,
            checkpoint: acc['checkpoint'] as Map<String, dynamic>),
        AccountTrust(
            root: peerData['root'] as String,
            genesis: peerData['genesis'] as Map<String, dynamic>,
            checkpoint: peerData['checkpoint'] as Map<String, dynamic>));
    await store.putOutbox(message['id'] as String, peer, message);
    await flushOutbox();
    return message['id'] as String;
  }

  Future<void> flushOutbox() async {
    final entries = await store.outboxAll();
    for (final entry in entries) {
      final message = entry['message'] as Map<String, dynamic>;
      try {
        final result = await transport.send(message, privateKey: privateKey);
        if (result['accepted'] == true) {
          final own = (message['envelopes'] as List)
              .cast<Map<String, dynamic>>()
              .firstWhere((e) =>
                  e['account'] == account && e['deviceId'] == _session.id);
          await store.insertSent(
              ref: messageRef(message),
              peer: message['to'] as String,
              messageId: message['id'] as String,
              createdAt: message['createdAt'] as int,
              payload: own['payload'] as Map<String, dynamic>);
          await store.removeOutbox(entry['id'] as String);
        }
      } on AlphaTransportException catch (error) {
        await store.markOutboxAttempt(entry['id'] as String, error.code);
      }
    }
  }

  /// Подписанный fetch: проверка каталогов/подписи, атомарное сохранение
  /// ciphertext и replay ID, затем ACK. Неподтверждённые контакты не ACK-аются.
  Future<int> syncInbox() async {
    if (_syncing) return 0;
    _syncing = true;
    try {
      final acc = _requireAccount();
      final bundles = await transport.fetch(
          account: account, id: 'primary', privateKey: privateKey);
      var count = 0;
      final refs = <String>[];
      for (final b in bundles) {
        final bundle = b as Map<String, dynamic>;
        final m = bundle['message'] as Map<String, dynamic>;
        final ref = messageRef(m);
        if (await store.hasRef(ref)) {
          // Already stored (e.g. self-chat sent copy): still ACK the queue
          // copy so the relay does not redeliver it forever.
          refs.add(ref);
          continue;
        }
        final peer = (m['from'] == account ? m['to'] : m['from']) as String;
        final AccountTrust senderTrust;
        if (peer == account) {
          senderTrust = AccountTrust(
              root: root,
              genesis: acc['genesis'] as Map<String, dynamic>,
              checkpoint: acc['checkpoint'] as Map<String, dynamic>);
        } else {
          final contact = await store.loadContact(peer);
          if (contact == null || contact['confirmed'] != true) continue;
          senderTrust = AccountTrust(
              root: contact['root'] as String,
              genesis: contact['genesis'] as Map<String, dynamic>,
              checkpoint: contact['checkpoint'] as Map<String, dynamic>);
        }
        await v2.openMessage(
            bundle,
            _session,
            senderTrust,
            AccountTrust(
                root: root,
                genesis: acc['genesis'] as Map<String, dynamic>,
                checkpoint: acc['checkpoint'] as Map<String, dynamic>));
        final own = (m['envelopes'] as List)
            .cast<Map<String, dynamic>>()
            .firstWhere((e) =>
                e['account'] == account && e['deviceId'] == _session.id);
        final inserted = await store.insertReceived(
            ref: ref,
            peer: peer,
            messageId: m['id'] as String,
            createdAt: m['createdAt'] as int,
            payload: own['payload'] as Map<String, dynamic>);
        if (inserted) {
          count++;
          refs.add(ref);
        }
      }
      if (refs.isNotEmpty) {
        await transport.ack(refs,
            account: account, id: 'primary', privateKey: privateKey);
        await store.markAcked(refs);
      }
      return count;
    } finally {
      _syncing = false;
    }
  }

  Future<List<Map<String, dynamic>>> refreshDelivery(List<String> refs) async {
    if (refs.isEmpty) return [];
    final status = await transport.status(refs,
        account: account, id: 'primary', privateKey: privateKey);
    for (final ref in refs) {
      final devices = status[ref] as List? ?? [];
      for (final d in devices.cast<Map<String, dynamic>>()) {
        await store.upsertDelivery(
            ref, d['id'] as String, d['acknowledgedAt'] as int?);
      }
    }
    return [
      for (final ref in refs)
        {'ref': ref, 'devices': await store.deliveryFor(ref)}
    ];
  }

  /// История чата: ciphertext хранится в SQLCipher, расшифровка при чтении.
  /// Payload-декодирование совместимо с PWA: plain text и {"shade":1,"t","r"}.
  Future<List<Map<String, dynamic>>> getMessages(String peer) async {
    final rows = await store.messagesByPeer(peer);
    return [
      for (final row in rows)
        {
          ...row,
          ...decodePayload(
              await crypto.decryptData(row['payload'] as String, privateKey))
        }
    ];
  }

  /// «Удалить у себя» (контракт ZCODE): queued-отправка отменяется; входящее
  /// без ACK сначала ACK-ается, чтобы relay не доставил его повторно.
  /// Другие устройства собеседника сохраняют свою копию.
  Future<void> deleteLocal(String ref) async {
    final message = await store.messageByRef(ref);
    check(message != null, 'Сообщение не найдено');
    if (message!['direction'] == 'in' && message['acked'] != true) {
      await transport.ack([ref],
          account: account, id: 'primary', privateKey: privateKey);
    }
    await store.removeOutbox(message['messageId'] as String);
    await store.deleteMessage(ref);
  }

  /// Wake-up hints + периодический опрос чинят потерянные socket-события.
  void attachWake() {
    transport.onWake = () {
      syncInbox().then((_) => flushOutbox()).catchError((Object _) {});
    };
  }
}