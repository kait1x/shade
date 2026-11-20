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
import 'pairing.dart';
import 'payload.dart';
import 'protocol.dart';
import 'store.dart';
import 'transport.dart';

class V2ChatRepository {
  final AlphaTransport transport;
  final DeviceV2Crypto v2;
  final CryptoService crypto;
  final V2Store store;
  // Аккаунт может быть уточнён при восстановлении: репозиторий создаётся до
  // выбора пакета (account ''), а recoverWithBackup принимает аккаунт genesis.
  String account;
  String root; // SPKI base64 якоря (primary); после rotation — новый RSA-4096
  String privateKey; // PEM, никогда не покидает устройство
  /// Исходный v1-ключ после rotation: расшифровка старой истории и bridged
  /// v1-ciphertext. Не заменяет якорь и не используется для новых сообщений.
  String? legacyPrivateKey;
  bool _syncing = false;

  /// Pairing второго устройства: криптография контракта pairing.mjs.
  final DeviceV2Pairing _pairing;

  /// Сессия НОВОГО устройства (startPairing/completePairing) либо сессия
  /// подключённого вторичного устройства, восстановленная из долговечных
  /// ключей. Чат от вторичного устройства проводится отдельно (D2).
  DeviceV2Session? _pairingSession;

  /// Одноразовый challenge доверенной стороны; живёт только в памяти и
  /// потребляется успешным подтверждением (украденный экран не переиспользовать).
  Map<String, dynamic>? _pairingChallenge;

  V2ChatRepository({
    required this.transport,
    required this.crypto,
    required this.store,
    required this.account,
    required this.root,
    required this.privateKey,
  })  : v2 = DeviceV2Crypto(crypto),
        _pairing = DeviceV2Pairing(crypto);

  /// Репозиторий НОВОГО устройства до enrollment: якорь аккаунта ещё не
  /// известен — он будет закреплён из проверенного genesis в completePairing.
  /// Ключи устройства создаются в startPairing и журналируются долговечно.
  V2ChatRepository.pairing({
    required this.transport,
    required this.crypto,
    required this.store,
    required this.account,
  })  : root = '',
        privateKey = '',
        v2 = DeviceV2Crypto(crypto),
        _pairing = DeviceV2Pairing(crypto);

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
      // Вторичное устройство: собственная сессия из долговечных ключей,
      // сохранённых completePairing (перезапуск не теряет идентичность).
      if (acc['sessionId'] != 'primary') {
        final keys = await store.loadDeviceKeys(account);
        if (keys != null) {
          _pairingSession = DeviceV2Session(
              account: account,
              id: keys['deviceId'] as String,
              encryptionKey: keys['encryptionKey'] as String,
              signingKey: keys['signingKey'] as String,
              encryptionPrivateKey: keys['encryptionPrivate'] as String,
              signingPrivateKey: keys['signingPrivate'] as String);
        }
      }
    }
  }

  /// Сессия подключённого вторичного устройства (null у primary/до pairing).
  DeviceV2Session? get pairedSession => _pairingSession;

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

  // ── Pairing второго устройства (контракт client/web/pairing.mjs) ───────
  //
  // Доверенная сторона: pairingChallenge → reviewPairingOffer → approvePairing
  // (подписанный манифест + challenge-bound proof нового устройства → install).
  // Новая сторона: startPairing (долговечные ключи + подписанный offer с эхом
  // challenge) → completePairing (проверка подтверждения → device-сессия →
  // авторитетный каталог сервера → локальная фиксация).
  // Crash-safe по образцу enrollLegacy: долговечный журнал v2_pairing_journal
  // хранит ключи/артефакты ДО сетевых вызовов; повтор после любого сбоя
  // перенимает серверное состояние, не создавая вторых манифестов/ключей.

  /// Доверенное устройство: свежий одноразовый код (5 минут) для экрана
  /// подтверждения. Offer нового устройства обязан эхом подтвердить его.
  Map<String, dynamic> pairingChallenge({int? now}) {
    final challenge = createPairingChallenge(now: now);
    _pairingChallenge = challenge;
    return {'code': challenge['code'], 'expiresAt': challenge['expiresAt']};
  }

  /// Доверенное устройство: проверка вставленного offer без изменения
  /// состояния. Возвращает {deviceId, offer, expiresAt} для экрана сверки.
  Future<Map<String, dynamic>> reviewPairingOffer(String text) async {
    final challenge = _pairingChallenge;
    check(challenge != null &&
        (challenge['expiresAt'] as int) > DateTime.now().millisecondsSinceEpoch,
        'Код подключения истёк. Сгенерируйте новый и создайте запрос заново.');
    final offer = decodeOffer(text);
    final device = await _pairing.verifyPairingOffer(offer,
        account: account, challenge: challenge!['nonce'] as String);
    return {'deviceId': device['id'], 'offer': offer, 'expiresAt': offer['expiresAt']};
  }

  /// Доверенное устройство: явное подтверждение = манифест, подписанный ЭТИМ
  /// устройством, с новым устройством в ростере; сервер перепроверяет
  /// challenge-bound proof из offer. Возвращает текст подтверждения для
  /// нового устройства. Повтор после сбоя перенимает зафиксированный каталог.
  Future<String> approvePairing(String text) async {
    final acc = _requireAccount();
    final genesis = acc['genesis'] as Map<String, dynamic>;
    final journal = await store.loadPairingJournal(account);
    // Повтор того же offer после сбоя: манифест уже подписан и проверен —
    // challenge мог истечь, но подпись offer неизменна и была проверена до журнала.
    final resume = journal != null &&
        journal['role'] == 'trusted' &&
        journal['offerText'] == text;
    Map<String, dynamic> offer;
    Map<String, dynamic>? manifest;
    List<dynamic>? proofs;
    if (resume) {
      offer = Map<String, dynamic>.from(journal['offer'] as Map);
      manifest = Map<String, dynamic>.from(journal['manifest'] as Map);
      proofs = journal['proofs'] as List;
    } else {
      final review = await reviewPairingOffer(text);
      offer = review['offer'] as Map<String, dynamic>;
    }
    final offerDevice = offer['device'] as Map<String, dynamic>;
    // Свежий каталог сервера: ростер мог измениться другим устройством.
    final dir = await transport.directory(account,
        account: account, id: _session.id, privateKey: privateKey);
    final history = (dir['history'] as List).cast<Map<String, dynamic>>();
    await v2.verifier.verifyHistory(history, root,
        acc['checkpoint'] as Map<String, dynamic>, genesis: genesis);
    final tip = history.last;
    if (resume &&
        (tip['revision'] as int) >= (manifest!['revision'] as int) &&
        (tip['devices'] as List).any((d) => d['id'] == offerDevice['id'])) {
      // Сервер уже зафиксировал манифест до сбоя клиента — перенимаем.
      return _finishApproval(acc, genesis, history);
    }
    check(!(tip['devices'] as List).any((d) => d['id'] == offerDevice['id']),
        'Это устройство уже подключено');
    check((tip['devices'] as List).length < maxDevices,
        'Достигнут лимит 8 устройств');
    if (!resume) {
      final now = DateTime.now().millisecondsSinceEpoch;
      final devices = [
        ...(tip['devices'] as List).cast<Map<String, dynamic>>(),
        offerDevice
      ]..sort((a, b) => (a['id'] as String).compareTo(b['id'] as String));
      manifest = <String, dynamic>{
        'account': account,
        'rootFingerprint': spkiFingerprint(root),
        'revision': (tip['revision'] as int) + 1,
        'previous': sha256Hex(manifestText(tip)),
        'issuedAt': now,
        'expiresAt': now + maxLeaseMs,
        'devices': devices,
        'signer': _session.id,
        'signature': ''
      };
      manifest['signature'] =
          await crypto.signData(manifestText(manifest), privateKey);
      // Полная проверка расширенной цепочки ДО отправки (как approveDevices).
      await v2.verifier.verifyHistory([...history, manifest], root, null,
          now: now, genesis: genesis);
      // Только поля, которые потребляет registry: v2 несёт challenge внутри
      // подписанного proof; v1 сохраняет legacy-форму на переходный период.
      proofs = [
        {
          'id': offerDevice['id'],
          'nonce': offer['nonce'],
          'expiresAt': offer['expiresAt'],
          'signature': offer['signature'],
          if (offer['v'] == 2) 'challenge': offer['challenge'],
          if (offer['v'] == 2) 'pairingVersion': 2
        }
      ];
      await store.savePairingJournal(account, {
        'role': 'trusted',
        'phase': 'installing',
        'deviceId': offerDevice['id'],
        'offerText': text,
        'offer': offer,
        'manifest': manifest,
        'proofs': proofs
      });
    }
    final signedManifest = manifest!;
    final signedProofs = proofs!;
    try {
      await transport.install(signedManifest,
          proofs: signedProofs, account: account, id: _session.id, privateKey: privateKey);
    } on AlphaTransportException {
      // Сервер мог уже зафиксировать манифест (сбой клиента после коммита) —
      // перенимаем проверенный каталог, а не устанавливаем повторно.
      final retryDir = await transport.directory(account,
          account: account, id: _session.id, privateKey: privateKey);
      final retryHistory =
          (retryDir['history'] as List).cast<Map<String, dynamic>>();
      await v2.verifier.verifyHistory(retryHistory, root, null, genesis: genesis);
      final retryTip = retryHistory.last;
      if ((retryTip['revision'] as int) < (signedManifest['revision'] as int) ||
          !(retryTip['devices'] as List).any((d) => d['id'] == offerDevice['id'])) {
        rethrow;
      }
      return _finishApproval(acc, genesis, retryHistory);
    }
    final fresh = await transport.directory(account,
        account: account, id: _session.id, privateKey: privateKey);
    final freshHistory = (fresh['history'] as List).cast<Map<String, dynamic>>();
    return _finishApproval(acc, genesis, freshHistory);
  }

  /// Локальная фиксация подтверждённого каталога + одноразовое подтверждение.
  Future<String> _finishApproval(Map<String, dynamic> acc,
      Map<String, dynamic> genesis, List<Map<String, dynamic>> history) async {
    final verified =
        await v2.verifier.verifyHistory(history, root, null, genesis: genesis);
    final checkpoint = {
      'account': account,
      'rootFingerprint': verified['rootFingerprint'],
      'revision': verified['revision'],
      'digest': verified['digest'],
      'genesisDigest': sha256Hex(genesisText(genesis))
    };
    await store.saveAccount(
        account: account,
        root: root,
        genesis: genesis,
        history: history,
        checkpoint: checkpoint,
        sessionId: acc['sessionId'] as String,
        recovery: acc['recovery'] as Map<String, dynamic>?,
        anchorKey: acc['anchorKey'] as String?,
        legacyKey: acc['legacyKey'] as String?);
    await store.deletePairingJournal(account);
    // Одноразовый challenge потреблён: повторное подтверждение тем же кодом невозможно.
    _pairingChallenge = null;
    await load();
    return encodeConfirmation(buildPairingConfirmation(
        account: account, genesis: genesis, tip: history.last));
  }

  /// Новое устройство: долговечные ключи + подписанный offer с эхом свежего
  /// challenge (≤5 минут). Ключи журналируются ДО offer: прерванная попытка
  /// не теряет идентичность, повтор создаёт свежий offer тем же ключом.
  /// Возвращает {offerText, offer, deviceId, expiresAt, challengeEcho}.
  Future<Map<String, dynamic>> startPairing(
      {required String challengeCode, int? now}) async {
    // Валидация кода — до любого I/O: честная ошибка ввода сразу.
    final challenge = decodeChallenge(challengeCode);
    final existing = await store.loadAccount(account);
    check(existing == null,
        'На этом устройстве уже есть ключи аккаунта. Разблокируйте их.');
    final journal = await store.loadPairingJournal(account);
    DeviceV2Session session;
    Map<String, dynamic> entry;
    if (journal != null &&
        journal['role'] == 'new' &&
        journal['encryptionPrivate'] != null) {
      session = _sessionFromJournal(journal);
      entry = Map<String, dynamic>.from(journal);
    } else {
      session = await _pairing.generateDeviceSession(account);
      entry = {
        'role': 'new',
        'phase': 'keys',
        'deviceId': session.id,
        'encryptionKey': session.encryptionKey,
        'signingKey': session.signingKey,
        'encryptionPrivate': session.encryptionPrivateKey,
        'signingPrivate': session.signingPrivateKey
      };
      // Приватные ключи — в SQLCipher (at-rest) ДО любых сетевых шагов.
      await store.savePairingJournal(account, entry);
    }
    _pairingSession = session;
    final offer = await _pairing.buildPairingOffer(
        account: account,
        device: session.descriptor,
        signingPrivateKey: session.signingPrivateKey,
        challenge: challenge,
        now: now);
    final offerText = encodeOffer(offer);
    entry = {
      ...entry,
      'phase': 'offered',
      'offerText': offerText,
      'offer': offer
    };
    await store.savePairingJournal(account, entry);
    return {
      'offerText': offerText,
      'offer': offer,
      'deviceId': session.id,
      'expiresAt': offer['expiresAt'],
      'challengeEcho': challengeCodeOf(challenge)
    };
  }

  DeviceV2Session _sessionFromJournal(Map<String, dynamic> journal) =>
      DeviceV2Session(
          account: account,
          id: journal['deviceId'] as String,
          encryptionKey: journal['encryptionKey'] as String,
          signingKey: journal['signingKey'] as String,
          encryptionPrivateKey: journal['encryptionPrivate'] as String,
          signingPrivateKey: journal['signingPrivate'] as String);

  /// Новое устройство: завершение подключения. Подтверждение — только
  /// подсказка маршрута: доверие строится из ПОЛНОГО каталога сервера,
  /// проверенного против закреплённого genesis после открытия device-сессии.
  /// Crash-safe: проверенное подтверждение журналируется до сети; повтор
  /// после любого сбоя продолжает с журнала, ключи не пересоздаются.
  Future<Map<String, dynamic>> completePairing(String text, {int? now}) async {
    now ??= DateTime.now().millisecondsSinceEpoch;
    // Идемпотентность: уже подключено — ничего не пересоздаём.
    final existing = await store.loadAccount(account);
    if (existing != null) {
      final orphan = await store.loadPairingJournal(account);
      if (orphan != null && orphan['role'] == 'new') {
        await store.deletePairingJournal(account);
      }
      return {
        'revision': (existing['checkpoint'] as Map)['revision'],
        'alreadyPaired': true
      };
    }
    final journal = await store.loadPairingJournal(account);
    check(journal != null &&
        journal['role'] == 'new' &&
        journal['encryptionPrivate'] != null,
        'Ключи устройства не созданы. Сначала создайте запрос подключения.');
    final session = _sessionFromJournal(journal!);
    _pairingSession = session;
    Map<String, dynamic> genesis;
    String root;
    String genesisDigest;
    if (journal['confirmation'] != null && journal['confirmationText'] == text) {
      // Повтор после сбоя: подтверждение уже проверено и записано до сети.
      genesis = Map<String, dynamic>.from(journal['genesis'] as Map);
      root = journal['root'] as String;
      genesisDigest = sha256Hex(genesisText(genesis));
    } else {
      final confirmation = decodeConfirmation(text);
      final verified = await _pairing.verifyPairingConfirmation(confirmation,
          account: account, deviceId: session.id, now: now);
      genesis = verified['genesis'] as Map<String, dynamic>;
      root = verified['root'] as String;
      genesisDigest = verified['genesisDigest'] as String;
      await store.savePairingJournal(account, {
        ...journal,
        'phase': 'confirming',
        'confirmationText': text,
        'confirmation': confirmation,
        'root': root,
        'genesis': genesis
      });
    }
    // Bootstrap device-сессии: relay разрешает sessionless challenge только
    // для device-session; устройство уже в ростере (install доверенной стороны).
    await transport.deviceSession(account, session.id, session.signingPrivateKey);
    // Авторитетный каталог сервера через подписанную операцию directory.
    final dir = await transport.directory(account,
        account: account, id: session.id, privateKey: session.signingPrivateKey);
    final serverGenesis = Map<String, dynamic>.from(dir['genesis'] as Map);
    final serverRoot = dir['root'] as String;
    check(serverRoot == root &&
        sha256Hex(genesisText(serverGenesis)) == genesisDigest,
        'Каталог сервера не совпадает с подтверждённым аккаунтом');
    final history = (dir['history'] as List).cast<Map<String, dynamic>>();
    final own = await v2.verifier
        .verifyHistory(history, serverRoot, null, now: now, genesis: serverGenesis);
    check((history.last['devices'] as List).any((d) => d['id'] == session.id),
        'Устройство отсутствует в каталоге сервера');
    final checkpoint = {
      'account': account,
      'rootFingerprint': own['rootFingerprint'],
      'revision': own['revision'],
      'digest': own['digest'],
      'genesisDigest': own['genesisDigest']
    };
    // Ключи устройства фиксируются долговечно до состояния аккаунта; журнал
    // удаляется последним — сбой между шагами оставляет возобновляемый журнал.
    await store.saveDeviceKeys(
        account: account,
        deviceId: session.id,
        encryptionKey: session.encryptionKey,
        signingKey: session.signingKey,
        encryptionPrivate: session.encryptionPrivateKey,
        signingPrivate: session.signingPrivateKey);
    await store.saveAccount(
        account: account,
        root: serverRoot,
        genesis: serverGenesis,
        history: history,
        checkpoint: checkpoint,
        sessionId: session.id);
    await store.deletePairingJournal(account);
    await load();
    return {'account': account, 'revision': own['revision'], 'deviceId': session.id};
  }

  // ── Восстановление с recovery-пакетом (PRF_RECOVERY_BLOCKER §3) ─────────────
  // Все устройства аккаунта утрачены. Старые ключи устройства НЕ возвращаются:
  // создаётся новая сессия устройства, независимый recovery-ключ из пакета
  // открывает короткоживущую recovery-сессию, ростер заменяется манифестом
  // signer:'recovery' только с новым устройством, затем открывается обычная
  // device-сессия. Последовательность 1:1 с client/web/alpha-client.mjs
  // recoverWithBackup; криптоформаты и протокол не меняются.
  //
  // Локальная фиксация — только после полного успеха на сервере: прерванная
  // попытка не оставляет ключей без состояния (журнал не ведётся), повтор
  // создаёт новые ключи. At-rest защита новых ключей — SQLCipher с
  // device-bound ключом (нативный эквивалент web-vault; локальная разблокировка
  // не требует фразы, переносимый vault-экспорт для web — отдельная задача).

  bool _recovering = false;

  /// [pkg] — {backup, genesis} из файла recovery-пакета; [recoveryPhrase] —
  /// фраза, расшифровывающая пакет (≥24 символа, проверяется расшифровкой).
  /// [onStep] — шаги потока: unlock/keys/session/install/bootstrap.
  Future<Map<String, dynamic>> recoverWithBackup(
      Map<String, dynamic> pkg, String recoveryPhrase,
      {void Function(String step)? onStep}) async {
    check(!_recovering, 'Восстановление уже выполняется');
    _recovering = true;
    try {
      final step = onStep ?? (_) {};
      final backupRaw = pkg['backup'];
      final genesisRaw = pkg['genesis'];
      check(backupRaw is Map && genesisRaw is Map,
          'Неверный формат recovery-пакета');
      final backup = Map<String, dynamic>.from(backupRaw as Map);
      final genesis = Map<String, dynamic>.from(genesisRaw as Map);
      final pkgAccount = genesis['account'];
      check(pkgAccount is String && accountPattern.hasMatch(pkgAccount),
          'Неверный аккаунт в recovery-пакете');
      // Репозиторий уже привязан к аккаунту (подключённое устройство) —
      // чужой пакет не может тихо сменить личность.
      check(account.isEmpty || account == pkgAccount,
          'Recovery-пакет принадлежит другому аккаунту');
      final targetAccount = pkgAccount as String;
      final rootAnchor =
          (genesis['firstDevice'] as Map)['signingKey'] as String;
      final genesisDigest = sha256Hex(genesisText(genesis));

      // 1) Recovery-ключ: фраза расшифровывает пакет, привязанный к точному
      // genesis (identity + genesisDigest проверяются внутри unlock).
      step('unlock');
      final recoveryPem =
          await v2.unlockRecoveryBackup(backup, recoveryPhrase, genesis);

      // 2) Новый vault с НОВЫМИ ключами устройства (нативный эквивалент
      // createVault/unlockVault): пара RSA-4096, приватные части только в
      // памяти до полного успеха. Формат ключей/протокола не менялся.
      step('keys');
      final session = await _pairing.generateDeviceSession(targetAccount);

      // 3) Recovery-сессия: challenge → подпись recovery-ключом, привязанная
      // к genesisDigest, → вход. Сервер сверяет принесённый genesis с хранимым.
      step('session');
      final nonce = await transport.recoveryChallenge(targetAccount);
      final operation = operationDigest('recovery-session', genesisDigest);
      final proof = await crypto.signData(
          requestText(targetAccount, 'primary', nonce, operation), recoveryPem);
      await transport.recoverySession(targetAccount, genesis, nonce, proof);

      // 4) Каталог через op directory: recovery-сессия разрешает только его
      // и install; auth несёт только account (без device-proof).
      final directory = await transport.recoveryOperation('directory',
          targetAccount, account: targetAccount) as Map<String, dynamic>;
      final dirGenesis =
          Map<String, dynamic>.from(directory['genesis'] as Map);
      check(sha256Hex(genesisText(dirGenesis)) == genesisDigest,
          'Genesis digest mismatch');
      final history =
          (directory['history'] as List).cast<Map<String, dynamic>>();

      // 5) Манифест revision+1 signer:'recovery': ростер только из нового
      // устройства, старые retire-ятся сервером. Possession proof —
      // challenge-bound v2 с self-generated challenge (как при обычном
      // pairing, доверенное устройство не нужно).
      step('install');
      final now = DateTime.now().millisecondsSinceEpoch;
      final tip = history.last;
      final manifest = <String, dynamic>{
        'account': targetAccount,
        'rootFingerprint': spkiFingerprint(rootAnchor),
        'revision': (tip['revision'] as int) + 1,
        'previous': sha256Hex(manifestText(tip)),
        'issuedAt': now,
        'expiresAt': now + maxLeaseMs,
        'devices': [session.descriptor],
        'signer': 'recovery',
        'signature': ''
      };
      manifest['signature'] =
          await crypto.signData(manifestText(manifest), recoveryPem);
      // Полная проверка расширенной цепочки ДО отправки (как approveDevices).
      await v2.verifier.verifyHistory([...history, manifest], rootAnchor, null,
          now: now, genesis: genesis);
      final offer = await _pairing.buildPairingOffer(
          account: targetAccount,
          device: session.descriptor,
          signingPrivateKey: session.signingPrivateKey,
          challenge: createPairingChallenge()['nonce'] as String);
      final offerDevice = offer['device'] as Map<String, dynamic>;
      final proofs = [
        {
          'id': offerDevice['id'],
          'nonce': offer['nonce'],
          'expiresAt': offer['expiresAt'],
          'challenge': offer['challenge'],
          'pairingVersion': 2,
          'signature': offer['signature']
        }
      ];
      await transport.recoveryOperation('install',
          {'manifest': manifest, 'proofs': proofs}, account: targetAccount);

      // 6) Bootstrap обычной device-сессии нового устройства (sessionless
      // challenge): recovery-cookie заменяется обычной device-cookie.
      step('bootstrap');
      await transport.deviceSession(
          targetAccount, session.id, session.signingPrivateKey);

      // 7) Каталог уже device-сессией: полная проверка цепочки, genesis и
      // ростера против закреплённого genesis пакета.
      final fresh = await transport.directory(targetAccount,
          account: targetAccount,
          id: session.id,
          privateKey: session.signingPrivateKey);
      final serverGenesis =
          Map<String, dynamic>.from(fresh['genesis'] as Map);
      final serverRoot = fresh['root'] as String;
      check(serverRoot == rootAnchor &&
          sha256Hex(genesisText(serverGenesis)) == genesisDigest,
          'Каталог сервера не совпадает с recovery-пакетом');
      final freshHistory =
          (fresh['history'] as List).cast<Map<String, dynamic>>();
      final own = await v2.verifier
          .verifyHistory(freshHistory, serverRoot, null, genesis: serverGenesis);
      check((freshHistory.last['devices'] as List).any((d) => d['id'] == session.id),
          'Устройство отсутствует в каталоге сервера');

      // 8) Локальная фиксация после успеха: ключи + состояние. Recovery-пакет
      // сохраняется в состоянии — он по-прежнему действует (genesis неизменяем).
      // Порядок как в completePairing: ключи долговечно до состояния аккаунта.
      final checkpoint = {
        'account': targetAccount,
        'rootFingerprint': own['rootFingerprint'],
        'revision': own['revision'],
        'digest': own['digest'],
        'genesisDigest': own['genesisDigest']
      };
      await store.saveDeviceKeys(
          account: targetAccount,
          deviceId: session.id,
          encryptionKey: session.encryptionKey,
          signingKey: session.signingKey,
          encryptionPrivate: session.encryptionPrivateKey,
          signingPrivate: session.signingPrivateKey);
      await store.saveAccount(
          account: targetAccount,
          root: serverRoot,
          genesis: serverGenesis,
          history: freshHistory,
          checkpoint: checkpoint,
          sessionId: session.id,
          recovery: backup);
      account = targetAccount;
      root = serverRoot;
      // Приватная часть якоря утрачена вместе со старыми устройствами;
      // legacy-мост v1 после восстановления недоступен (честно).
      privateKey = '';
      legacyPrivateKey = null;
      _pairingSession = session;
      await load();
      return {
        'account': targetAccount,
        'revision': own['revision'],
        'deviceId': session.id
      };
    } finally {
      _recovering = false;
    }
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
        confirmed: true,
        // Долговечная проверенная цепочка: offline-seal нового peer-сообщения.
        history: dir['history'] as List);
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
        confirmed: true,
        // Обновление ТОЛЬКО после успешной проверки цепочки против
        // закреплённого checkpoint (fail-closed выше по стеку).
        history: dir['history'] as List);
    return {
      'root': contact['root'],
      'genesis': contact['genesis'],
      'history': dir['history'],
      'checkpoint': checkpoint
    };
  }

  /// Последняя онлайн-проверенная цепочка каталога контакта для offline-seal
  /// (sync.dart). null — контакт не подтверждён либо старая запись без
  /// history: offline-отправка недоступна до первой онлайн-верификации.
  /// Подмена chain при онлайн-верификации отклоняется verifyHistory против
  /// checkpoint, и сохранённая history не обновляется (fail-closed).
  Future<List<dynamic>?> contactHistory(String peer) async {
    final contact = await store.loadContact(peer);
    if (contact == null || contact['confirmed'] != true) return null;
    return contact['history'] as List<dynamic>?;
  }

  /// Собственный проверенный каталог: обновляется при каждом успешном
  /// enrollment/renewLease/approvePairing (saveAccount) — offline self-seal.
  List<dynamic>? get ownHistory => _accountCache?['history'] as List<dynamic>?;

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