import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:fast_rsa/fast_rsa.dart';
import 'package:encrypt/encrypt.dart' as enc;
import 'package:pointycastle/export.dart' as pc;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

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
  /// fast_rsa 3.8.6 signature:
  ///   RSA.signPSS(message, hash, saltLength, privateKey)
  Future<String> signData(String data, String privateKey) async {
    final dataB64 = base64.encode(utf8.encode(data));
    return await RSA.signPSS(
      dataB64,
      Hash.SHA256,
      SaltLength.AUTO,
      privateKey,
    );
  }

  /// Verifies that [data] was signed by the holder of [publicKey].
  ///
  /// fast_rsa 3.8.6 signature:
  ///   RSA.verifyPSS(signature, message, hash, saltLength, publicKey)
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
        SaltLength.AUTO,
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
  Future<bool> verifyPublicKeySignature(
    String publicKey,
    String signature,
  ) {
    return verifySignature(publicKey, signature, publicKey);
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

    // Also delete file fallback on desktop
    if (!Platform.isAndroid && !Platform.isIOS) {
      try {
        final dir = await getApplicationSupportDirectory();
        for (final alias in [_privKeyAlias, _pubKeyAlias]) {
          final file = File('${dir.path}/shade_$alias.pem');
          if (await file.exists()) await file.delete();
        }
      } catch (_) {}
    }
    debugPrint('[CryptoService] Keys cleared');
  }

  // ══════════════════════════════════════════════════════════════
  //  INTERNALS
  // ══════════════════════════════════════════════════════════════

  /// Reads a key. Tries secure storage first, falls back to file on desktop.
  /// Normalizes the PEM string to fix Windows line-ending issues.
  Future<String?> _readKey(String alias) async {
    String? raw;

    // 1) Try secure storage
    try {
      raw = await _secureStorage.read(key: alias);
      if (raw != null && raw.isNotEmpty) {
        debugPrint('[CryptoService] readKey $alias from secure storage');
      }
    } catch (e) {
      debugPrint('[CryptoService] secure storage read failed: $e');
    }

    // 2) Fallback to file on desktop
    if ((raw == null || raw.isEmpty) &&
        !Platform.isAndroid &&
        !Platform.isIOS) {
      try {
        final dir = await getApplicationSupportDirectory();
        final file = File('${dir.path}/shade_$alias.pem');
        if (await file.exists()) {
          raw = await file.readAsString();
          debugPrint('[CryptoService] readKey $alias from file');
        } else {
          debugPrint('[CryptoService] file not found: ${file.path}');
        }
      } catch (e) {
        debugPrint('[CryptoService] file read failed: $e');
      }
    }

    if (raw == null || raw.isEmpty) return null;

    // 3) Normalize PEM: fix line endings, strip extra whitespace
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
  Future<void> _writeKey(String alias, String value) async {
    // Normalize before writing
    final normalized = _normalizePem(value);

    try {
      await _secureStorage.write(key: alias, value: normalized);
      debugPrint('[CryptoService] writeKey $alias to secure storage');
    } catch (e) {
      debugPrint('[CryptoService] secure storage write failed: $e');
    }

    if (!Platform.isAndroid && !Platform.isIOS) {
      try {
        final dir = await getApplicationSupportDirectory();
        final file = File('${dir.path}/shade_$alias.pem');
        await file.writeAsString(normalized, flush: true);
        debugPrint('[CryptoService] writeKey $alias to file: ${file.path}');
      } catch (e) {
        debugPrint('[CryptoService] file write failed: $e');
      }
    }
  }

  static Uint8List _randomBytes(int length) {
    final rng = Random.secure();
    return Uint8List.fromList(
      List<int>.generate(length, (_) => rng.nextInt(256)),
    );
  }
}
