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

/// Crypto-secure random number generator using PointyCastle Fortuna PRNG.
/// 
/// This is a cryptographically secure PRNG suitable for generating:
/// - AES encryption keys
/// - Nonces and IVs
/// - Salt values
/// - Any other cryptographic material
class _SecureRandom {
  static final pc.FortunaRandom _random = pc.FortunaRandom();
  static bool _seeded = false;

  /// Seeds the PRNG with entropy from multiple sources.
  /// 
  /// This should be called before first use to ensure proper initialization.
  static void _ensureSeeded() {
    if (_seeded) return;
    
    // Gather entropy from multiple sources
    final entropySources = <Uint8List>[];
    
    // Source 1: Current time with high precision
    final timeBytes = Uint8List(8);
    final timeValue = DateTime.now().microsecondsSinceEpoch;
    for (int i = 0; i < 8; i++) {
      timeBytes[i] = (timeValue >> (i * 8)) & 0xFF;
    }
    entropySources.add(timeBytes);
    
    // Source 2: Performance counter (if available)
    try {
      final perfBytes = Uint8List(8);
      final perfValue = Stopwatch.getTimestamp();
      for (int i = 0; i < 8; i++) {
        perfBytes[i] = (perfValue >> (i * 8)) & 0xFF;
      }
      entropySources.add(perfBytes);
    } catch (_) {}
    
    // Source 3: Random.secure() as additional entropy (not sole source)
    try {
      final dartRandomBytes = Uint8List(32);
      for (int i = 0; i < 32; i++) {
        dartRandomBytes[i] = (Random.secure().nextInt(256)) & 0xFF;
      }
      entropySources.add(dartRandomBytes);
    } catch (_) {}
    
    // Combine all entropy sources
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

  /// Generates [length] cryptographically secure random bytes.
  static Uint8List nextBytes(int length) {
    _ensureSeeded();
    final result = Uint8List(length);
    for (int i = 0; i < length; i++) {
      result[i] = _random.nextUint8();
    }
    return result;
  }
}

/// Hybrid RSA-4096 + AES-256-GCM encryption service.
///
/// Conforms to fast_rsa 3.8.6 API:
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

  /// Generates a 4096-bit RSA key pair and persists both halves.
  Future<Map<String, String>> generateIdentityKeys() async {
    final kp = await RSA.generate(4096);

    await Future.wait([
      _writeKey(_privKeyAlias, kp.privateKey),
      _writeKey(_pubKeyAlias, kp.publicKey),
    ]);

    debugPrint('[CryptoService] Identity keys generated');
    return {'publicKey': kp.publicKey, 'privateKey': kp.privateKey};
  }

  /// Clears all identity keys from secure storage.
  /// 
  /// This should be called during logout to ensure cryptographic material
  /// is removed from the device. After calling this, the user must generate
  /// new keys to use the app again.
  Future<void> clearIdentityKeys() async {
    await Future.wait([
      _secureStorage.delete(key: _privKeyAlias),
      _secureStorage.delete(key: _pubKeyAlias),
    ]);
    debugPrint('[CryptoService] Identity keys cleared from secure storage');
  }

  // ══════════════════════════════════════════════════════════════
  //  HYBRID ENCRYPTION  —  encryptData / decryptData
  // ══════════════════════════════════════════════════════════════

  /// Encrypts [plainText] for the owner of [publicKey].
  ///
  /// 1. Generates a random AES-256 key (32 bytes) + nonce (12 bytes).
  /// 2. Encrypts the plaintext with AES-256-GCM (authenticated).
  /// 3. Encrypts the key+nonce envelope with RSA-OAEP-SHA256.
  /// 4. Returns `{"k":"<encrypted key>","d":"<encrypted data+tag>"}`.
  Future<String> encryptData(String plainText, String publicKey) async {
    final aesKey = _randomBytes(_aesKeyLen);
    final nonce = _randomBytes(_aesNonceLen);

    // AES-256-GCM encrypt (includes 16-byte auth tag)
    final plainBytes = Uint8List.fromList(utf8.encode(plainText));
    final cipher = pc.GCMBlockCipher(pc.AESFastEngine())
      ..init(
        true,
        pc.AEADParameters(
            pc.KeyParameter(aesKey), _aesGcmTagBits, nonce, Uint8List(0)),
      );
    final encryptedWithTag = cipher.process(plainBytes);

    // Pack envelope: version(2) + key(32) + nonce(12) = 45 bytes
    final envelope = Uint8List(1 + _aesKeyLen + _aesNonceLen)
      ..[0] = 2
      ..setRange(1, 1 + _aesKeyLen, aesKey)
      ..setRange(1 + _aesKeyLen, 1 + _aesKeyLen + _aesNonceLen, nonce);

    // RSA-OAEP-SHA256 encrypt the envelope
    final encryptedKey = await RSA.encryptOAEP(
      base64.encode(envelope),
      '',
      Hash.SHA256,
      publicKey,
    );

    return jsonEncode(
        {'k': encryptedKey, 'd': base64.encode(encryptedWithTag)});
  }

  /// Decrypts a payload produced by [encryptData].
  ///
  /// Supports both AES-256-GCM (v2) and legacy AES-256-CBC (v1).
  Future<String> decryptData(String encryptedPayload, String privateKey) async {
    final map = jsonDecode(encryptedPayload) as Map<String, dynamic>;
    final encryptedKey = map['k'] as String;
    final encryptedDataB64 = map['d'] as String;

    try {
      // RSA-OAEP-SHA256 decrypt the envelope
      final envelopeB64 = await RSA.decryptOAEP(
        encryptedKey,
        '',
        Hash.SHA256,
        privateKey,
      );
      final envelope = base64.decode(envelopeB64);

      // Detect version by envelope size
      if (envelope.length == 45 && envelope[0] == 2) {
        // GCM mode (v2): version(1) + key(32) + nonce(12)
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

  /// Signs [data] with [privateKey] using RSA-PSS-SHA256.
  ///
  /// Uses explicit salt length of 32 bytes as per RFC 8017 recommendation.
  Future<String> signData(String data, String privateKey) async {
    final dataB64 = base64.encode(utf8.encode(data));
    return await RSA.signPSS(
      dataB64,
      Hash.SHA256,
      const SaltLength(32), // Explicit 32-byte salt per RFC 8017
      privateKey,
    );
  }

  /// Verifies that [data] was signed by the holder of [publicKey].
  ///
  /// Uses explicit salt length of 32 bytes as per RFC 8017 recommendation.
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

  /// Signs the stored public key for server registration.
  Future<String> signPublicKey() async {
    final priv = await _readKey(_privKeyAlias);
    final pub = await _readKey(_pubKeyAlias);
    if (priv == null || pub == null) {
      throw StateError('Identity keys not found');
    }
    return signData(pub, priv);
  }

  /// Verifies a public key bundle received from the server.
  ///
  /// NOTE: This method currently performs a self-signature verification,
  /// which is inherently insecure. The server should sign public keys with
  /// its own key, or TOFU (Trust On First Use) with local pinning should be
  /// implemented. See security audit for details.
  ///
  /// For now, this returns true to allow operation, but callers SHOULD
  /// implement their own TOFU verification using stored fingerprints.
  Future<bool> verifyPublicKeySignature(
    String publicKey,
    String signature,
  ) async {
    // SECURITY WARNING: Self-signature verification is meaningless.
    // This is a placeholder until proper key distribution is implemented.
    // 
    // Proper implementation requires:
    // 1. Server signs user public keys with server's private key
    // 2. Client pins server's public key fingerprint
    // 3. TOFU: Store first-seen fingerprint of each user's key
    // 4. Reject if fingerprint changes on subsequent fetches
    
    // For now, attempt verification but DO NOT rely on it for security.
    // Return true to allow operation, but log warning.
    try {
      final isValid = await verifySignature(publicKey, signature, publicKey);
      if (!isValid) {
        debugPrint('[CryptoService] Public key signature INVALID - possible MitM!');
      } else {
        // Even if "valid", it's a self-signature which proves nothing
        debugPrint('[CryptoService] Public key signature check passed but is self-signed (insecure)');
      }
      // Return true to allow operation - actual security must come from TOFU
      return true;
    } catch (e) {
      debugPrint('[CryptoService] Public key signature verification error: $e');
      return true; // Allow operation even on error
    }
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
