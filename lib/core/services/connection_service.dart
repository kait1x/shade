import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:socket_io_client/socket_io_client.dart' as io;

import 'package:shade/core/services/crypto_service.dart';
import 'package:shade/core/database/database_service.dart';
import 'package:shade/features/auth/data/repositories/auth_notifier.dart';

// ── Domain models ─────────────────────────────────────────────

class PublicKeyBundle {
  final String publicKey;
  final String signature;

  const PublicKeyBundle({required this.publicKey, required this.signature});

  factory PublicKeyBundle.fromJson(Map<String, dynamic> json) {
    return PublicKeyBundle(
      publicKey: json['publicKey'] as String,
      signature: json['signature'] as String,
    );
  }
}

class IncomingMessage {
  final String from;
  final String data; // encrypted payload JSON
  final DateTime timestamp;

  const IncomingMessage({
    required this.from,
    required this.data,
    required this.timestamp,
  });

  factory IncomingMessage.fromJson(Map<String, dynamic> json) {
    return IncomingMessage(
      from: json['from'] as String,
      data: json['data'] as String,
      timestamp: DateTime.fromMillisecondsSinceEpoch(json['timestamp'] as int),
    );
  }
}

// ── Connection service ────────────────────────────────────────

/// Manages HTTP + WebSocket communication with the Shade relay server.
///
/// Supports:
/// - Local development (http://localhost:3000)
/// - Cloudflare Tunnel (https://your-tunnel.trycloudflare.com)
/// - Custom LAN IP for physical devices
///
/// Flow:
///   1. register(username) — POST public key + signature
///   2. connect(username) — open Socket.io, auto-register
///   3. getPublicKey(username) — fetch + verify recipient key
///   4. sendMessage(to, data) — emit encrypted payload
///   5. messages stream — incoming encrypted messages (auto-saved to DB)
class ConnectionService {
  final String serverUrl;
  final CryptoService _crypto;
  final DatabaseService _db;

  io.Socket? _socket;
  String? _username;
  Timer? _reconnectTimer;
  bool _isDisposed = false;

  final _messageCtrl = StreamController<IncomingMessage>.broadcast();
  final _onlineCtrl = StreamController<List<String>>.broadcast();
  final Set<String> _onlineUsers = {};

  bool _isConnected = false;

  ConnectionService({
    required this.serverUrl,
    required CryptoService cryptoService,
    required DatabaseService databaseService,
  })  : _crypto = cryptoService,
        _db = databaseService;

  // ── Public API ──────────────────────────────────────────────

  Stream<IncomingMessage> get messages => _messageCtrl.stream;
  Stream<List<String>> get onlineUsers => _onlineCtrl.stream;
  bool get isConnected => _isConnected;
  String? get currentUsername => _username;

  // ── REST ────────────────────────────────────────────────────

  /// Registers the current user on the server.
  Future<void> register(String username) async {
    final publicKey = await _crypto.getPublicKey();
    if (publicKey == null) {
      throw StateError('No public key — generate identity first');
    }

    final signature = await _crypto.signPublicKey();

    final response = await _retryPost(
      Uri.parse('$serverUrl/register'),
      body: jsonEncode({
        'username': username,
        'publicKey': publicKey,
        'signature': signature,
      }),
    );

    if (response.statusCode != 200) {
      final body = jsonDecode(response.body);
      throw Exception(body['error'] ?? 'Registration failed (${response.statusCode})');
    }

    _username = username;
    debugPrint('[ConnectionService] Registered as $username');
  }

  /// Fetches the public key bundle for [username] and verifies the signature.
  Future<PublicKeyBundle?> getPublicKey(String username) async {
    try {
      final response = await _retryGet(
        Uri.parse('$serverUrl/user/$username'),
      );
      if (response.statusCode != 200) return null;

      final json = jsonDecode(response.body) as Map<String, dynamic>;
      final bundle = PublicKeyBundle.fromJson(json);

      final valid = await _crypto.verifyPublicKeySignature(
        bundle.publicKey,
        bundle.signature,
      );
      if (!valid) {
        debugPrint('[ConnectionService] ⚠ Invalid signature for $username');
        return null;
      }
      return bundle;
    } catch (e) {
      debugPrint('[ConnectionService] getPublicKey error: $e');
      return null;
    }
  }

  // ── WebSocket ───────────────────────────────────────────────

  /// Opens the WebSocket and auto-reconnects on failure.
  void connect(String username) {
    if (_socket != null && _isConnected) return;

    _username = username;

    // Determine transports based on URL scheme
    final uri = Uri.parse(serverUrl);
    final useWebSocketOnly = uri.scheme == 'https' || uri.scheme == 'http';

    _socket = io.io(
      serverUrl,
      io.OptionBuilder()
          .setTransports(['websocket']) // WebSocket only — stable through CF
          .disableAutoConnect()
          .setReconnectionAttempts(-1) // infinite
          .setReconnectionDelay(2000)
          .setReconnectionDelayMax(15000)
          .setTimeout(20000)
          .build(),
    );

    _socket!.onConnect((_) {
      _isConnected = true;
      _cancelReconnect();
      _socket!.emit('register', username);
      debugPrint('[ConnectionService] WS connected as $username');
    });

    _socket!.on('message', _handleIncomingMessage);

    _socket!.on('userOnline', (name) {
      _onlineUsers.add(name as String);
      if (!_onlineCtrl.isClosed) _onlineCtrl.add(_onlineUsers.toList());
    });

    _socket!.on('userOffline', (name) {
      _onlineUsers.remove(name as String);
      if (!_onlineCtrl.isClosed) _onlineCtrl.add(_onlineUsers.toList());
    });

    _socket!.onDisconnect((reason) {
      _isConnected = false;
      debugPrint('[ConnectionService] WS disconnected: $reason');
      _scheduleReconnect();
    });

    _socket!.onError((err) {
      debugPrint('[ConnectionService] WS error: $err');
    });

    _socket!.onConnectError((err) {
      debugPrint('[ConnectionService] WS connect error: $err');
      _scheduleReconnect();
    });

    _socket!.connect();
  }

  /// Sends an encrypted payload to [to] via WebSocket.
  void sendMessage(String to, String encryptedPayload) {
    if (_socket == null || !_isConnected) {
      throw StateError('Not connected');
    }
    _socket!.emit('message', {'to': to, 'data': encryptedPayload});
  }

  void disconnect() {
    _cancelReconnect();
    _socket?.disconnect();
    _socket?.dispose();
    _socket = null;
    _isConnected = false;
  }

  void dispose() {
    _isDisposed = true;
    disconnect();
    _messageCtrl.close();
    _onlineCtrl.close();
  }

  // ── Incoming message handler ────────────────────────────────

  /// Saves incoming message to DB, then broadcasts to UI listeners.
  Future<void> _handleIncomingMessage(dynamic raw) async {
    try {
      final msg = IncomingMessage.fromJson(
        Map<String, dynamic>.from(raw as Map),
      );
      debugPrint('[ConnectionService] Incoming from ${msg.from}');

      // Persist into encrypted DB
      final convId = await _ensureConversation(msg.from);
      await _db.insertMessage(
        conversationId: convId,
        senderId: msg.from.hashCode,
        encryptedContent: msg.data,
      );

      // Notify UI
      if (!_messageCtrl.isClosed) {
        _messageCtrl.add(msg);
      }
    } catch (e) {
      debugPrint('[ConnectionService] Bad incoming message: $e');
    }
  }

  Future<int> _ensureConversation(String withUser) async {
    final convs = await _db.getConversations();
    for (final c in convs) {
      if (c['name'] == withUser) return c['id'] as int;
    }
    return _db.createConversation(withUser);
  }

  // ── Reconnection ────────────────────────────────────────────

  void _scheduleReconnect() {
    if (_isDisposed) return;
    _cancelReconnect();
    _reconnectTimer = Timer(const Duration(seconds: 3), () {
      if (_isDisposed) return;
      if (_username != null && !(_socket?.connected ?? false)) {
        debugPrint('[ConnectionService] Reconnecting...');
        _socket?.connect();
      }
    });
  }

  void _cancelReconnect() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
  }

  // ── HTTP helpers with retry ─────────────────────────────────

  static const _maxRetries = 3;
  static const _retryDelay = Duration(seconds: 2);

  Future<http.Response> _retryPost(Uri uri, {required String body}) async {
    for (var i = 0; i < _maxRetries; i++) {
      try {
        return await http
            .post(uri, headers: {'Content-Type': 'application/json'}, body: body)
            .timeout(const Duration(seconds: 15));
      } catch (e) {
        if (i == _maxRetries - 1) rethrow;
        debugPrint('[ConnectionService] POST retry ${i + 1}/$_maxRetries: $e');
        await Future.delayed(_retryDelay);
      }
    }
    throw StateError('unreachable');
  }

  Future<http.Response> _retryGet(Uri uri) async {
    for (var i = 0; i < _maxRetries; i++) {
      try {
        return await http.get(uri).timeout(const Duration(seconds: 15));
      } catch (e) {
        if (i == _maxRetries - 1) rethrow;
        debugPrint('[ConnectionService] GET retry ${i + 1}/$_maxRetries: $e');
        await Future.delayed(_retryDelay);
      }
    }
    throw StateError('unreachable');
  }
}

// ── Riverpod providers ────────────────────────────────────────

/// Server URL — choose the right one for your setup:
///
/// ┌─────────────────────────────┬───────────────────────────────────────┐
/// │ Setup                       │ URL                                   │
/// ├─────────────────────────────┼───────────────────────────────────────┤
/// │ Android emulator (local)    │ http://10.0.2.2:3000                  │
/// │ iOS simulator               │ http://localhost:3000                  │
/// │ Physical device (LAN)       │ http://192.168.1.XXX:3000              │
/// │ Cloudflare Tunnel           │ https://your-name.trycloudflare.com   │
/// └─────────────────────────────┴───────────────────────────────────────┘
///
/// For Samsung A25 over USB/WiFi with Cloudflare, use your tunnel URL.
const _serverUrl = String.fromEnvironment(
  'SHADE_SERVER_URL',
  defaultValue: 'http://10.0.2.2:3000',
);

final connectionServiceProvider = Provider<ConnectionService>((ref) {
  final crypto = ref.watch(cryptoServiceProvider);
  final db = ref.watch(databaseServiceProvider);
  final svc = ConnectionService(
    serverUrl: _serverUrl,
    cryptoService: crypto,
    databaseService: db,
  );
  ref.onDispose(() => svc.dispose());
  return svc;
});
