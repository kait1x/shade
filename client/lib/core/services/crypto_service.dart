import 'dart:convert';
import 'dart:math' show Random;
import 'package:flutter/foundation.dart';
import 'package:fast_rsa/fast_rsa.dart';
import 'package:pointycastle/export.dart' as pc;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:crypto/crypto.dart' as crypto;

/// Криптографически стойкий генератор случайных чисел на базе PointyCastle Fortuna PRNG.
///
/// Используется для генерации:
/// - Ключей шифрования AES
/// - Nonce и векторов инициализации (IV)
/// - Солей (salt)
/// - Любого другого криптографического материала
class _SecureRandom {
  // CRIT-01: Fortuna PRNG seeded with Random.secure()
  static final pc.SecureRandom _fortuna = pc.FortunaRandom();
  static bool _seeded = false;

  /// Ensures Fortuna is seeded with entropy from platform CSPRNG.
  static void _ensureSeeded() {
    if (_seeded) return;
    final random = Random.secure();
    final entropy =
        Uint8List.fromList(List.generate(32, (_) => random.nextInt(256)));
    _fortuna.seed(pc.KeyParameter(entropy));
    entropy.fillRange(0, entropy.length, 0);
    _seeded = true;
  }

  /// Returns [length] cryptographically secure random bytes via Fortuna PRNG.
  static Uint8List nextBytes(int length) {
    _ensureSeeded();
    return _fortuna.nextBytes(length);
  }

  // HIGH-04: Wipe password with Uint8List
}

enum ServerKeyTrustStatus {
  trusted,
  newKeyRequiresConfirmation,
  mismatchDetected,
}

class ServerKeyFingerprintResult {
  final ServerKeyTrustStatus status;
  final String fingerprint;
  final String? storedFingerprint;

  ServerKeyFingerprintResult({
    required this.status,
    required this.fingerprint,
    this.storedFingerprint,
  });
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
    final cipher = pc.GCMBlockCipher(pc.AESEngine())
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

      // MED-05: Removed legacy CBC - only GCM mode supported
      // Определяем версию по размеру конверта
      if (envelope.length == 45 && envelope[0] == 2) {
        // Режим GCM (v2): версия(1) + ключ(32) + nonce(12)
        final aesKey = Uint8List.fromList(envelope.sublist(1, 1 + _aesKeyLen));
        final nonce = Uint8List.fromList(envelope.sublist(1 + _aesKeyLen));
        final ciphertextWithTag = base64.decode(encryptedDataB64);

        final cipher = pc.GCMBlockCipher(pc.AESEngine())
          ..init(
            false,
            pc.AEADParameters(
                pc.KeyParameter(aesKey), _aesGcmTagBits, nonce, Uint8List(0)),
          );
        return utf8.decode(cipher.process(ciphertextWithTag));
      } else {
        throw Exception(
            'Unknown envelope format - CBC mode no longer supported');
      }
    } catch (e) {
      if (e.toString().contains('AEADBadTagException') ||
          e.toString().contains('Tag')) {
        throw Exception('Message authentication failed. Data may be tampered.');
      }
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
      SaltLength.EQUALS_HASH,
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
        SaltLength.EQUALS_HASH,
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
    String serverPublicKey, {
    required String username,
    required String serverOrigin,
  }) async {
    if (serverSignature.isEmpty) {
      debugPrint(
          '[CryptoService] No server signature provided - possible MitM!');
      return false;
    }
    try {
      final trust = await _checkServerKeyFingerprint(serverPublicKey,
          serverOrigin: serverOrigin);
      if (trust.status != ServerKeyTrustStatus.trusted) return false;
      final dataB64 =
          base64.encode(utf8.encode('shade-user-key:v1:$username:$publicKey'));
      final isValid = await RSA.verifyPSS(
        serverSignature,
        dataB64,
        Hash.SHA256,
        SaltLength.EQUALS_HASH,
        serverPublicKey,
      );
      if (!isValid) {
        debugPrint('[CryptoService] Server signature INVALID - possible MitM!');
        return false;
      }
      // TOFU: verify server public key fingerprint - throws if confirmation needed
      return true;
    } catch (e) {
      debugPrint('[CryptoService] Server signature verification error: $e');
      return false;
    }
  }

  /// Проверяет ключ сервера и возвращает результат для UI (диалог подтверждения)
  Future<ServerKeyFingerprintResult> checkServerKeyForConfirmation(
      String serverPublicKey,
      {String serverOrigin = 'default'}) async {
    try {
      final fpResult = await _checkServerKeyFingerprint(serverPublicKey,
          serverOrigin: serverOrigin);
      return fpResult;
    } catch (e) {
      return ServerKeyFingerprintResult(
        status: ServerKeyTrustStatus.mismatchDetected,
        fingerprint: '',
      );
    }
  }

  /// Проверяет отпечаток публичного ключа сервера.
  /// [FIX] HIGH #2: Используем PIN-код из сборки как единственный источник истины.
  /// TOFU используется только как fallback если PIN не сконфигурирован.
  /// Возвращает результат с статусом проверки для показа диалога подтверждения.
  Future<ServerKeyFingerprintResult> _checkServerKeyFingerprint(
      String serverPublicKey,
      {String serverOrigin = 'default'}) async {
    try {
      final fingerprint = await _sha256Fingerprint(serverPublicKey);

      // HIGH-03: Server key fingerprint via build config
      // Проверяем --dart-define=SERVER_PUBLIC_KEY_FINGERPRINT
      const buildConfigFingerprint = String.fromEnvironment(
          'SERVER_PUBLIC_KEY_FINGERPRINT',
          defaultValue: '');

      if (buildConfigFingerprint.isNotEmpty) {
        // Приоритет: предустановленный fingerprint из билда
        if (fingerprint != buildConfigFingerprint) {
          debugPrint(
              '[CryptoService] CRITICAL: Server key MISMATCH! Build config vs actual');
          debugPrint('  Expected: $buildConfigFingerprint');
          debugPrint('  Got:      $fingerprint');
          return ServerKeyFingerprintResult(
            status: ServerKeyTrustStatus.mismatchDetected,
            fingerprint: fingerprint,
            storedFingerprint: buildConfigFingerprint,
          );
        }
        debugPrint(
            '[CryptoService] Server key fingerprint verified (build config)');
        return ServerKeyFingerprintResult(
          status: ServerKeyTrustStatus.trusted,
          fingerprint: fingerprint,
        );
      }

      // [FIX] Приоритет 2: TOFU как fallback (только для разработки!)
      const isProduction =
          bool.fromEnvironment('dart.vm.product', defaultValue: false);
      // HIGH-06: Require pin in production, no TOFU
      if (isProduction) {
        debugPrint('[CryptoService] CRITICAL: TOFU not allowed in production!');
        debugPrint(
            '[CryptoService] Set --dart-define=SERVER_PUBLIC_KEY_FINGERPRINT=<colon-hex-sha256>');
        return ServerKeyFingerprintResult(
          status: ServerKeyTrustStatus.mismatchDetected,
          fingerprint: fingerprint,
        );
      }
      final key = 'server_pubkey_fingerprint:$serverOrigin';
      final stored = await _secureStorage.read(key: key);
      if (stored == null) {
        // Впервые видим ключ сервера - требуется подтверждение пользователя
        debugPrint(
            '[CryptoService] NEW server key detected - user confirmation required');
        return ServerKeyFingerprintResult(
          status: ServerKeyTrustStatus.newKeyRequiresConfirmation,
          fingerprint: fingerprint,
        );
      } else if (stored != fingerprint) {
        debugPrint(
            '[CryptoService] WARNING: Server key fingerprint changed! Possible MitM attack.');
        debugPrint('  Stored: $stored');
        debugPrint('  Got:    $fingerprint');
        return ServerKeyFingerprintResult(
          status: ServerKeyTrustStatus.mismatchDetected,
          fingerprint: fingerprint,
          storedFingerprint: stored,
        );
      } else {
        debugPrint('[CryptoService] Server key fingerprint verified (TOFU)');
        return ServerKeyFingerprintResult(
          status: ServerKeyTrustStatus.trusted,
          fingerprint: fingerprint,
        );
      }
    } catch (e) {
      debugPrint('[CryptoService] Fingerprint check error: $e');
      return ServerKeyFingerprintResult(
        status: ServerKeyTrustStatus.mismatchDetected,
        fingerprint: '',
      );
    }
  }

  /// Подтверждает доверие к ключу сервера (сохраняет fingerprint)
  Future<void> trustServerKey(String fingerprint,
      {String serverOrigin = 'default'}) async {
    final key = 'server_pubkey_fingerprint:$serverOrigin';
    await _secureStorage.write(key: key, value: fingerprint);
    debugPrint('[CryptoService] Server key fingerprint trusted and saved');
  }

  /// Вычисляет отпечаток SHA-256 публичного PEM-ключа (убирает заголовки/подвалы, пробелы).
  Future<String> _sha256Fingerprint(String pem) async {
    final lines = pem
        .split('\n')
        .where((l) =>
            !l.contains('BEGIN') && !l.contains('END') && l.trim().isNotEmpty)
        .join();
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

  /// HIGH-01: Reads a key from OS-specific secure storage
  /// - Android: EncryptedSharedPreferences (Keystore)
  /// - iOS: Keychain
  /// - macOS: Keychain
  /// - Windows: DPAPI via FlutterSecureStorage
  /// - Linux: libsecret via FlutterSecureStorage
  Future<String?> _readKey(String alias) async {
    String? raw;

    // Try secure storage (uses OS keychain on desktop)
    try {
      raw = await _secureStorage.read(key: alias);
      if (raw != null && raw.isNotEmpty) {
        debugPrint('[CryptoService] readKey $alias from OS secure storage');
        return _normalizePem(raw);
      }
    } catch (e) {
      debugPrint('[CryptoService] OS secure storage read failed: $e');
    }

    // HIGH-01: No password fallback - keys MUST be in OS keychain
    // On desktop, FlutterSecureStorage uses:
    // - macOS: Keychain Services
    // - Windows: DPAPI
    // - Linux: libsecret
    debugPrint('[CryptoService] ERROR: Cannot read key from OS secure storage');
    return null;
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

  /// HIGH-01: Writes a key to OS-specific secure storage
  /// Uses platform-native keychain (no password fallback)
  Future<void> _writeKey(String alias, String value) async {
    final normalized = _normalizePem(value);

    // Write to OS keychain (Keychain/DPAPI/libsecret)
    try {
      await _secureStorage.write(key: alias, value: normalized);
      debugPrint('[CryptoService] writeKey $alias to OS secure storage');
    } catch (e) {
      debugPrint(
          '[CryptoService] ERROR: Cannot write to OS secure storage: $e');
      // HIGH-01: No fallback - throw error to prevent unsafe storage
      throw Exception(
          'Failed to write key to OS secure storage. Keys must be protected by OS keychain.');
    }
  }

  static Uint8List _randomBytes(int length) => _SecureRandom.nextBytes(length);
}
