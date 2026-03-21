import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:fast_rsa/fast_rsa.dart';
import 'package:encrypt/encrypt.dart' as enc;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Hybrid RSA-4096 + AES-256-CBC encryption service.
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
  static const int _aesIvLen = 16;

  CryptoService({FlutterSecureStorage? storage})
      : _secureStorage =
            storage ??
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
      _secureStorage.write(key: _privKeyAlias, value: kp.privateKey),
      _secureStorage.write(key: _pubKeyAlias, value: kp.publicKey),
    ]);

    debugPrint('[CryptoService] Identity keys generated');
    return {'publicKey': kp.publicKey, 'privateKey': kp.privateKey};
  }

  // ══════════════════════════════════════════════════════════════
  //  HYBRID ENCRYPTION  —  encryptData / decryptData
  // ══════════════════════════════════════════════════════════════

  /// Encrypts [plainText] for the owner of [publicKey].
  ///
  /// 1. Generates a random AES-256 key (32 bytes) + IV (16 bytes).
  /// 2. Encrypts the plaintext with AES-256-CBC.
  /// 3. Encrypts the key+IV envelope with RSA-OAEP-SHA256.
  /// 4. Returns `{"k":"<encrypted key>","d":"<encrypted data>"}`.
  Future<String> encryptData(String plainText, String publicKey) async {
    final aesKey = _randomBytes(_aesKeyLen);
    final iv = _randomBytes(_aesIvLen);

    // AES-256-CBC encrypt the plaintext
    final encrypter = enc.Encrypter(
      enc.AES(enc.Key(aesKey), mode: enc.AESMode.cbc),
    );
    final encryptedData = encrypter.encrypt(plainText, iv: enc.IV(iv));

    // Pack key + iv into a single 48-byte envelope
    final envelope = Uint8List(_aesKeyLen + _aesIvLen)
      ..setRange(0, _aesKeyLen, aesKey)
      ..setRange(_aesKeyLen, _aesKeyLen + _aesIvLen, iv);

    // RSA-OAEP-SHA256 encrypt the envelope
    final encryptedKey = await RSA.encryptOAEP(
      base64.encode(envelope),
      '',            // label (empty)
      Hash.SHA256,
      publicKey,
    );

    return jsonEncode({'k': encryptedKey, 'd': encryptedData.base64});
  }

  /// Decrypts a payload produced by [encryptData].
  ///
  /// [privateKey] — the recipient's RSA private key in PEM format.
  Future<String> decryptData(String encryptedPayload, String privateKey) async {
    final map = jsonDecode(encryptedPayload) as Map<String, dynamic>;
    final encryptedKey = map['k'] as String;
    final encryptedDataB64 = map['d'] as String;

    // RSA-OAEP-SHA256 decrypt the envelope
    final envelopeB64 = await RSA.decryptOAEP(
      encryptedKey,
      '',            // label (empty)
      Hash.SHA256,
      privateKey,
    );
    final envelope = base64.decode(envelopeB64);

    final aesKey = enc.Key(
      Uint8List.fromList(envelope.sublist(0, _aesKeyLen)),
    );
    final iv = enc.IV(
      Uint8List.fromList(envelope.sublist(_aesKeyLen)),
    );

    // AES-256-CBC decrypt the data
    final encrypter = enc.Encrypter(
      enc.AES(aesKey, mode: enc.AESMode.cbc),
    );
    return encrypter.decrypt64(encryptedDataB64, iv: iv);
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
    await Future.wait([
      _secureStorage.delete(key: _privKeyAlias),
      _secureStorage.delete(key: _pubKeyAlias),
    ]);
    debugPrint('[CryptoService] Keys cleared');
  }

  // ══════════════════════════════════════════════════════════════
  //  INTERNALS
  // ══════════════════════════════════════════════════════════════

  Future<String?> _readKey(String alias) =>
      _secureStorage.read(key: alias);

  static Uint8List _randomBytes(int length) {
    final rng = Random.secure();
    return Uint8List.fromList(
      List<int>.generate(length, (_) => rng.nextInt(256)),
    );
  }
}
