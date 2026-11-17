/// HTTP/Socket.IO транспорт device-v2 для native-клиента (альфа-процесс).
///
/// Порт транспортной части client/web/alpha-client.mjs: cookie-сессия Google,
/// одноразовый challenge + RSA-PSS proof на каждую операцию, Socket.IO только
/// как wake-up hints (потерянные hints чинятся подписанным fetch при reconnect
/// и периодическим опросом). Production server.js (v1) не затрагивается.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:socket_io_client/socket_io_client.dart' as io;

import '../crypto_service.dart';
import 'protocol.dart';

class AlphaTransportException implements Exception {
  final int status;
  final String code;
  AlphaTransportException(this.status, this.code);
  @override
  String toString() => 'AlphaTransportException($status, $code)';
}

class AlphaTransport {
  final String origin;
  final CryptoService crypto;
  final HttpClient _client = HttpClient();

  /// Для восстановленной сессии или тестового fixture; в production cookie
  /// выдаётся сервером после проверки Google.
  String? sessionCookie;
  io.Socket? _socket;
  Timer? _pollTimer;
  Timer? _reconnectTimer;
  bool _disposed = false;
  bool _connecting = false;

  /// Вызывается при hint inbox/receipts/retracted, reconnect и каждом периоде
  /// опроса. Владелец (репозиторий) выполняет подписанный fetch/receipts сам.
  void Function()? onWake;

  /// Typing/presence hints (контракт C2): только между аккаунтами с перепиской.
  void Function(String account, int until)? onTyping;
  void Function(String account, bool online)? onPresence;

  AlphaTransport(this.origin, this.crypto) {
    final uri = Uri.parse(origin);
    check(
        uri.scheme == 'https' ||
            (uri.scheme == 'http' &&
                ['localhost', '127.0.0.1', '[::1]'].contains(uri.host)),
        'HTTPS origin required');
    check(origin == uri.origin, 'Invalid origin');
  }

  bool get hasSession => sessionCookie != null;

  Future<dynamic> _send(String method, String path, {Object? body}) async {
    final request = await _client.openUrl(method, Uri.parse('$origin$path'));
    request.headers.set('Content-Type', 'application/json');
    request.headers.set('Origin', origin);
    if (sessionCookie != null) request.headers.set('Cookie', sessionCookie!);
    if (body != null) request.write(jsonEncode(body));
    final response = await request.close();
    for (final cookie in response.cookies) {
      if (cookie.name == 'shade-alpha' || cookie.name == '__Host-shade-alpha') {
        sessionCookie = '${cookie.name}=${cookie.value}';
      }
    }
    final text = await response.transform(utf8.decoder).join();
    final dynamic decoded = text.isEmpty ? null : jsonDecode(text);
    if (response.statusCode != 200) {
      final code = decoded is Map && decoded['error'] is String
          ? decoded['error'] as String
          : 'http_${response.statusCode}';
      throw AlphaTransportException(response.statusCode, code);
    }
    return decoded;
  }

  Future<Map<String, dynamic>> session() async =>
      await _send('GET', '/api/session') as Map<String, dynamic>;

  /// Вход владением исходного RSA v1 (для nickname-only аккаунтов при
  /// миграции): одноразовый nonce + подпись requestText исходным ключом.
  Future<String> legacyChallenge(String account) async =>
      (await _send('POST', '/api/v2/session/legacy-challenge',
          body: {'account': account}) as Map<String, dynamic>)['nonce'] as String;

  Future<Map<String, dynamic>> legacySession(
          String account, String nonce, String proof) async =>
      await _send('POST', '/api/v2/session/legacy',
          body: {'account': account, 'nonce': nonce, 'proof': proof})
          as Map<String, dynamic>;

  /// Одноразовый nonce для входа через Google ID token (защита от replay):
  /// клиент передаёт его в google_sign_in initialize(nonce:), сервер сверяет
  /// claim nonce в токене и потребляет nonce безвозвратно.
  Future<String> fetchLoginNonce() async =>
      (await _send('GET', '/api/v2/session/nonce')
          as Map<String, dynamic>)['nonce'] as String;

  /// Вход native через Google ID token (google_sign_in plugin с serverClientId
  /// alpha-процесса). Сервер проверяет token тем же googleProfile, что и code flow.
  Future<Map<String, dynamic>> loginWithGoogleIdToken(
          String idToken, String nonce) async =>
      await _send('POST', '/api/v2/session/google',
          body: {'idToken': idToken, 'nonce': nonce}) as Map<String, dynamic>;

  Future<void> logout() async {
    await _send('POST', '/api/logout');
    sessionCookie = null;
    _disconnectSocket();
  }

  Future<Map<String, dynamic>> register(Map<String, dynamic> genesis,
          Map<String, dynamic> manifest, List<dynamic> proofs) async =>
      await _send('POST', '/api/v2/register',
          body: {'genesis': genesis, 'manifest': manifest, 'proofs': proofs})
          as Map<String, dynamic>;

  Future<Map<String, dynamic>> legacyEnrollment(
          Map<String, dynamic> genesis, Map<String, dynamic> manifest) async =>
      await _send('POST', '/api/v2/legacy-enrollment',
          body: {'genesis': genesis, 'manifest': manifest}) as Map<String, dynamic>;

  /// RSA-rotation (v1 RSA-2048 → v2 RSA-4096): одноразовый nonce и fingerprint
  /// старого корня. Сервер отдаёт их только для prepared rotation_required.
  Future<Map<String, dynamic>> rotationChallenge(String account) async =>
      await _send('POST', '/api/v2/session/rotation-challenge',
          body: {'account': account}) as Map<String, dynamic>;

  /// Enrollment новой идентичности с аттестацией, подписанной СТАРЫМ ключом.
  Future<Map<String, dynamic>> legacyRotation(
          String account,
          String nonce,
          Map<String, dynamic> attestation,
          Map<String, dynamic> genesis,
          Map<String, dynamic> manifest) async =>
      await _send('POST', '/api/v2/legacy-rotation', body: {
        'account': account,
        'nonce': nonce,
        'attestation': attestation,
        'genesis': genesis,
        'manifest': manifest
      }) as Map<String, dynamic>;

  Future<dynamic> operation(String op, Object? body,
      {required String account,
      required String id,
      required String privateKey}) async {
    final operation = operationDigest(
        op, op == 'send' ? sha256Hex(messageText(body as Map<String, dynamic>)) : body);
    final challenge = await _send('POST', '/api/v2/challenge',
        body: {'account': account, 'id': id, 'operation': operation}) as Map<String, dynamic>;
    final nonce = challenge['nonce'] as String;
    final proof = await crypto.signData(requestText(account, id, nonce, operation), privateKey);
    return await _send('POST', '/api/v2/operation', body: {
      'op': op,
      'body': body,
      'auth': {'account': account, 'id': id, 'nonce': nonce, 'proof': proof}
    });
  }

  Future<List<dynamic>> fetch(
          {required String account, required String id, required String privateKey}) async =>
      await operation('fetch', null, account: account, id: id, privateKey: privateKey)
          as List<dynamic>;

  Future<Map<String, dynamic>> send(Map<String, dynamic> message,
          {required String privateKey}) async =>
      await operation('send', message,
          account: message['from'] as String,
          id: message['deviceId'] as String,
          privateKey: privateKey) as Map<String, dynamic>;

  Future<Map<String, dynamic>> ack(List<String> refs,
          {required String account, required String id, required String privateKey}) async =>
      await operation('ack', refs, account: account, id: id, privateKey: privateKey)
          as Map<String, dynamic>;

  Future<Map<String, dynamic>> status(List<String> refs,
          {required String account, required String id, required String privateKey}) async =>
      await operation('status', refs, account: account, id: id, privateKey: privateKey)
          as Map<String, dynamic>;

  Future<Map<String, dynamic>> read(List<String> refs,
          {required String account, required String id, required String privateKey}) async =>
      await operation('read', refs, account: account, id: id, privateKey: privateKey)
          as Map<String, dynamic>;

  Future<Map<String, dynamic>> retract(List<String> refs,
          {required String account, required String id, required String privateKey}) async =>
      await operation('retract', refs, account: account, id: id, privateKey: privateKey)
          as Map<String, dynamic>;

  Future<List<dynamic>> retractions(
          {int since = 0,
          required String account,
          required String id,
          required String privateKey}) async =>
      (await operation('retractions', {'since': since},
          account: account, id: id, privateKey: privateKey))['retractions'] as List<dynamic>;

  /// One-way мост v1: недошедшие offline-сообщения v1 для переведённого
  /// аккаунта. Ciphertext {k,d} зашифрован исходным RSA (primary) — сервер
  /// его не расшифровывает. ACK идемпотентен по v1 message ID.
  Future<List<dynamic>> legacyInbox(
          {required String account, required String id, required String privateKey}) async =>
      await operation('legacy.inbox', null,
          account: account, id: id, privateKey: privateKey) as List<dynamic>;

  Future<Map<String, dynamic>> legacyAck(List<String> ids,
          {required String account, required String id, required String privateKey}) async =>
      await operation('legacy.ack', ids,
          account: account, id: id, privateKey: privateKey) as Map<String, dynamic>;

  Future<Map<String, dynamic>> directory(String targetAccount,
          {required String account, required String id, required String privateKey}) async =>
      await operation('directory', targetAccount,
          account: account, id: id, privateKey: privateKey)
          as Map<String, dynamic>;

  Future<List<dynamic>> users(
          {required String account, required String id, required String privateKey}) async =>
      await operation('users', null, account: account, id: id, privateKey: privateKey)
          as List<dynamic>;

  Future<Map<String, dynamic>> install(Map<String, dynamic> manifest,
      {List<dynamic> proofs = const [],
      Map<String, dynamic>? genesis,
      required String account,
      required String id,
      required String privateKey}) async {
    // Порядок ключей тела фиксирован: digest считается по тому же JSON.
    final body = <String, dynamic>{
      'manifest': manifest,
      'proofs': proofs,
      if (genesis != null) 'genesis': genesis
    };
    return await operation('install', body, account: account, id: id, privateKey: privateKey)
        as Map<String, dynamic>;
  }

  /// Socket.IO с одноразовым device-proof; nonce не переиспользуется при
  /// reconnect — каждое подключение получает свежий proof.
  Future<void> connectSocket(
      {required String account,
      required String id,
      required String privateKey}) async {
    if (_disposed || _connecting) return;
    _connecting = true;
    try {
      final operation = operationDigest('socket', null);
      final challenge = await _send('POST', '/api/v2/challenge',
          body: {'account': account, 'id': id, 'operation': operation}) as Map<String, dynamic>;
      final nonce = challenge['nonce'] as String;
      final proof =
          await crypto.signData(requestText(account, id, nonce, operation), privateKey);
      _disconnectSocket();
      final socket = io.io(
          origin,
          io.OptionBuilder()
              .setTransports(['websocket'])
              .disableAutoConnect()
              .disableReconnection()
              .setAuth({'account': account, 'id': id, 'nonce': nonce, 'proof': proof})
              .setExtraHeaders({if (sessionCookie != null) 'Cookie': sessionCookie!})
              .build());
      _socket = socket;
      socket.on('inbox', (_) => onWake?.call());
      socket.on('receipts', (_) => onWake?.call());
      socket.on('retracted', (_) => onWake?.call());
      socket.on('typing', (data) {
        if (data is Map && data['account'] is String && data['until'] is int) {
          onTyping?.call(data['account'] as String, data['until'] as int);
        }
      });
      socket.on('presence', (data) {
        if (data is Map && data['account'] is String && data['online'] is bool) {
          onPresence?.call(data['account'] as String, data['online'] as bool);
        }
      });
      socket.onConnect((_) => onWake?.call());
      socket.onDisconnect((_) {
        if (!_disposed) _scheduleReconnect(account, id, privateKey);
      });
      socket.onConnectError((_) {
        if (!_disposed) _scheduleReconnect(account, id, privateKey);
      });
      socket.connect();
    } finally {
      _connecting = false;
    }
  }

  /// Presence/typing подписки и сигналы (socket уже авторизован proof-ом).
  void watch(String peer) => _socket?.emit('watch', {'peer': peer});
  void unwatch(String peer) => _socket?.emit('unwatch', {'peer': peer});
  void sendTyping(String peer) => _socket?.emit('typing', {'peer': peer});

  void _scheduleReconnect(String account, String id, String privateKey) {
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 5), () {
      if (!_disposed) connectSocket(account: account, id: id, privateKey: privateKey);
    });
  }

  /// Периодический подписанный fetch чинит потерянные socket hints.
  void startPolling({Duration interval = const Duration(seconds: 15)}) {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(interval, (_) => onWake?.call());
  }

  void _disconnectSocket() {
    _reconnectTimer?.cancel();
    _socket?.dispose();
    _socket = null;
  }

  void dispose() {
    _disposed = true;
    _pollTimer?.cancel();
    _disconnectSocket();
    _client.close(force: true);
  }
}