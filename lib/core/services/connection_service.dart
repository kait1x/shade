import 'dart:async';
import 'dart:convert';
import 'dart:io' show HttpClient, Platform, SecurityContext, X509Certificate;
import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart' as http_io;
import 'package:socket_io_client/socket_io_client.dart' as io;

import 'package:shade/core/services/crypto_service.dart';
import 'package:shade/core/services/notification_service.dart';
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

class UserStatus {
  final bool online;
  final int lastSeen; // milliseconds since epoch

  const UserStatus({required this.online, required this.lastSeen});

  /// Returns a human-readable string like Telegram.
  String get displayText {
    if (online) return 'в сети';

    if (lastSeen == 0) return 'был(а) давно';

    final diff = DateTime.now().millisecondsSinceEpoch - lastSeen;
    final minutes = diff ~/ 60000;
    final hours = diff ~/ 3600000;
    final days = diff ~/ 86400000;

    if (minutes < 1) return 'только что';
    if (minutes < 5) return 'был(а) недавно';
    if (hours < 24) return 'сегодня';
    if (hours < 48) return 'вчера';
    if (days < 7) return 'был(а) на этой неделе';
    if (days < 30) return 'был(а) месяц назад';
    return 'был(а) давно';
  }
}

class UserStatusUpdate {
  final String username;
  final bool online;
  final int lastSeen;

  const UserStatusUpdate({
    required this.username,
    required this.online,
    required this.lastSeen,
  });

  factory UserStatusUpdate.fromJson(Map<String, dynamic> json) {
    return UserStatusUpdate(
      username: json['username'] as String,
      online: json['online'] as bool,
      lastSeen: json['lastSeen'] as int? ?? 0,
    );
  }

  UserStatus toUserStatus() => UserStatus(online: online, lastSeen: lastSeen);
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

class MessageDeletedEvent {
  final String msgId;
  final String from;

  const MessageDeletedEvent({required this.msgId, required this.from});

  factory MessageDeletedEvent.fromJson(Map<String, dynamic> json) {
    return MessageDeletedEvent(
      msgId: json['msgId'] as String,
      from: json['from'] as String,
    );
  }
}

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
// ── HTTP Client with certificate pinning ───────────────────

/// SHA-256 fingerprint of the server's TLS certificate (DER format, base64).
/// Pass via: --dart-define=SHADED_PIN_SHA256=<base64>
/// If empty, self-signed certs are allowed (development only).
const _pinSha256 =
    String.fromEnvironment('SHADED_PIN_SHA256', defaultValue: '');

/// Creates an HTTP client with optional certificate pinning.
http.Client _createHttpClient() {
  final client = HttpClient();

  if (_pinSha256.isNotEmpty) {
    // Production: pin to specific certificate
    client.badCertificateCallback = (X509Certificate cert, _, __) {
      final fingerprint = sha256.convert(cert.der).toString();
      return fingerprint == _pinSha256;
    };
  } else {
    // Development: allow any certificate (self-signed)
    client.badCertificateCallback = (_, __, ___) => true;
  }

  return http_io.IOClient(client);
}

class ConnectionService {
  final String serverUrl;
  final CryptoService _crypto;
  final DatabaseService _db;
  final http.Client _httpClient;

  io.Socket? _socket;
  String? _username;
  String? _sessionToken;
  Timer? _reconnectTimer;
  bool _isDisposed = false;

  final _messageCtrl = StreamController<IncomingMessage>.broadcast();
  final _notificationCtrl = StreamController<IncomingMessage>.broadcast();
  final _typingCtrl = StreamController<String>.broadcast();
  final _statusCtrl = StreamController<UserStatusUpdate>.broadcast();
  final _deleteCtrl = StreamController<MessageDeletedEvent>.broadcast();

  bool _isConnected = false;

  ConnectionService({
    required this.serverUrl,
    required CryptoService cryptoService,
    required DatabaseService databaseService,
  })  : _crypto = cryptoService,
        _db = databaseService,
        _httpClient = _createHttpClient();

  // ── Public API ──────────────────────────────────────────────

  Stream<IncomingMessage> get messages => _messageCtrl.stream;
  Stream<IncomingMessage> get notifications => _notificationCtrl.stream;
  Stream<String> get typing => _typingCtrl.stream;
  Stream<UserStatusUpdate> get statusUpdates => _statusCtrl.stream;
  Stream<MessageDeletedEvent> get messageDeleted => _deleteCtrl.stream;
  bool get isConnected => _isConnected;
  String? get currentUsername => _username;

  /// Watch a user's online status (real-time via WebSocket).
  void watchUser(String username) {
    if (_socket != null && _isConnected) {
      _socket!.emit('watch', username);
    }
  }

  /// Stop watching a user's status.
  void unwatchUser(String username) {
    if (_socket != null && _isConnected) {
      _socket!.emit('unwatch', username);
    }
  }

  /// Send read/delivered status for messages.
  void sendMessageStatus(String type, String from, {List<String>? msgIds}) {
    if (_socket == null || !_isConnected) return;
    if (type == 'read') {
      _socket!.emit('read', {'from': from, 'msgIds': msgIds});
    } else if (type == 'delivered' && msgIds != null && msgIds.isNotEmpty) {
      _socket!.emit('delivered', msgIds.first);
    }
  }

  /// Delete a message for everyone.
  void sendDeleteMessage(String to, String msgId) {
    if (_socket == null || !_isConnected) return;
    _socket!
        .emit('deleteMessage', {'to': to, 'msgId': msgId, 'forEveryone': true});
  }

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
      throw Exception(
          body['error'] ?? 'Registration failed (${response.statusCode})');
    }

    final body = jsonDecode(response.body);
    _username = username;
    _sessionToken = body['token'];
    debugPrint('[ConnectionService] Registered');
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
        debugPrint('[ConnectionService] Invalid signature');
        return null;
      }
      return bundle;
    } catch (e) {
      debugPrint('[ConnectionService] getPublicKey error: $e');
      return null;
    }
  }

  /// Fetches online status and last seen for a user.
  Future<UserStatus?> getUserStatus(String username) async {
    try {
      final response = await _retryGet(
        Uri.parse('$serverUrl/user/$username'),
      );
      if (response.statusCode != 200) return null;

      final json = jsonDecode(response.body) as Map<String, dynamic>;
      return UserStatus(
        online: json['online'] as bool? ?? false,
        lastSeen: json['lastSeen'] as int? ?? 0,
      );
    } catch (_) {
      return null;
    }
  }

  // ── WebSocket ───────────────────────────────────────────────

  /// Opens the WebSocket and auto-reconnects on failure.
  void connect(String username) {
    // Always disconnect old socket first
    if (_socket != null) {
      _socket!.disconnect();
      _socket!.dispose();
      _socket = null;
      _isConnected = false;
    }

    _username = username;

    _socket = io.io(
      serverUrl,
      io.OptionBuilder()
          .setTransports(['websocket'])
          .disableAutoConnect()
          .setReconnectionAttempts(-1)
          .setReconnectionDelay(2000)
          .setReconnectionDelayMax(15000)
          .setTimeout(20000)
          .build(),
    );

    _socket!.onConnect((_) {
      _isConnected = true;
      _cancelReconnect();
      _socket!.emit('register', {
        'username': username,
        'token': _sessionToken ?? '',
      });
      debugPrint('[ConnectionService] WS connected');
    });

    _socket!.on('message', _handleIncomingMessage);

    // Typing indicator events
    _socket!.on('typing', (data) {
      final from = (data as Map)['from'] as String;
      if (!_typingCtrl.isClosed) _typingCtrl.add(from);
    });

    _socket!.on('stopTyping', (data) {
      // The UI will handle the timeout
    });

    _socket!.on('authError', (data) async {
      debugPrint('[ConnectionService] WS auth error — re-registering');
      _sessionToken = null;
      disconnect();
      // Re-register to get new session token, then reconnect
      if (_username != null) {
        try {
          await register(_username!);
          connect(_username!);
        } catch (e) {
          debugPrint('[ConnectionService] Re-register failed: $e');
        }
      }
    });

    _socket!.on('statusUpdate', (data) {
      try {
        final update = UserStatusUpdate.fromJson(
          Map<String, dynamic>.from(data as Map),
        );
        if (!_statusCtrl.isClosed) _statusCtrl.add(update);
      } catch (_) {}
    });

    _socket!.on('messageDeleted', (data) {
      try {
        final event = MessageDeletedEvent.fromJson(
          Map<String, dynamic>.from(data as Map),
        );
        if (!_deleteCtrl.isClosed) _deleteCtrl.add(event);
      } catch (_) {}
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

  /// Sends typing indicator to [to].
  void sendTyping(String to) {
    if (_socket == null || !_isConnected) return;
    _socket!.emit('typing', {'to': to});
  }

  /// Sends stop-typing indicator to [to].
  void sendStopTyping(String to) {
    if (_socket == null || !_isConnected) return;
    _socket!.emit('stopTyping', {'to': to});
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
    _notificationCtrl.close();
    _typingCtrl.close();
    _statusCtrl.close();
    _deleteCtrl.close();
  }

  // ── Incoming message handler ────────────────────────────────

  /// Saves incoming message to DB, then broadcasts to UI listeners.
  Future<void> _handleIncomingMessage(dynamic raw) async {
    try {
      final msg = IncomingMessage.fromJson(
        Map<String, dynamic>.from(raw as Map),
      );
      debugPrint('[ConnectionService] Incoming message');

      // Skip messages from self (prevents duplicates)
      if (msg.from == _username) {
        debugPrint('[ConnectionService] Skipping own message');
        return;
      }

      // Persist into encrypted DB
      final convId = await _ensureConversation(msg.from);
      await _db.insertMessage(
        conversationId: convId,
        senderId: msg.from.hashCode.abs(),
        encryptedContent: msg.data,
      );

      // Notify UI
      if (!_messageCtrl.isClosed) {
        _messageCtrl.add(msg);
      }

      // Emit notification for incoming messages
      if (!_notificationCtrl.isClosed) {
        _notificationCtrl.add(msg);
      }

      // Show system notification
      await NotificationService.showMessageNotification(
        from: msg.from,
        conversationId: convId.toString(),
      );
    } catch (e) {
      debugPrint('[ConnectionService] Bad incoming message: $e');
    }
  }

  Future<int> _ensureConversation(String withUser) async {
    final convs = await _db.getConversations();
    for (final c in convs) {
      if (c['name'] == withUser) return c['id'] as int;
    }
    // Look up public key from contacts
    String? publicKey;
    final contact = await _db.getContact(withUser);
    if (contact != null) {
      publicKey = contact['public_key'] as String?;
    }
    // If not in contacts, fetch from server
    if (publicKey == null) {
      try {
        final bundle = await getPublicKey(withUser);
        if (bundle != null) {
          publicKey = bundle.publicKey;
          await _db.saveContact(
            nickname: withUser,
            publicKey: bundle.publicKey,
            signature: bundle.signature,
          );
        }
      } catch (_) {}
    }
    return _db.createConversation(withUser, publicKey: publicKey);
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
        return await _httpClient
            .post(uri,
                headers: {'Content-Type': 'application/json'}, body: body)
            .timeout(const Duration(seconds: 15));
      } catch (e) {
        if (i == _maxRetries - 1) rethrow;
        debugPrint('[ConnectionService] POST retry ${i + 1}/$_maxRetries');
        await Future.delayed(_retryDelay);
      }
    }
    throw StateError('unreachable');
  }

  Future<http.Response> _retryGet(Uri uri) async {
    for (var i = 0; i < _maxRetries; i++) {
      try {
        return await _httpClient.get(uri).timeout(const Duration(seconds: 15));
      } catch (e) {
        if (i == _maxRetries - 1) rethrow;
        debugPrint('[ConnectionService] GET retry ${i + 1}/$_maxRetries');
        await Future.delayed(_retryDelay);
      }
    }
    throw StateError('unreachable');
  }
}

// ── Riverpod providers ────────────────────────────────────────

/// Server URL — configure via --dart-define=SHADE_SERVER_URL=<url>
///
/// ┌─────────────────────────────┬───────────────────────────────────────┐
/// │ Setup                       │ URL                                   │
/// ├─────────────────────────────┼───────────────────────────────────────┤
/// │ Android emulator (local)    │ http://10.0.2.2:3000                  │
/// │ iOS simulator               │ http://localhost:3000                  │
/// │ Production (HTTPS required) │ https://your-domain.com               │
/// │ Cloudflare Tunnel           │ https://your-name.trycloudflare.com   │
/// └─────────────────────────────┴───────────────────────────────────────┘
///
/// WARNING: HTTP exposes metadata. Always use HTTPS in production.
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
