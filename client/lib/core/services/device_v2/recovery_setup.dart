import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'protocol.dart';

class DeferredRecoveryPhrase {
  DeferredRecoveryPhrase(String origin, String account)
      : _key = 'v2.recovery-setup.${sha256Hex('$origin\n$account')}';

  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );
  final String _key;

  Future<String?> read() => _storage.read(key: _key);
  Future<void> save(String phrase) => _storage.write(key: _key, value: phrase);
  Future<void> complete() => _storage.delete(key: _key);
}
