/// Репозиторий чата device-v2 для native Android-клиента.
///
/// Соединяет AlphaTransport (реальный alpha-процесс), DeviceV2Crypto и
/// локальное SQLCipher-хранилище: явная legacy-enrollment без замены ключей,
/// сверка genesis digest контакта, подписанный outbox с идемпотентным retry,
/// inbox с replay-дедупликацией и ACK только после атомарного сохранения.
library;

import 'dart:convert';
import 'dart:typed_data';

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
  String root; // SPKI base64 якоря (primary); после rotation — новый RSA-4096
  String privateKey; // PEM, никогда не покидает устройство
  /// Исходный v1-ключ после rotation: расшифровка старой истории и bridged
  /// v1-ciphertext. Не заменяет якорь и не используется для новых сообщений.
  String? legacyPrivateKey;
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
    final acc = _accountCache;
    if (acc != null) {
      root = acc['root'] as String;
      final anchor = acc['anchorKey'] as String?;
      if (anchor != null && anchor.isNotEmpty) privateKey = anchor;
      legacyPrivateKey = acc['legacyKey'] as String?;
    }
  }

  bool get enrolled => _accountCache != null;

  /// Снимок локального аккаунта (genesis/history/checkpoint) для UI.
  Map<String, dynamic>? get accountSnapshot => _accountCache;

  /// Явная миграция legacy-аккаунта: исходный RSA подписывает genesis и
  /// остаётся primary-якорем; recovery-ключ независим и шифруется фразой.
  ///
  /// Crash-safe: genesis/manifest и зашифрованный recovery-пакет пишутся в
  /// долговечный журнал ДО сетевого вызова. Повтор после любого сбоя:
  ///  - тот же genesis уже на сервере → сервер возвращает committed tip
  ///    (resumed), локальное состояние достраивается из журнала;
  ///  - ответ потерялся → каталог сверяется через /api/session и перенимается
  ///    без создания второго genesis и без потери recovery-ключа.
  /// Старое локальное хранилище (SQLCipher v1, ключи, история) не удаляется.
  Future<Map<String, dynamic>> enrollLegacy(
      {required String recoveryPassphrase}) async {
    // Идемпотентность: уже enrolled локально — ничего не пересоздаём и не
    // трогаем сохранённый recovery-пакет.
    final existing = await store.loadAccount(account);
    if (existing != null) {
      return {
        'revision': (existing['checkpoint'] as Map)['revision'],
        'recovery': existing['recovery'],
        'alreadyEnrolled': true
      };
    }
    final journal = await store.loadEnrollmentJournal(account);
    Map<String, dynamic> genesis, manifest, backup;
    if (journal != null && journal['root'] == root) {
      genesis = Map<String, dynamic>.from(journal['genesis'] as Map);
      manifest = Map<String, dynamic>.from(journal['manifest'] as Map);
      backup = Map<String, dynamic>.from(journal['recoveryBackup'] as Map);
    } else {
      backup =
          await v2.createRecoveryBackup(account, root, recoveryPassphrase);
      genesis =
          v2.buildLegacyGenesis(account, root, backup['publicKey'] as String);
      genesis['signature'] =
          await crypto.signData(genesisText(genesis), privateKey);
      manifest = v2.buildLegacyManifest(account, root);
      manifest['signature'] =
          await crypto.signData(manifestText(manifest), privateKey);
      await store.saveEnrollmentJournal(
          account: account,
          root: root,
          genesis: genesis,
          manifest: manifest,
          recoveryBackup: backup);
    }
    Map<String, dynamic> result;
    try {
      result = await transport.legacyEnrollment(genesis, manifest);
    } on AlphaTransportException {
      // Сервер мог уже зафиксировать genesis (сбой клиента после коммита) —
      // перенимаем проверенный каталог, а не создаём новый genesis.
      final session = await transport.session();
      final dir = session['directory'];
      if (session['account'] != account ||
          dir is! Map ||
          (dir['history'] as List?)?.isEmpty != false) {
        rethrow;
      }
      return _adoptDirectory(Map<String, dynamic>.from(dir),
          genesis, backup, recoveryPassphrase);
    }
    if (result['resumed'] == true) {
      final session = await transport.session();
      final dir = session['directory'];
      if (session['account'] == account && dir is Map) {
        return _adoptDirectory(Map<String, dynamic>.from(dir),
            genesis, backup, recoveryPassphrase);
      }
    }
    final finalized = await _finalizeBackup(backup, recoveryPassphrase, genesis);
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
    await store.deleteEnrollmentJournal(account);
    await load();
    return {'revision': result['revision'], 'recovery': finalized};
  }

  /// Rotation RSA-2048 → RSA-4096: ОСОЗНАННАЯ смена криптографической
  /// идентичности с доказательством владения старым ключом. Старый RSA
  /// подписывает аттестацию, связывающую account, old fingerprint, новый
  /// SPKI и точные digest genesis/manifest; новый RSA-4096 становится
  /// primary-якорем v2. Старый приватный ключ остаётся на устройстве для
  /// расшифровки локальной истории и bridged v1-ciphertext.
  ///
  /// Crash-safe: новый якорь, genesis/manifest и recovery-пакет пишутся в
  /// долговечный журнал ДО сети; повтор после сбоя перенимает серверный
  /// каталог через сессию НОВЫМ ключом, не создавая второй genesis.
  Future<Map<String, dynamic>> enrollWithRotation(
      {required String recoveryPassphrase}) async {
    final existing = await store.loadAccount(account);
    if (existing != null) {
      return {
        'revision': (existing['checkpoint'] as Map)['revision'],
        'recovery': existing['recovery'],
        'alreadyEnrolled': true
      };
    }
    final journal = await store.loadEnrollmentJournal(account);
    if (journal != null && journal['rotation'] == null) {
      throw StateError(
          'Существует журнал обычного перехода v1→v2. Завершите его тем же '
          'ключом; rotation не перезаписывает чужой журнал.');
    }
    Map<String, dynamic> genesis, manifest, backup;
    String anchorPrivate, newRoot;
    if (journal != null && journal['anchorKey'] != null) {
      genesis = Map<String, dynamic>.from(journal['genesis'] as Map);
      manifest = Map<String, dynamic>.from(journal['manifest'] as Map);
      backup = Map<String, dynamic>.from(journal['recoveryBackup'] as Map);
      anchorPrivate = journal['anchorKey'] as String;
      newRoot = journal['root'] as String;
    } else {
      final anchor = await v2.generateAnchorKey();
      anchorPrivate = anchor['privateKey']!;
      newRoot = anchor['publicKey']!;
      backup =
          await v2.createRecoveryBackup(account, newRoot, recoveryPassphrase);
      genesis =
          v2.buildLegacyGenesis(account, newRoot, backup['publicKey'] as String);
      genesis['signature'] =
          await crypto.signData(genesisText(genesis), anchorPrivate);
      manifest = v2.buildLegacyManifest(account, newRoot);
      manifest['signature'] =
          await crypto.signData(manifestText(manifest), anchorPrivate);
      await store.saveEnrollmentJournal(
          account: account,
          root: newRoot,
          genesis: genesis,
          manifest: manifest,
          recoveryBackup: backup,
          anchorKey: anchorPrivate,
          rotation: {'oldRoot': root, 'pending': true});
    }
    // Свежий одноразовый nonce; аттестация подписывается СТАРЫМ ключом.
    final challenge = await transport.rotationChallenge(account);
    final nonce = challenge['nonce'] as String;
    final oldFingerprint = challenge['oldRootFingerprint'] as String;
    if (oldFingerprint != spkiFingerprint(root)) {
      throw StateError(
          'Серверный отпечаток старого ключа не совпадает с локальным; '
          'переход остановлен, ключи не изменены.');
    }
    final attestation = <String, dynamic>{
      'version': 1,
      'account': account,
      'oldRootFingerprint': oldFingerprint,
      'newRoot': newRoot,
      'genesisDigest': sha256Hex(genesisText(genesis)),
      'manifestDigest': sha256Hex(manifestText(manifest)),
      'createdAt': DateTime.now().millisecondsSinceEpoch,
      'nonce': nonce,
      // Placeholder валидной формы: канонический текст не включает подпись.
      'signature': 'AA=='
    };
    attestation['signature'] =
        await crypto.signData(rotationText(attestation), privateKey);
    await store.saveEnrollmentJournal(
        account: account,
        root: newRoot,
        genesis: genesis,
        manifest: manifest,
        recoveryBackup: backup,
        anchorKey: anchorPrivate,
        rotation: {
          'oldRoot': root,
          'oldRootFingerprint': oldFingerprint,
          'attestation': attestation
        });
    Map<String, dynamic> result;
    try {
      result = await transport.legacyRotation(
          account, nonce, attestation, genesis, manifest);
    } on AlphaTransportException {
      // Сервер мог уже зафиксировать genesis — перенимаем проверенный каталог
      // через сессию НОВЫМ ключом, а не создаём второй genesis.
      return _adoptRotated(genesis, backup, recoveryPassphrase,
          newRoot, anchorPrivate);
    }
    if (result['resumed'] == true) {
      return _adoptRotated(genesis, backup, recoveryPassphrase,
          newRoot, anchorPrivate);
    }
    final finalized = await _finalizeBackup(backup, recoveryPassphrase, genesis);
    final checkpoint = {
      'account': account,
      'rootFingerprint': spkiFingerprint(newRoot),
      'revision': result['revision'],
      'digest': result['digest'],
      'genesisDigest': sha256Hex(genesisText(genesis))
    };
    await store.saveAccount(
        account: account,
        root: newRoot,
        genesis: genesis,
        history: [manifest],
        checkpoint: checkpoint,
        sessionId: 'primary',
        recovery: finalized,
        anchorKey: anchorPrivate,
        legacyKey: privateKey);
    await store.deleteEnrollmentJournal(account);
    await load();
    return {
      'revision': result['revision'],
      'recovery': finalized,
      'rotated': true
    };
  }

  Future<Map<String, dynamic>> _adoptRotated(
      Map<String, dynamic> genesis,
      Map<String, dynamic> backup,
      String passphrase,
      String newRoot,
      String anchorPrivate) async {
    final nonce = await transport.legacyChallenge(account);
    final operation = sha256Hex(jsonEncode(['legacy-session', null]));
    final proof = await crypto.signData(
        requestText(account, 'primary', nonce, operation), anchorPrivate);
    await transport.legacySession(account, nonce, proof);
    final session = await transport.session();
    final dir = session['directory'];
    if (session['account'] != account ||
        dir is! Map ||
        (dir['history'] as List?)?.isEmpty != false) {
      throw StateError(
          'Rotation не подтверждена сервером; локальное состояние не изменено.');
    }
    return _adoptDirectory(Map<String, dynamic>.from(dir), genesis, backup,
        passphrase,
        anchorRoot: newRoot, anchorKey: anchorPrivate, legacyKey: privateKey);
  }

  Future<Map<String, dynamic>> _finalizeBackup(Map<String, dynamic> backup,
      String passphrase, Map<String, dynamic> genesis) async {
    try {
      return await v2.finalizeRecoveryBackup(backup, passphrase, genesis);
    } catch (_) {
      throw StateError(
          'Recovery-фраза не совпадает с пакетом, сохранённым при первой '
          'попытке перехода. Введите ту же фразу; ключи не пересоздаются.');
    }
  }

  /// Перенимает уже зафиксированный на сервере каталог после сбоя клиента.
  /// Genesis сверяется с исходным RSA-якорем; история проверяется полностью.
  Future<Map<String, dynamic>> _adoptDirectory(
      Map<String, dynamic> dir,
      Map<String, dynamic> journalGenesis,
      Map<String, dynamic> backup,
      String passphrase,
      {String? anchorRoot, String? anchorKey, String? legacyKey}) async {
    final effectiveRoot = anchorRoot ?? root;
    final serverGenesis = Map<String, dynamic>.from(dir['genesis'] as Map);
    final history = (dir['history'] as List).cast<Map<String, dynamic>>();
    await v2.verifier.verifyGenesis(serverGenesis, effectiveRoot);
    await v2.verifier.verifyHistory(history, effectiveRoot, null, genesis: serverGenesis);
    final tip = history.last;
    final sameGenesis = sha256Hex(genesisText(serverGenesis)) ==
        sha256Hex(genesisText(journalGenesis));
    // Если genesis отличается от журнального (enrollment выполнен раньше без
    // журнала), recovery-пакет журнала к нему не подходит — честно сообщаем.
    final finalized = sameGenesis
        ? await _finalizeBackup(backup, passphrase, serverGenesis)
        : null;
    final checkpoint = {
      'account': account,
      'rootFingerprint': spkiFingerprint(effectiveRoot),
      'revision': tip['revision'],
      'digest': sha256Hex(manifestText(tip)),
      'genesisDigest': sha256Hex(genesisText(serverGenesis))
    };
    await store.saveAccount(
        account: account,
        root: effectiveRoot,
        genesis: serverGenesis,
        history: history,
        checkpoint: checkpoint,
        sessionId: 'primary',
        recovery: finalized,
        anchorKey: anchorKey,
        legacyKey: legacyKey);
    await store.deleteEnrollmentJournal(account);
    await load();
    return {
      'revision': tip['revision'],
      'recovery': finalized,
      'adopted': true,
      if (!sameGenesis) 'recoveryLost': true
    };
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
    return _sealAndQueue(peer, encodePayload(text, reply));
  }

  /// Медиа (контракт C4): чанки ≤32 КиБ как отдельные подписанные сообщения;
  /// получатель собирает по id/index. EXIF срезается на клиенте до шифрования.
  Future<String> sendMedia(String peer, Uint8List bytes,
      {String mime = 'image/jpeg'}) async {
    final mediaId = randomHex(16);
    final payloads = splitMediaPayloads(bytes, id: mediaId, mime: mime);
    for (final payload in payloads) {
      await _sealAndQueue(peer, payload);
    }
    return mediaId;
  }

  Future<String> _sealAndQueue(String peer, String payload) async {
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
        payload,
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

  /// Read-ACK (C5): только свои входящие; идемпотентно на сервере.
  Future<void> markRead(List<String> refs) async {
    if (refs.isEmpty) return;
    await transport.read(refs,
        account: account, id: 'primary', privateKey: privateKey);
  }

  /// Delete-for-all (C3): только исходящие; локально помечается «отозвано».
  Future<void> retractMessage(String ref) async {
    final message = await store.messageByRef(ref);
    check(message != null, 'Сообщение не найдено');
    check(message!['direction'] == 'out', 'Отозвать можно только своё сообщение');
    await transport.retract([ref],
        account: account, id: 'primary', privateKey: privateKey);
    await store.markRetracted(ref);
  }

  /// Tombstones с сервера: локальные копии помечаются «отозвано отправителем».
  /// Возвращает курсор (max deletedAt) для следующего инкрементального запроса.
  Future<int> syncRetractions({int since = 0}) async {
    final tombstones = await transport.retractions(since: since,
        account: account, id: 'primary', privateKey: privateKey);
    var cursor = since;
    for (final t in tombstones.cast<Map<String, dynamic>>()) {
      final ref = t['ref'] as String;
      final deletedAt = t['deletedAt'] as int;
      if (deletedAt > cursor) cursor = deletedAt;
      if (await store.hasRef(ref)) await store.markRetracted(ref);
    }
    return cursor;
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

  /// One-way мост v1: забирает недошедшие offline-сообщения v1 для уже
  /// переведённого аккаунта. Ciphertext {k,d} расшифровывается тем же исходным
  /// RSA (primary); сервер никогда не видит plaintext. Дедупликация по
  /// v1-идентичности (from:id); ACK только после долговечного сохранения.
  Future<int> syncLegacyInbox() async {
    if (!enrolled) return 0;
    final envelopes = await transport.legacyInbox(
        account: account, id: 'primary', privateKey: privateKey);
    var count = 0;
    final refs = <String>[];
    final serverRefs = <String>[];
    for (final raw in envelopes) {
      final e = Map<String, dynamic>.from(raw as Map);
      final id = e['id'] as String;
      final from = e['from'] as String;
      final ref = 'v1:$from:$id';
      // ACK по полному ref `from:id`: голый id мог совпасть у двух
      // отправителей и удалить чужое сообщение из моста.
      serverRefs.add('$from:$id');
      refs.add(ref);
      final inserted = await store.insertReceived(
          ref: ref,
          peer: from,
          messageId: id,
          createdAt: (e['timestamp'] as num).toInt(),
          payload:
              Map<String, dynamic>.from(jsonDecode(e['data'] as String) as Map));
      if (inserted) count++;
    }
    if (serverRefs.isNotEmpty) {
      // ACK только после durable локального сохранения (two-phase):
      // серверный тумбстоун переживает crash и дренирует v1-очередь.
      await transport.legacyAck(serverRefs,
          account: account, id: 'primary', privateKey: privateKey);
      await store.markAcked(refs);
    }
    return count;
  }

  /// Честное ограничение v2→v1: собеседник ещё не перешёл на v2. Сервер
  /// отклоняет send с `peer_upgrade_required`; ciphertext остаётся в
  /// подписанном outbox и будет отправлен после перехода собеседника.
  Future<bool> isPeerUpgradeBlocked(String peer) async {
    final rows = await store.outboxAll();
    return rows.any((r) =>
        r['peer'] == peer && r['lastError'] == 'peer_upgrade_required');
  }

  Future<List<Map<String, dynamic>>> refreshDelivery(List<String> refs) async {
    if (refs.isEmpty) return [];
    final status = await transport.status(refs,
        account: account, id: 'primary', privateKey: privateKey);
    for (final ref in refs) {
      final devices = status[ref] as List? ?? [];
      for (final d in devices.cast<Map<String, dynamic>>()) {
        await store.upsertDelivery(
            ref, d['id'] as String, d['acknowledgedAt'] as int?,
            readAt: d['readAt'] as int?);
      }
    }
    return [
      for (final ref in refs)
        {'ref': ref, 'devices': await store.deliveryFor(ref)}
    ];
  }

  /// История чата: ciphertext хранится в SQLCipher, расшифровка при чтении.
  /// Payload-декодирование совместимо с PWA: plain text, {"shade":1,"t","r"}
  /// и медиа-чанки {"shade":1,"m":...}, собираемые в одно изображение.
  Future<List<Map<String, dynamic>>> getMessages(String peer) async {
    final rows = await store.messagesByPeer(peer);
    final decoded = <Map<String, dynamic>>[];
    for (final row in rows) {
      // Bridged v1-ciphertext зашифрован СТАРЫМ ключом: после rotation он
      // хранится отдельно и никогда не покидает устройство.
      final decryptionKey = (row['ref'] as String).startsWith('v1:')
          ? (legacyPrivateKey ?? privateKey)
          : privateKey;
      final plain =
          await crypto.decryptData(row['payload'] as String, decryptionKey);
      final decodedRow = {...row, ...decodePayload(plain)};
      // Legacy v1 форматы из моста: "IMG:<base64>" и reply-JSON {"t","r"}.
      if ((row['ref'] as String).startsWith('v1:')) {
        final text = decodedRow['text'] as String? ?? '';
        if (text.startsWith('IMG:')) {
          decodedRow['text'] = '';
          decodedRow['isImage'] = true;
          decodedRow['imageData'] = base64Decode(text.substring(4));
        } else {
          try {
            final parsed = jsonDecode(text);
            if (parsed is Map && parsed['t'] is String) {
              decodedRow['text'] = parsed['t'];
              if (parsed['r'] is Map) {
                decodedRow['reply'] = parsed['r'];
              }
            }
          } catch (_) {/* обычный текст */}
        }
      }
      decoded.add(decodedRow);
    }
    final mediaParts = <String, List<Map<String, dynamic>>>{};
    final result = <Map<String, dynamic>>[];
    for (final row in decoded) {
      final media = row['media'];
      if (media is Map<String, dynamic>) {
        (mediaParts[media['id'] as String] ??= []).add(row);
      } else {
        result.add(row);
      }
    }
    for (final entry in mediaParts.entries) {
      final parts = entry.value;
      final assembled = assembleMedia(
          parts.map((r) => r['media'] as Map<String, dynamic>).toList());
      final first = parts.first;
      if (assembled != null) {
        result.add({
          ...first,
          'text': '',
          'isImage': true,
          'imageData': assembled,
          'mediaId': entry.key
        });
      } else {
        result.add({...first, 'text': '📷 Фото загружается…', 'mediaPending': true});
      }
    }
    result.sort((a, b) => (a['createdAt'] as int).compareTo(b['createdAt'] as int));
    return result;
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
  int _retractionCursor = 0;
  void attachWake() {
    transport.onWake = () {
      syncInbox()
          .then((_) => syncLegacyInbox())
          .then((_) => flushOutbox())
          .then((_) => syncRetractions(since: _retractionCursor))
          .then((cursor) { _retractionCursor = cursor; })
          .catchError((Object _) {});
    };
  }
}