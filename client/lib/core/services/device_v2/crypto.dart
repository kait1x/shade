/// Криптооперации device-v2 поверх существующего CryptoService (fast_rsa).
///
/// Порт client/web/device_crypto.mjs: sealMessage/openMessage, recovery-бэкап
/// (PBKDF2-SHA256 600000 + AES-256-GCM с AAD), genesis/manifest/pairing.
/// Приватные ключи Android остаются в Keystore через CryptoService; здесь
/// передаются только PEM-представления, уже извлечённые владельцем.
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:fast_rsa/fast_rsa.dart';
import 'package:pointycastle/export.dart' as pc;

import '../crypto_service.dart';
import 'protocol.dart';

const int pbkdf2Iterations = 600000;
const int maxTextBytes = 65536;

final Random _secureRandom = Random.secure();

Uint8List randomBytes(int length) =>
    Uint8List.fromList(List.generate(length, (_) => _secureRandom.nextInt(256)));

String randomHex(int byteLength) => randomBytes(byteLength)
    .map((b) => b.toRadixString(16).padLeft(2, '0'))
    .join();

Uint8List pbkdf2Sha256(String passphrase, Uint8List salt,
    {int iterations = pbkdf2Iterations, int length = 32}) {
  final derivator = pc.PBKDF2KeyDerivator(pc.HMac(pc.SHA256Digest(), 64))
    ..init(pc.Pbkdf2Parameters(salt, iterations, length));
  final password = Uint8List.fromList(utf8.encode(passphrase));
  try {
    return derivator.process(password);
  } finally {
    password.fillRange(0, password.length, 0);
  }
}

Uint8List aesGcmEncrypt(Uint8List key, Uint8List iv, Uint8List aad, Uint8List plain) {
  final cipher = pc.GCMBlockCipher(pc.AESEngine())
    ..init(true, pc.AEADParameters(pc.KeyParameter(key), 128, iv, aad));
  return cipher.process(plain);
}

Uint8List aesGcmDecrypt(Uint8List key, Uint8List iv, Uint8List aad, Uint8List cipherWithTag) {
  final cipher = pc.GCMBlockCipher(pc.AESEngine())
    ..init(false, pc.AEADParameters(pc.KeyParameter(key), 128, iv, aad));
  return cipher.process(cipherWithTag);
}

String pemToDerB64(String pem) => pem
    .split('\n')
    .where((s) => !s.startsWith('-----'))
    .join()
    .trim();

String pkcs8DerToPem(String derB64) =>
    '-----BEGIN PRIVATE KEY-----\n$derB64\n-----END PRIVATE KEY-----';

Future<String> publicSpki(String publicKeyPem) async =>
    pemToDerB64(await RSA.convertPublicKeyToPKIX(publicKeyPem));

Future<String> privatePkcs8Der(String privateKeyPem) async =>
    pemToDerB64(await RSA.convertPrivateKeyToPKCS8(privateKeyPem));

Map<String, dynamic>? _atRevision(List<dynamic> history, int revision) =>
    revision >= 1 && revision <= history.length
        ? history[revision - 1] as Map<String, dynamic>
        : null;

/// Разблокированная сессия устройства. Для legacy primary оба ключа — один RSA.
class DeviceV2Session {
  final String account;
  final String id;
  final String encryptionKey; // SPKI base64
  final String signingKey; // SPKI base64
  final String encryptionPrivateKey; // PEM
  final String signingPrivateKey; // PEM

  DeviceV2Session({
    required this.account,
    required this.id,
    required this.encryptionKey,
    required this.signingKey,
    required this.encryptionPrivateKey,
    required this.signingPrivateKey,
  });

  Map<String, dynamic> get descriptor =>
      {'id': id, 'encryptionKey': encryptionKey, 'signingKey': signingKey};
}

/// Закреплённая вне relay личность аккаунта (genesis + checkpoint каталога).
class AccountTrust {
  final String root;
  final Map<String, dynamic> genesis;
  final Map<String, dynamic>? checkpoint;

  AccountTrust({required this.root, required this.genesis, this.checkpoint});
}

class DeviceV2Crypto {
  final CryptoService crypto;
  final DeviceV2Verifier verifier;

  DeviceV2Crypto(this.crypto) : verifier = DeviceV2Verifier(crypto);

  /// sealMessage: fanout-конверты каждому устройству обеих сторон + подпись.
  Future<Map<String, dynamic>> sealMessage(
      String text,
      List<dynamic> senderHistory,
      List<dynamic> recipientHistory,
      DeviceV2Session session,
      AccountTrust sender,
      AccountTrust recipient,
      {int? now}) async {
    now ??= DateTime.now().millisecondsSinceEpoch;
    check(utf8.encode(text).length <= maxTextBytes, 'Text too large');
    await verifier.verifyHistory(senderHistory, sender.root, sender.checkpoint,
        now: now, genesis: sender.genesis);
    await verifier.verifyHistory(recipientHistory, recipient.root, recipient.checkpoint,
        now: now, genesis: recipient.genesis);
    final senderLatest = senderHistory.last as Map<String, dynamic>;
    final recipientLatest = recipientHistory.last as Map<String, dynamic>;
    check(senderLatest['account'] == session.account &&
        (senderLatest['devices'] as List).any((d) => d['id'] == session.id));
    // Self-chat: один ростер/тип; конверты не дедуплицируются постфактум.
    final self = senderLatest['account'] == recipientLatest['account'];
    if (self) {
      check(senderLatest['revision'] == recipientLatest['revision'] &&
          sha256Hex(manifestText(senderLatest)) == sha256Hex(manifestText(recipientLatest)),
          'Self directory mismatch');
    }
    final envelopes = <Map<String, dynamic>>[];
    for (final roster in (self ? [senderLatest] : [senderLatest, recipientLatest])) {
      for (final d in (roster['devices'] as List).cast<Map<String, dynamic>>()) {
        envelopes.add({
          'account': roster['account'],
          'deviceId': d['id'],
          'payload': jsonDecode(
              await crypto.encryptData(text, spkiToPem(d['encryptionKey'] as String)))
        });
      }
    }
    envelopes.sort((a, b) =>
        '${a['account']}:${a['deviceId']}'.compareTo('${b['account']}:${b['deviceId']}'));
    final message = <String, dynamic>{
      'version': 2,
      'id': randomHex(32),
      'from': senderLatest['account'],
      'deviceId': session.id,
      'to': recipientLatest['account'],
      'fromRevision': senderLatest['revision'],
      'toRevision': recipientLatest['revision'],
      'fromDigest': sha256Hex(manifestText(senderLatest)),
      'toDigest': sha256Hex(manifestText(recipientLatest)),
      'createdAt': now,
      'envelopes': envelopes,
      'signature': ''
    };
    message['signature'] =
        await crypto.signData(messageText(message), session.signingPrivateKey);
    return message;
  }

  /// openMessage: проверка каталогов/подписи и расшифровка своего конверта.
  /// Вызывающий обязан атомарно сохранить ciphertext/replay ID до ACK.
  Future<String> openMessage(Map<String, dynamic> bundle, DeviceV2Session session,
      AccountTrust sender, AccountTrust recipient,
      {int? now}) async {
    now ??= DateTime.now().millisecondsSinceEpoch;
    final m = bundle['message'] as Map<String, dynamic>;
    final senderHistory = bundle['senderHistory'] as List;
    final recipientHistory = bundle['recipientHistory'] as List;
    await verifier.verifyHistory(senderHistory, sender.root, sender.checkpoint,
        now: now, genesis: sender.genesis);
    await verifier.verifyHistory(recipientHistory, recipient.root, recipient.checkpoint,
        now: now, genesis: recipient.genesis);
    check(m['to'] == session.account || m['from'] == session.account,
        'Wrong recipient');
    check((senderHistory.last['devices'] as List).any((d) => d['id'] == m['deviceId']),
        'Sender device has been revoked');
    final ownHistory = session.account == m['from'] ? senderHistory : recipientHistory;
    check((ownHistory.last['devices'] as List).any((d) => d['id'] == session.id),
        'Recipient device has been revoked');
    final senderAt = _atRevision(senderHistory, m['fromRevision'] as int);
    final recipientAt = _atRevision(recipientHistory, m['toRevision'] as int);
    check(senderAt != null && recipientAt != null, 'Missing historical directory');
    final senderDir = senderAt!;
    final recipientDir = recipientAt!;
    final createdAt = m['createdAt'] as int;
    check((senderDir['issuedAt'] as int) <= createdAt &&
        (senderDir['expiresAt'] as int) > createdAt &&
        (recipientDir['issuedAt'] as int) <= createdAt &&
        (recipientDir['expiresAt'] as int) > createdAt, 'Message outside directory lease');
    await verifier.verifyMessage(m, senderDir, recipientDir, now: now);
    final own = (m['envelopes'] as List).cast<Map<String, dynamic>>().where(
        (e) => e['account'] == session.account && e['deviceId'] == session.id).firstOrNull;
    check(own != null, 'Device is not a recipient');
    return crypto.decryptData(jsonEncode(own!['payload']), session.encryptionPrivateKey);
  }

  /// Recovery-бэкап: независимый RSA-PSS ключ, шифрованный фразой (24+).
  Future<Map<String, dynamic>> createRecoveryBackup(
      String account, String anchorSpki, String passphrase) async {
    check(passphrase.length >= 24,
        'Use a strong independent recovery passphrase (24+ characters)');
    check(accountPattern.hasMatch(account));
    final pair = await RSA.generate(4096);
    final publicKey = await publicSpki(pair.publicKey);
    final salt = randomBytes(16), iv = randomBytes(12);
    final rootFingerprint = spkiFingerprint(anchorSpki);
    final aad = Uint8List.fromList(utf8.encode(
        jsonEncode(['shade-recovery:v2', account, rootFingerprint, publicKey])));
    final der = Uint8List.fromList(base64.decode(await privatePkcs8Der(pair.privateKey)));
    final key = pbkdf2Sha256(passphrase, salt);
    try {
      return {
        'version': 2,
        'account': account,
        'rootFingerprint': rootFingerprint,
        'publicKey': publicKey,
        'salt': base64.encode(salt),
        'iv': base64.encode(iv),
        'ciphertext': base64.encode(aesGcmEncrypt(key, iv, aad, der))
      };
    } finally {
      der.fillRange(0, der.length, 0);
      key.fillRange(0, key.length, 0);
    }
  }

  /// Привязывает скачанный пакет к точному genesis digest (новый IV).
  Future<Map<String, dynamic>> finalizeRecoveryBackup(Map<String, dynamic> backup,
      String passphrase, Map<String, dynamic> genesis) async {
    final firstDevice = genesis['firstDevice'] as Map<String, dynamic>;
    await verifier.verifyGenesis(genesis, firstDevice['signingKey'] as String);
    check(backup['genesisDigest'] == null &&
        backup['account'] == genesis['account'] &&
        backup['publicKey'] == genesis['recoveryKey'] &&
        backup['rootFingerprint'] == spkiFingerprint(firstDevice['signingKey'] as String),
        'Wrong recovery package');
    final salt = unb64(backup['salt'] as String, 32);
    final key = pbkdf2Sha256(passphrase, salt);
    final oldAad = Uint8List.fromList(utf8.encode(jsonEncode([
      'shade-recovery:v2', backup['account'], backup['rootFingerprint'], backup['publicKey']
    ])));
    final der = aesGcmDecrypt(key, unb64(backup['iv'] as String, 24), oldAad,
        unb64(backup['ciphertext'] as String, 8000));
    final genesisDigest = sha256Hex(genesisText(genesis));
    final iv = randomBytes(12);
    final aad = Uint8List.fromList(utf8.encode(jsonEncode([
      'shade-recovery:v2', backup['account'], backup['rootFingerprint'],
      backup['publicKey'], genesisDigest
    ])));
    try {
      return {
        ...backup,
        'genesisDigest': genesisDigest,
        'iv': base64.encode(iv),
        'ciphertext': base64.encode(aesGcmEncrypt(key, iv, aad, der))
      };
    } finally {
      der.fillRange(0, der.length, 0);
      key.fillRange(0, key.length, 0);
    }
  }

  /// Разблокировка recovery-ключа; возвращает PEM для подписи каталогов.
  Future<String> unlockRecoveryBackup(Map<String, dynamic> backup,
      String passphrase, Map<String, dynamic> genesis) async {
    final firstDevice = genesis['firstDevice'] as Map<String, dynamic>;
    check(backup['version'] == 2 &&
        backup['account'] == genesis['account'] &&
        backup['publicKey'] == genesis['recoveryKey'] &&
        backup['rootFingerprint'] == spkiFingerprint(firstDevice['signingKey'] as String),
        'Recovery identity mismatch');
    check(backup['genesisDigest'] == sha256Hex(genesisText(genesis)),
        'Recovery backup must pin the exact account genesis');
    final salt = unb64(backup['salt'] as String, 32), iv = unb64(backup['iv'] as String, 24);
    check(salt.length == 16 && iv.length == 12);
    final aad = Uint8List.fromList(utf8.encode(jsonEncode([
      'shade-recovery:v2', backup['account'], backup['rootFingerprint'],
      backup['publicKey'], backup['genesisDigest']
    ])));
    final key = pbkdf2Sha256(passphrase, salt);
    final der = aesGcmDecrypt(key, iv, aad, unb64(backup['ciphertext'] as String, 8000));
    try {
      final pem = pkcs8DerToPem(base64.encode(der));
      final probe = base64.encode(randomBytes(32));
      final signature = await crypto.signData(probe, pem);
      check(await verifier.verify(probe, signature, backup['publicKey'] as String),
          'Recovery key validation failed');
      return pem;
    } finally {
      der.fillRange(0, der.length, 0);
      key.fillRange(0, key.length, 0);
    }
  }

  /// Genesis для legacy-миграции: исходный RSA остаётся primary-якорем.
  Map<String, dynamic> buildLegacyGenesis(
      String account, String rootSpki, String recoveryKey,
      {int? now}) {
    now ??= DateTime.now().millisecondsSinceEpoch;
    return {
      'version': 2,
      'account': account,
      'nonce': randomHex(32),
      'createdAt': now,
      'legacy': true,
      'firstDevice': {'id': 'primary', 'encryptionKey': rootSpki, 'signingKey': rootSpki},
      'recoveryKey': recoveryKey,
      'signature': ''
    };
  }

  /// Новый независимый RSA-4096 якорь для rotation. Secure storage v1-ключа
  /// НЕ трогается: старый ключ остаётся для v1-режима и расшифровки истории.
  /// Приватная часть никогда не покидает устройство.
  Future<Map<String, String>> generateAnchorKey() async {
    final pair = await RSA.generate(4096);
    return {
      'publicKey': await publicSpki(pair.publicKey),
      'privateKey': pair.privateKey
    };
  }

  /// Начальный каталог (revision 1) для legacy-аккаунта.
  Map<String, dynamic> buildLegacyManifest(String account, String rootSpki,
      {int? now}) {
    now ??= DateTime.now().millisecondsSinceEpoch;
    return {
      'account': account,
      'rootFingerprint': spkiFingerprint(rootSpki),
      'revision': 1,
      'previous': '',
      'issuedAt': now,
      'expiresAt': now + maxLeaseMs,
      'devices': [
        {'id': 'primary', 'encryptionKey': rootSpki, 'signingKey': rootSpki}
      ],
      'signer': 'primary',
      'signature': ''
    };
  }

  /// Свежая подпись владения для добавления нового устройства.
  Future<Map<String, dynamic>> pairingProof(DeviceV2Session session, {int? now}) async {
    now ??= DateTime.now().millisecondsSinceEpoch;
    final nonce = randomHex(32);
    final expiresAt = now + 60000;
    return {
      'id': session.id,
      'nonce': nonce,
      'expiresAt': expiresAt,
      'signature': await crypto.signData(
          pairingText(session.account, session.descriptor, nonce, expiresAt),
          session.signingPrivateKey)
    };
  }
}