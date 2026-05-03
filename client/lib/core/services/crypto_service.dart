import 'dart:convert';
import 'dart:io';
import 'dart:math' show Random;
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:fast_rsa/fast_rsa.dart';
import 'package:encrypt/encrypt.dart' as enc;
import 'package:pointycastle/export.dart' as pc;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:crypto/crypto.dart' as crypto;

/// Криптографически стойкий генератор случайных чисел на базе PointyCastle Fortuna PRNG.
/// 
/// Используется для генерации:
/// - Ключей шифрования AES
/// - Nonce и векторов инициализации (IV)
/// - Солей (salt)
/// - Любого другого криптографического материала
class _SecureRandom {
  static final pc.FortunaRandom _random = pc.FortunaRandom();
  static bool _seeded = false;

  /// Инициализирует PRNG, собирая энтропию из нескольких источников.
  /// 
  /// Должно вызываться перед первым использованием для корректной инициализации.
  static void _ensureSeeded() {
    if (_seeded) return;
    
    // Собираем энтропию из нескольких источников
    final entropySources = <Uint8List>[];
    
    // Источник 1: Текущее время с высокой точностью
    final timeBytes = Uint8List(8);
    final timeValue = DateTime.now().microsecondsSinceEpoch;
    for (int i = 0; i < 8; i++) {
      timeBytes[i] = (timeValue >> (i * 8)) & 0xFF;
    }
    entropySources.add(timeBytes);
    
    // Источник 2: Счётчик производительности (если доступен)
    try {
      final perfBytes = Uint8List(8);
      final perfValue = Stopwatch.getTimestamp();
      for (int i = 0; i < 8; i++) {
        perfBytes[i] = (perfValue >> (i * 8)) & 0xFF;
      }
      entropySources.add(perfBytes);
    } catch (_) {}
    
    // Источник 3: Random.secure() как дополнительная энтропия (не единственный источник)
    try {
      final dartRandomBytes = Uint8List(32);
      for (int i = 0; i < 32; i++) {
        dartRandomBytes[i] = (Random.secure().nextInt(256)) & 0xFF;
      }
      entropySources.add(dartRandomBytes);
    } catch (_) {}
    
    // Объединяем все источники энтропии
    final combinedLength = entropySources.fold<int>(0, (sum, list) => sum + list.length);
    final seed = Uint8List(combinedLength);
    int offset = 0;
    for (final source in entropySources) {
      seed.setRange(offset, offset + source.length, source);
      offset += source.length;
    }
    
    _random.seed(pc.KeyParameter(seed));
    _seeded = true;
  }

  /// Генерирует [length] криптографически стойких случайных байт.
  static Uint8List nextBytes(int length) {
    _ensureSeeded();
    final result = Uint8List(length);
    for (int i = 0; i < length; i++) {
      result[i] = _random.nextUint8();
    }
    return result;
  }
}

/// Сервис гибридного шифрования RSA-4096 + AES-256-GCM.
///
/// Соответствует API fast_rsa 3.8.6:
///   RSA.generate(bits) → KeyPair
///   RSA.encryptOAEP(message, label, hash, publicKey)
///   RSA.decryptOAEP(ciphertext, label, hash, privateKey)
///   RSA.signPSS(message, hash, saltLength, privateKey)
///   RSA.verifyPSS(signature, message, hash, saltLength, publicKey)
class CryptoService {
  final FlutterSecureStorage _secureStorage;

  static const String _privKeyAlias = 'rsa_private_key';
  static const String _pubKeyAlias = 'rsa_public_key';

  static const int _aesKeyLen = 32;
  static const int _aesNonceLen = 12; // GCM nonce
  static const int _aesGcmTagBits = 128; // 16-byte auth tag

  CryptoService({FlutterSecureStorage? storage})
      : _secureStorage = storage ??
            const FlutterSecureStorage(
              aOptions: AndroidOptions(encryptedSharedPreferences: true),
            );

  // ══════════════════════════════════════════════════════════════
  //  KEY GENERATION
  // ══════════════════════════════════════════════════════════════

  /// Генерирует пару RSA-4096 ключей и сохраняет обе части.
  Future<Map<String, String>> generateIdentityKeys() async {
    final kp = await RSA.generate(4096);

    await Future.wait([
      _writeKey(_privKeyAlias, kp.privateKey),
      _writeKey(_pubKeyAlias, kp.publicKey),
    ]);

    debugPrint('[CryptoService] Identity keys generated');
    return {'publicKey': kp.publicKey, 'privateKey': kp.privateKey};
  }

  /// Очищает все ключи идентификации из защищённого хранилища.
  /// 
  /// Должно вызываться при выходе из системы для удаления криптографического
  /// материала с устройства. После вызова пользователь должен заново
  /// сгенерировать ключи для использования приложения.
  Future<void> clearIdentityKeys() async {
    await Future.wait([
      _secureStorage.delete(key: _privKeyAlias),
      _secureStorage.delete(key: _pubKeyAlias),
    ]);
    debugPrint('[CryptoService] Identity keys cleared from secure storage');
  }

  // ══════════════════════════════════════════════════════════════
  //  ГИБРИДНОЕ ШИФРОВАНИЕ  —  encryptData / decryptData
  // ══════════════════════════════════════════════════════════════

  /// Шифрует [plainText] для владельца [publicKey].
  ///
  /// 1. Генерирует случайный AES-256 ключ (32 байта) + nonce (12 байт).
  /// 2. Шифрует открытый текст с помощью AES-256-GCM (с аутентификацией).
  /// 3. Шифрует конверт (ключ+nonce) с помощью RSA-OAEP-SHA256.
  /// 4. Возвращает `{"k":"<зашифрованный ключ>","d":"<зашифрованные данные+тег>"}`.
  Future<String> encryptData(String plainText, String publicKey) async {
    final aesKey = _randomBytes(_aesKeyLen);
    final nonce = _randomBytes(_aesNonceLen);

    // AES-256-GCM шифрование (включает 16-байтный тег аутентификации)
    final plainBytes = Uint8List.fromList(utf8.encode(plainText));
    final cipher = pc.GCMBlockCipher(pc.AESFastEngine())
      ..init(
        true,
        pc.AEADParameters(
            pc.KeyParameter(aesKey), _aesGcmTagBits, nonce, Uint8List(0)),
      );
    final encryptedWithTag = cipher.process(plainBytes);

    // Упаковываем конверт: версия(2) + ключ(32) + nonce(12) = 45 байт
    final envelope = Uint8List(1 + _aesKeyLen + _aesNonceLen)
      ..[0] = 2
      ..setRange(1, 1 + _aesKeyLen, aesKey)
      ..setRange(1 + _aesKeyLen, 1 + _aesKeyLen + _aesNonceLen, nonce);

    // RSA-OAEP-SHA256 шифрование конверта
    final encryptedKey = await RSA.encryptOAEP(
      base64.encode(envelope),
      '',
      Hash.SHA256,
      publicKey,
    );

    return jsonEncode(
        {'k': encryptedKey, 'd': base64.encode(encryptedWithTag)});
  }

  /// Расшифровывает данные, полученные от [encryptData].
  ///
  /// Поддерживает как AES-256-GCM (v2), так и устаревшее AES-256-CBC (v1).
  Future<String> decryptData(String encryptedPayload, String privateKey) async {
    final map = jsonDecode(encryptedPayload) as Map<String, dynamic>;
    final encryptedKey = map['k'] as String;
    final encryptedDataB64 = map['d'] as String;

    try {
      // RSA-OAEP-SHA256 расшифровка конверта
      final envelopeB64 = await RSA.decryptOAEP(
        encryptedKey,
        '',
        Hash.SHA256,
        privateKey,
      );
      final envelope = base64.decode(envelopeB64);

      // Определяем версию по размеру конверта
      if (envelope.length == 45 && envelope[0] == 2) {
        // Режим GCM (v2): версия(1) + ключ(32) + nonce(12)
        final aesKey = Uint8List.fromList(envelope.sublist(1, 1 + _aesKeyLen));
        final nonce = Uint8List.fromList(envelope.sublist(1 + _aesKeyLen));
        final ciphertextWithTag = base64.decode(encryptedDataB64);

        final cipher = pc.GCMBlockCipher(pc.AESFastEngine())
          ..init(
            false,
            pc.AEADParameters(
                pc.KeyParameter(aesKey), _aesGcmTagBits, nonce, Uint8List(0)),
          );
        return utf8.decode(cipher.process(ciphertextWithTag));
      } else if (envelope.length == 48) {
        // CBC mode (v1, legacy): key(32) + iv(16)
        final aesKey =
            enc.Key(Uint8List.fromList(envelope.sublist(0, _aesKeyLen)));
        final iv = enc.IV(Uint8List.fromList(envelope.sublist(_aesKeyLen)));
        final encrypter = enc.Encrypter(enc.AES(aesKey, mode: enc.AESMode.cbc));
        return encrypter.decrypt64(encryptedDataB64, iv: iv);
      } else {
        throw Exception('Unknown envelope format');
      }
    } catch (e) {
      debugPrint('[CryptoService] decryptData FAILED');
      rethrow;
    }
  }

  // ══════════════════════════════════════════════════════════════
  //  DIGITAL SIGNATURES  —  signData / verifySignature
  // ══════════════════════════════════════════════════════════════

  /// Подписывает [data] с помощью [privateKey] используя RSA-PSS-SHA256.
  ///
  /// Использует явную длину соли 32 байта согласно RFC 8017.
  Future<String> signData(String data, String privateKey) async {
    final dataB64 = base64.encode(utf8.encode(data));
    return await RSA.signPSS(
      dataB64,
      Hash.SHA256,
      const SaltLength(32), // Explicit 32-byte salt per RFC 8017
      privateKey,
    );
  }

  /// Проверяет, что [data] был подписан владельцем [publicKey].
  ///
  /// Использует явную длину соли 32 байта согласно RFC 8017.
  Future<bool> verifySignature(
    String data,
    String signature,
    String publicKey,
  ) async {
    try {
      final dataB64 = base64.encode(utf8.encode(data));
      return await RSA.verifyPSS(
        signature,
        dataB64,
        Hash.SHA256,
        const SaltLength(32), // Must match signData salt length
        publicKey,
      );
    } catch (_) {
      return false;
    }
  }

  // ══════════════════════════════════════════════════════════════
  //  CONVENIENCE WRAPPERS (key ownership proofs)
  // ══════════════════════════════════════════════════════════════

  /// Подписывает сохранённый публичный ключ для регистрации на сервере.
  Future<String> signPublicKey() async {
    final priv = await _readKey(_privKeyAlias);
    final pub = await _readKey(_pubKeyAlias);
    if (priv == null || pub == null) {
      throw StateError('Identity keys not found');
    }
    return signData(pub, priv);
  }

  /// Проверяет, что публичный ключ был подписан мастер-ключом сервера.
  ///
  /// [publicKey] — публичный ключ пользователя.
  /// [serverSignature] — подпись публичного ключа мастер-ключом сервера.
  /// [serverPublicKey] — мастер-ключ сервера (публичная часть).
  ///
  /// Также реализует TOFU: сохраняет отпечаток SHA-256 публичного ключа сервера
  /// при первом использовании, предупреждает при изменении.
  Future<bool> verifyPublicKeySignature(
    String publicKey,
    String serverSignature,
    String serverPublicKey,
  ) async {
    if (serverSignature == null || serverSignature.isEmpty) {
      debugPrint('[CryptoService] No server signature provided - possible MitM!');
      return false;
    }
    try {
      final dataB64 = base64.encode(utf8.encode(publicKey));
      final isValid = await RSA.verifyPSS(
        serverSignature,
        dataB64,
        Hash.SHA256,
        const SaltLength(32),
        serverPublicKey,
      );
      if (!isValid) {
        debugPrint('[CryptoService] Server signature INVALID - possible MitM!');
        return false;
      }
      // TOFU: verify server public key fingerprint
      await _checkServerKeyFingerprint(serverPublicKey);
      return true;
    } catch (e) {
      debugPrint('[CryptoService] Server signature verification error: $e');
      return false;
    }
  }

  /// Проверяет отпечаток публичного ключа сервера с сохранённым значением (TOFU).
  Future<void> _checkServerKeyFingerprint(String serverPublicKey) async {
    try {
      final fingerprint = await _sha256Fingerprint(serverPublicKey);
      const storage = FlutterSecureStorage();
      const key = 'server_pubkey_fingerprint';
      final stored = await storage.read(key: key);
      if (stored == null) {
        // Впервые видим ключ сервера - сохраняем отпечаток
        await storage.write(key: key, value: fingerprint);
        debugPrint('[CryptoService] Server key fingerprint stored (TOFU)');
      } else if (stored != fingerprint) {
        debugPrint('[CryptoService] WARNING: Server key fingerprint changed! Possible MitM attack.');
        // In production, you might want to notify user or block
      } else {
        debugPrint('[CryptoService] Server key fingerprint verified');
      }
    } catch (e) {
      debugPrint('[CryptoService] TOFU check error: $e');
    }
  }

  /// Вычисляет отпечаток SHA-256 публичного PEM-ключа (убирает заголовки/подвалы, пробелы).
  Future<String> _sha256Fingerprint(String pem) async {
    final lines = pem.split('\n').where((l) => !l.contains('BEGIN') && !l.contains('END') && l.trim().isNotEmpty).join();
    final bytes = base64.decode(lines);
    final hash = crypto.sha256.convert(bytes);
    return hash.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(':');
  }

  // ══════════════════════════════════════════════════════════════
  //  ALIASES (backward compatibility)
  // ══════════════════════════════════════════════════════════════

  /// Alias for [encryptData]. Reads recipient key from argument.
  Future<String> encryptMessage(String text, String recipientPublicKey) =>
      encryptData(text, recipientPublicKey);

  /// Alias for [decryptData]. Falls back to stored private key.
  Future<String> decryptMessage(
    String encryptedPayload, {
    String? myPrivateKey,
  }) async {
    final key = myPrivateKey ?? await getPrivateKey();
    if (key == null) throw StateError('Private key not found');
    return decryptData(encryptedPayload, key);
  }

  // ══════════════════════════════════════════════════════════════
  //  KEY ACCESSORS
  // ══════════════════════════════════════════════════════════════

  Future<String?> getPublicKey() => _readKey(_pubKeyAlias);
  Future<String?> getPrivateKey() => _readKey(_privKeyAlias);

  Future<bool> hasIdentityKeys() async {
    final pub = await _readKey(_pubKeyAlias);
    return pub != null && pub.isNotEmpty;
  }

  Future<void> clearKeys() async {
    try {
      await Future.wait([
        _secureStorage.delete(key: _privKeyAlias),
        _secureStorage.delete(key: _pubKeyAlias),
      ]);
    } catch (_) {}

    // REMOVED: Desktop file deletion (no longer writing plaintext files)
    debugPrint('[CryptoService] Keys cleared from secure storage');
  }

  // ══════════════════════════════════════════════════════════════
  //  INTERNALS
  // ══════════════════════════════════════════════════════════════

  /// Reads a key from secure storage.
  ///
  /// SECURITY: No fallback to plaintext files on desktop. Keys must be stored
  /// in OS-protected secure storage (Keychain/Keystore/DPAPI).
  Future<String?> _readKey(String alias) async {
    String? raw;

    // Try secure storage ONLY - no plaintext file fallback
    try {
      raw = await _secureStorage.read(key: alias);
      if (raw != null && raw.isNotEmpty) {
        debugPrint('[CryptoService] readKey $alias from secure storage');
      }
    } catch (e) {
      debugPrint('[CryptoService] secure storage read failed: $e');
    }

    if (raw == null || raw.isEmpty) return null;

    // Normalize PEM: fix line endings, strip extra whitespace
    return _normalizePem(raw);
  }

  /// Fixes common PEM corruption from secure storage on Windows:
  /// - Strips BOM, trailing whitespace
  /// - Normalizes \r\n → \n
  /// - Ensures PEM headers are present
  String _normalizePem(String raw) {
    var pem = raw.trim();

    // Strip BOM if present
    if (pem.startsWith('\uFEFF')) {
      pem = pem.substring(1);
    }

    // Normalize line endings
    pem = pem.replaceAll('\r\n', '\n').replaceAll('\r', '\n');

    // Strip trailing whitespace from each line
    pem = pem.split('\n').map((l) => l.trimRight()).join('\n');

    // Ensure there's exactly one trailing newline
    pem = '${pem.trimRight()}\n';

    return pem;
  }

  /// Writes a key to secure storage and file fallback.
  ///
  /// SECURITY: On desktop platforms (Windows/macOS/Linux), private keys are
  /// NOT written to files in plain text. They are ONLY stored in secure storage.
  /// If secure storage fails on desktop, the key is lost (safer than plaintext).
  Future<void> _writeKey(String alias, String value) async {
    // Normalize before writing
    final normalized = _normalizePem(value);

    try {
      await _secureStorage.write(key: alias, value: normalized);
      debugPrint('[CryptoService] writeKey $alias to secure storage');
    } catch (e) {
      debugPrint('[CryptoService] secure storage write failed: $e');
      // On desktop, if secure storage fails, we do NOT fall back to plaintext files
      if (!Platform.isAndroid && !Platform.isIOS) {
        throw Exception(
          'Secure storage unavailable on desktop. Cannot safely store keys. '
          'Please ensure your OS keychain/keystore is accessible.',
        );
      }
    }

    // REMOVED: Desktop plaintext file fallback (security vulnerability)
    // Private keys must NEVER be stored in plaintext on disk.
    // On desktop, secure storage (Keychain/DPAPI/libsecret) is mandatory.
  }

  /// Generates cryptographically secure random bytes using PointyCastle Fortuna.
  static Uint8List _randomBytes(int length) {
    return _SecureRandom.nextBytes(length);
  }
}
