/// Связка UI Alpha v2 с device-v2 репозиторием и транспортом.
///
/// Интерфейс отделён от реализации для widget-тестов; реальная реализация
/// переиспользует существующие CryptoService/DatabaseService и изолированный
/// alpha-процесс. Production v1-поток не затрагивается.
library;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/services/crypto_service.dart';
import '../../../core/services/device_v2/crypto.dart';
import '../../../core/services/device_v2/protocol.dart';
import '../../../core/services/device_v2/repository.dart';
import '../../../core/services/device_v2/store.dart';
import '../../../core/services/device_v2/transport.dart';
import '../../../core/database/database_service.dart';

abstract class AlphaV2Backend {
  Future<void> initialize();
  bool get hasSession;
  bool get enrolled;
  String? get account;
  String? get ownGenesisDigest;
  int? get catalogRevision;
  int? get leaseExpiresAt;
  Future<String> requestGoogleIdToken();
  Future<void> connect(String origin, String idToken);
  Future<Map<String, dynamic>> enroll(String recoveryPassphrase);
  Future<List<Map<String, dynamic>>> contacts();
  Future<void> confirmContact(String account, String genesisDigest);
  Future<List<Map<String, dynamic>>> messages(String peer);
  Future<void> send(String peer, String text, {Map<String, dynamic>? reply});
  Future<void> deleteLocal(String ref);
  Future<int> sync();
  Future<List<Map<String, dynamic>>> delivery(String ref);
  Future<void> renewLease();
  void dispose();
}

class RealAlphaV2Backend implements AlphaV2Backend {
  final CryptoService crypto;
  final DatabaseService database;
  final FlutterSecureStorage _secure = const FlutterSecureStorage(
      aOptions: AndroidOptions(encryptedSharedPreferences: true));

  AlphaTransport? _transport;
  V2ChatRepository? _repo;
  String? _account;
  String? _root;
  String? _privateKey;

  RealAlphaV2Backend({required this.crypto, required this.database});

  V2ChatRepository get _requireRepo {
    final repo = _repo;
    if (repo == null) throw StateError('Устройство не подключено к Alpha');
    return repo;
  }

  @override
  Future<void> initialize() async {
    final prefs = await SharedPreferences.getInstance();
    final origin = prefs.getString('alpha_v2_origin');
    final account = prefs.getString('alpha_v2_account');
    final cookie = await _secure.read(key: 'alpha_v2_cookie');
    if (origin == null || account == null || cookie == null) return;
    final publicKey = await crypto.getPublicKey();
    final privateKey = await crypto.getPrivateKey();
    if (publicKey == null || privateKey == null) return;
    _account = account;
    _root = await publicSpki(publicKey);
    _privateKey = privateKey;
    final transport = AlphaTransport(origin, crypto);
    transport.sessionCookie = cookie;
    _transport = transport;
    final repo = V2ChatRepository(
        transport: transport,
        crypto: crypto,
        store: V2Store(database),
        account: account,
        root: _root!,
        privateKey: privateKey);
    await repo.load();
    _repo = repo;
    if (repo.enrolled) {
      repo.attachWake();
      transport.startPolling();
      try {
        await transport.connectSocket(
            account: account, id: 'primary', privateKey: privateKey);
      } catch (_) {
        // Потерянный socket чинится периодическим подписанным fetch.
      }
    }
  }

  @override
  bool get hasSession => _transport?.hasSession ?? false;

  @override
  bool get enrolled => _repo?.enrolled ?? false;

  @override
  String? get account => _account;

  @override
  String? get ownGenesisDigest {
    final acc = _repo?.accountSnapshot;
    if (acc == null) return null;
    return sha256Hex(genesisText(acc['genesis'] as Map<String, dynamic>));
  }

  @override
  int? get catalogRevision {
    final acc = _repo?.accountSnapshot;
    if (acc == null) return null;
    return (acc['history'] as List).last['revision'] as int;
  }

  @override
  int? get leaseExpiresAt {
    final acc = _repo?.accountSnapshot;
    if (acc == null) return null;
    return (acc['history'] as List).last['expiresAt'] as int;
  }

  @override
  Future<String> requestGoogleIdToken() async {
    const clientId = String.fromEnvironment('ALPHA_GOOGLE_CLIENT_ID');
    if (clientId.isEmpty) {
      throw StateError(
          'ALPHA_GOOGLE_CLIENT_ID не настроен для этой сборки (отдельный OAuth-клиент alpha-процесса).');
    }
    await GoogleSignIn.instance.initialize(serverClientId: clientId);
    final account = await GoogleSignIn.instance.authenticate();
    final idToken = account.authentication.idToken;
    if (idToken == null) {
      throw StateError('Google не вернул ID token. Проверьте OAuth-настройки.');
    }
    return idToken;
  }

  @override
  Future<void> connect(String origin, String idToken) async {
    final publicKey = await crypto.getPublicKey();
    final privateKey = await crypto.getPrivateKey();
    if (publicKey == null || privateKey == null) {
      throw StateError('Сначала создайте профиль Shade на этом устройстве.');
    }
    final transport = AlphaTransport(origin, crypto);
    final session = await transport.loginWithGoogleIdToken(idToken);
    final account = session['account'] as String?;
    if (account == null) {
      transport.dispose();
      throw StateError(
          'Google-аккаунт не найден в alpha-реестре. Нужен явный импорт legacy-аккаунта оператором alpha.');
    }
    _account = account;
    _root = await publicSpki(publicKey);
    _privateKey = privateKey;
    _transport = transport;
    _repo = V2ChatRepository(
        transport: transport,
        crypto: crypto,
        store: V2Store(database),
        account: account,
        root: _root!,
        privateKey: privateKey);
    await _repo!.load();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('alpha_v2_origin', origin);
    await prefs.setString('alpha_v2_account', account);
    await _secure.write(key: 'alpha_v2_cookie', value: transport.sessionCookie);
  }

  @override
  Future<Map<String, dynamic>> enroll(String recoveryPassphrase) async {
    final result =
        await _requireRepo.enrollLegacy(recoveryPassphrase: recoveryPassphrase);
    final transport = _transport!;
    _requireRepo.attachWake();
    transport.startPolling();
    await transport.connectSocket(
        account: _account!, id: 'primary', privateKey: _privateKey!);
    return result;
  }

  @override
  Future<List<Map<String, dynamic>>> contacts() =>
      _requireRepo.store.listContacts();

  @override
  Future<void> confirmContact(String account, String genesisDigest) =>
      _requireRepo.confirmContact(account, genesisDigest);

  @override
  Future<List<Map<String, dynamic>>> messages(String peer) =>
      _requireRepo.getMessages(peer);

  @override
  Future<void> send(String peer, String text, {Map<String, dynamic>? reply}) async {
    await _requireRepo.sendMessage(peer, text, reply: reply);
  }

  @override
  Future<void> deleteLocal(String ref) => _requireRepo.deleteLocal(ref);

  @override
  Future<int> sync() => _requireRepo.syncInbox();

  @override
  Future<List<Map<String, dynamic>>> delivery(String ref) async {
    final result = await _requireRepo.refreshDelivery([ref]);
    return result.isEmpty ? [] : result.first['devices'] as List<Map<String, dynamic>>;
  }

  @override
  Future<void> renewLease() => _requireRepo.renewLease(force: true);

  @override
  void dispose() {
    _transport?.dispose();
    _transport = null;
    _repo = null;
  }
}