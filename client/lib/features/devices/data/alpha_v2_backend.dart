/// Связка UI Alpha v2 с device-v2 репозиторием и транспортом.
///
/// Интерфейс отделён от реализации для widget-тестов; реальная реализация
/// переиспользует существующие CryptoService/DatabaseService и изолированный
/// alpha-процесс. Production v1-поток не затрагивается.
library;

import 'dart:typed_data';

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
  Future<String> requestGoogleIdToken(String origin);
  Future<void> connect(String origin, String idToken);
  bool get registrationPending;
  V2ChatRepository? get pairingRepository;
  Future<Map<String, dynamic>> register(
      String account, String recoveryPassphrase);
  Future<void> connectWithLegacyKey(String origin);
  Future<Map<String, dynamic>> enroll(String recoveryPassphrase);

  /// Аккаунт требует RSA-rotation (v1 RSA-2048 → v2 RSA-4096) до enrollment.
  bool get rotationPending;
  Future<List<Map<String, dynamic>>> contacts();
  Future<void> confirmContact(String account, String genesisDigest);
  Future<List<Map<String, dynamic>>> messages(String peer);
  Future<bool> peerUpgradeBlocked(String peer);
  Future<void> send(String peer, String text, {Map<String, dynamic>? reply});
  Future<String> sendMedia(String peer, List<int> bytes, {String mime});
  Future<void> deleteLocal(String ref);
  Future<void> retract(String ref);
  Future<void> markRead(List<String> refs);
  Future<int> sync();
  Future<List<Map<String, dynamic>>> delivery(String ref);
  Future<void> renewLease();
  void watch(String peer);
  void unwatch(String peer);
  void sendTyping(String peer);
  void Function(String account, int until)? onTyping;
  void Function(String account, bool online)? onPresence;
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
  String? _loginNonce;
  String? _root;
  String? _privateKey;
  bool _rotationPending = false;
  String? _registrationOrigin;
  @override
  bool get registrationPending => _registrationOrigin != null;

  @override
  V2ChatRepository? get pairingRepository {
    final repo = _repo;
    return !registrationPending &&
            repo != null &&
            !repo.enrolled &&
            repo.root.isEmpty
        ? repo
        : null;
  }

  RealAlphaV2Backend({required this.crypto, required this.database});

  @override
  bool get rotationPending => _rotationPending;

  @override
  void Function(String account, int until)? onTyping;
  @override
  void Function(String account, bool online)? onPresence;

  void _attachSignals() {
    _transport?.onTyping = (account, until) => onTyping?.call(account, until);
    _transport?.onPresence =
        (account, online) => onPresence?.call(account, online);
  }

  @override
  Future<void> markRead(List<String> refs) => _requireRepo.markRead(refs);

  @override
  Future<void> retract(String ref) => _requireRepo.retractMessage(ref);

  @override
  Future<String> sendMedia(String peer, List<int> bytes,
          {String mime = 'image/jpeg'}) =>
      _requireRepo.sendMedia(peer, Uint8List.fromList(bytes), mime: mime);

  @override
  void watch(String peer) => _transport?.watch(peer);

  @override
  void unwatch(String peer) => _transport?.unwatch(peer);

  @override
  void sendTyping(String peer) => _transport?.sendTyping(peer);

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
    _attachSignals();
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
      // После rotation якорь — новый ключ из зашифрованного хранилища,
      // а не v1-ключ из secure storage.
      _privateKey = repo.privateKey;
      _root = repo.root;
      repo.attachWake();
      transport.startPolling();
      try {
        await transport.connectSocket(
            account: account, id: 'primary', privateKey: repo.privateKey);
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
  Future<String> requestGoogleIdToken(String origin) async {
    const clientId = String.fromEnvironment('ALPHA_GOOGLE_CLIENT_ID');
    if (clientId.isEmpty) {
      throw StateError(
          'ALPHA_GOOGLE_CLIENT_ID не настроен для этой сборки (отдельный OAuth-клиент alpha-процесса).');
    }
    // Single-use server nonce embedded into the ID token (replay protection).
    final nonceTransport = AlphaTransport(origin, crypto);
    final String nonce;
    try {
      nonce = await nonceTransport.fetchLoginNonce();
    } finally {
      nonceTransport.dispose();
    }
    await GoogleSignIn.instance
        .initialize(serverClientId: clientId, nonce: nonce);
    final account = await GoogleSignIn.instance.authenticate();
    final idToken = account.authentication.idToken;
    if (idToken == null) {
      throw StateError('Google не вернул ID token. Проверьте OAuth-настройки.');
    }
    _loginNonce = nonce;
    return idToken;
  }

  @override
  Future<void> connect(String origin, String idToken) async {
    final nonce = _loginNonce;
    if (nonce == null) throw StateError('Сначала войдите через Google.');
    final transport = AlphaTransport(origin, crypto);
    try {
      final session = await transport.loginWithGoogleIdToken(idToken, nonce);
      final account = session['account'] as String?;
      final store = V2Store(database);
      final profile = account == null ? null : await store.loadAccount(account);
      if (profile == null) {
        final pending =
            account == null ? null : await store.loadEnrollmentJournal(account);
        if (account != null && pending?['phase'] != 'registering') {
          _repo = V2ChatRepository.pairing(
            transport: transport,
            crypto: crypto,
            store: store,
            account: account,
          );
          _registrationOrigin = null;
        } else {
          _repo = null;
          _registrationOrigin = origin;
        }
        _account = account;
      } else {
        final repo = V2ChatRepository.pairing(
            transport: transport,
            crypto: crypto,
            store: store,
            account: account!);
        final legacy = profile['sessionId'] == 'primary';
        if (legacy) repo.privateKey = await crypto.getPrivateKey() ?? '';
        await repo.load();
        await _saveSession(origin, account, transport);
        _repo = repo;
        _account = account;
        _registrationOrigin = null;
      }
      _transport?.dispose();
      _transport = transport;
      _attachSignals();
    } catch (_) {
      transport.dispose();
      rethrow;
    }
  }

  Future<void> _saveSession(
      String origin, String account, AlphaTransport transport) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('alpha_v2_origin', origin);
    await prefs.setString('alpha_v2_account', account);
    await _secure.write(key: 'alpha_v2_cookie', value: transport.sessionCookie);
  }

  @override
  Future<Map<String, dynamic>> register(
      String account, String recoveryPassphrase) async {
    final origin = _registrationOrigin;
    final transport = _transport;
    if (origin == null || transport == null)
      throw StateError('Сначала войдите через Google.');
    final repo = V2ChatRepository.pairing(
        transport: transport,
        crypto: crypto,
        store: V2Store(database),
        account: account);
    final recovery = await repo.registerNewAccount(recoveryPassphrase);
    await _saveSession(origin, account, transport);
    _repo = repo;
    _account = account;
    _registrationOrigin = null;
    return recovery;
  }

  @override
  Future<void> connectWithLegacyKey(String origin) async {
    final profile = await database.getCurrentUserProfile();
    final publicKey = await crypto.getPublicKey();
    final privateKey = await crypto.getPrivateKey();
    if (profile == null || publicKey == null || privateKey == null) {
      throw StateError('Сначала создайте профиль Shade на этом устройстве.');
    }
    final account = (profile['nickname'] as String).toLowerCase().trim();
    final transport = AlphaTransport(origin, crypto);
    var rotationPending = false;
    try {
      try {
        final nonce = await transport.legacyChallenge(account);
        final operation = operationDigest('legacy-session', null);
        final proof = await crypto.signData(
            requestText(account, 'primary', nonce, operation), privateKey);
        final session = await transport.legacySession(account, nonce, proof);
        if (session['account'] != account) {
          throw StateError('Сервер вернул другой аккаунт; вход отклонён.');
        }
      } catch (_) {
        // v1 RSA-2048: аккаунт подготовлен как rotation_required — legacy-
        // сессия невозможна до смены ключа. Проверяем rotation-статус и
        // продолжаем БЕЗ сессии (enrollment выполнит rotation и откроет её).
        await transport.rotationChallenge(account);
        rotationPending = true;
      }
    } catch (_) {
      transport.dispose();
      rethrow;
    }
    _account = account;
    _root = await publicSpki(publicKey);
    _privateKey = privateKey;
    _rotationPending = rotationPending;
    _transport = transport;
    _attachSignals();
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
    if (!rotationPending) {
      await _secure.write(
          key: 'alpha_v2_cookie', value: transport.sessionCookie);
    }
  }

  @override
  Future<Map<String, dynamic>> enroll(String recoveryPassphrase) async {
    final repo = _requireRepo;
    Map<String, dynamic> result;
    if (_rotationPending) {
      result =
          await repo.enrollWithRotation(recoveryPassphrase: recoveryPassphrase);
      // После успешной rotation открываем сессию НОВЫМ ключом.
      final transport = _transport!;
      final nonce = await transport.legacyChallenge(_account!);
      final operation = operationDigest('legacy-session', null);
      final proof = await crypto.signData(
          requestText(_account!, 'primary', nonce, operation), repo.privateKey);
      final session = await transport.legacySession(_account!, nonce, proof);
      if (session['account'] != _account) {
        throw StateError('Сервер вернул другой аккаунт; вход отклонён.');
      }
      _privateKey = repo.privateKey;
      _root = repo.root;
      _rotationPending = false;
      await _secure.write(
          key: 'alpha_v2_cookie', value: transport.sessionCookie);
    } else {
      result = await repo.enrollLegacy(recoveryPassphrase: recoveryPassphrase);
    }
    final transport = _transport!;
    repo.attachWake();
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
  Future<bool> peerUpgradeBlocked(String peer) =>
      _requireRepo.isPeerUpgradeBlocked(peer);

  @override
  Future<void> send(String peer, String text,
      {Map<String, dynamic>? reply}) async {
    await _requireRepo.sendMessage(peer, text, reply: reply);
  }

  @override
  Future<void> deleteLocal(String ref) => _requireRepo.deleteLocal(ref);

  @override
  Future<int> sync() async {
    final fresh = await _requireRepo.syncInbox();
    final legacy = await _requireRepo.syncLegacyInbox();
    return fresh + legacy;
  }

  @override
  Future<List<Map<String, dynamic>>> delivery(String ref) async {
    final result = await _requireRepo.refreshDelivery([ref]);
    return result.isEmpty
        ? []
        : result.first['devices'] as List<Map<String, dynamic>>;
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
