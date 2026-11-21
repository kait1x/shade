import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shade/core/services/tls_policy.dart';
import 'package:shade/core/services/profile_upload.dart';
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
  final String? serverSignature;
  final int serverSignatureVersion;

  const PublicKeyBundle({
    required this.publicKey,
    required this.signature,
    this.serverSignature,
    this.serverSignatureVersion = 0,
  });

  factory PublicKeyBundle.fromJson(Map<String, dynamic> json) {
    return PublicKeyBundle(
      publicKey: json['publicKey'] as String,
      signature: json['signature'] as String,
      serverSignature: json['serverSignature'] as String?,
      serverSignatureVersion: json['serverSignatureVersion'] as int? ?? 0,
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
  final String id;
  final String from;
  final String data; // encrypted payload JSON
  final DateTime timestamp;

  const IncomingMessage({
    required this.id,
    required this.from,
    required this.data,
    required this.timestamp,
  });

  factory IncomingMessage.fromJson(Map<String, dynamic> json) {
    return IncomingMessage(
      id: json['id'] as String,
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

const _certificateDigest = String.fromEnvironment('TLS_CERT_SHA256');

http.Client _createHttpClient(String url) =>
    http_io.IOClient(ShadeHttpOverrides(Uri.parse(url), _certificateDigest)
        .createHttpClient(null));

class ConnectionService {
  final String serverUrl;
  final CryptoService _crypto;
  final DatabaseService _db;
  final http.Client _httpClient;
  late final _profileUploads =
      ProfileUploadTransport(Uri.parse(serverUrl), _certificateDigest);

  io.Socket? _socket;
  String? _username;
  String? _sessionToken;
  String? _serverPublicKey;
  Future<bool> Function(ServerKeyFingerprintResult)? onServerKeyConfirmation;
  Future<bool>? _confirmingServerKey;
  Timer? _reconnectTimer;
  bool _isDisposed = false;
  bool _signedOut = false;
  int _sessionGeneration = 0;

  final _connectionCtrl = StreamController<bool>.broadcast();
  final Set<String> _watchedUsers = {};
  final Map<String, int> _profileWatches = {};
  final _avatarCtrl = StreamController<String>.broadcast();
  Timer? _profileWatchTimer;
  Stream<String> get avatarUpdates => _avatarCtrl.stream;
  String? get profileOwner => _username;
  void retainProfile(String name) {
    _profileWatches.update(name, (n) => n + 1, ifAbsent: () => 1);
    _scheduleProfileWatches();
  }

  void releaseProfile(String name) {
    final count = _profileWatches[name] ?? 0;
    if (count <= 1) {
      _profileWatches.remove(name);
    } else {
      _profileWatches[name] = count - 1;
    }
    _scheduleProfileWatches();
  }

  void _scheduleProfileWatches() {
    _profileWatchTimer?.cancel();
    _profileWatchTimer = Timer(const Duration(milliseconds: 80), () {
      if (_isConnected) {
        _socket?.emit('watchProfiles', _profileWatches.keys.take(256).toList());
      }
    });
  }

  Timer? _outboxTimer;
  bool _flushing = false;

  final _messageCtrl = StreamController<IncomingMessage>.broadcast();
  final _notificationCtrl = StreamController<IncomingMessage>.broadcast();
  final _typingCtrl = StreamController<String>.broadcast();
  final _statusCtrl = StreamController<UserStatusUpdate>.broadcast();
  final _deleteCtrl = StreamController<MessageDeletedEvent>.broadcast();
  final _messageStatusCtrl = StreamController<Map<String, dynamic>>.broadcast();
  // Миграция v1→v2: сервер отвечает upgrade_required переведённым аккаунтам и
  // отправителям, пишущим переведённому получателю. Это не ошибка сессии —
  // автоматическое восстановление не запускается, UI показывает честное
  // уведомление о необходимости перехода.
  final _upgradeCtrl = StreamController<String>.broadcast();
  bool _upgradeRequired = false;
  Stream<String> get upgradeRequiredEvents => _upgradeCtrl.stream;
  bool get upgradeRequired => _upgradeRequired;

  bool _isConnected = false;

  ConnectionService({
    required this.serverUrl,
    required CryptoService cryptoService,
    required DatabaseService databaseService,
  })  : _crypto = cryptoService,
        _db = databaseService,
        _httpClient = _createHttpClient(serverUrl) {
    if (Uri.parse(serverUrl).scheme != 'https') {
      throw ArgumentError('Shade relay requires HTTPS');
    }
  }

  Stream<bool> get connectionChanges => _connectionCtrl.stream;
  void _setConnected(bool value) {
    _isConnected = value;
    if (!_connectionCtrl.isClosed) _connectionCtrl.add(value);
  }

  // ── Server public key (cached) ─────────────────────────
  Future<String?> _getServerPublicKey() async {
    try {
      final response = await _retryGet(
        Uri.parse('$serverUrl/api/server/public-key'),
      );
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final publicKey = data['publicKey'] as String?;

        const pinnedFingerprint =
            String.fromEnvironment('SERVER_PUBLIC_KEY_FINGERPRINT');
        if (publicKey != null) {
          final verified = _verifyServerKeyPin(publicKey, pinnedFingerprint);
          if (!verified) {
            debugPrint(
                '[ConnectionService] Server key fingerprint MISMATCH - possible MitM!');
            return null;
          }
          final trust = await _crypto.checkServerKeyForConfirmation(publicKey,
              serverOrigin: serverUrl);
          if (trust.status != ServerKeyTrustStatus.trusted) {
            final callback = onServerKeyConfirmation;
            if (callback == null) return null;
            final confirmation = _confirmingServerKey ??= callback(trust);
            final accepted = await confirmation;
            _confirmingServerKey = null;
            if (!accepted ||
                trust.status !=
                    ServerKeyTrustStatus.newKeyRequiresConfirmation) {
              return null;
            }
            await _crypto.trustServerKey(trust.fingerprint,
                serverOrigin: serverUrl);
          }
          _serverPublicKey = publicKey;
          debugPrint(
              '[ConnectionService] Server public key cached and verified');
          return _serverPublicKey;
        }
      }
    } catch (e) {
      debugPrint('[ConnectionService] Failed to fetch server public key: $e');
    }
    return null;
  }

  /// Checks server key fingerprint for TOFU confirmation.
  /// Returns the result which can be used to show confirmation dialog.
  Future<ServerKeyFingerprintResult?> checkServerKeyForConfirmation() async {
    try {
      final response = await _retryGet(
        Uri.parse('$serverUrl/api/server/public-key'),
      );
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final publicKey = data['publicKey'] as String?;
        if (publicKey != null) {
          return await _crypto.checkServerKeyForConfirmation(publicKey,
              serverOrigin: serverUrl);
        }
      }
    } catch (e) {
      debugPrint('[ConnectionService] Failed to check server key: $e');
    }
    return null;
  }

  /// Trust the server key after user confirmation.
  Future<void> trustServerKey(String fingerprint) async {
    await _crypto.trustServerKey(fingerprint, serverOrigin: serverUrl);
  }

  // [FIX] CRIT #2: Verify server key fingerprint against pinned value
  bool _verifyServerKeyPin(String publicKey, String? pinnedFingerprint) {
    if (pinnedFingerprint == null || pinnedFingerprint.isEmpty) {
      debugPrint(
          '[ConnectionService] No pinned fingerprint - skipping verification');
      return true; // Allow if no pin configured
    }
    try {
      // Вычисляем SHA-256 fingerprint публичного ключа
      final lines = publicKey
          .split('\n')
          .where((l) =>
              !l.contains('BEGIN') && !l.contains('END') && l.trim().isNotEmpty)
          .join();
      final bytes = base64.decode(lines);
      final hash = sha256.convert(bytes);
      final fingerprint =
          hash.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(':');

      if (fingerprint != pinnedFingerprint) {
        debugPrint(
            '[ConnectionService] WARNING: Server key fingerprint MISMATCH!');
        debugPrint('  Expected: $pinnedFingerprint');
        debugPrint('  Got:      $fingerprint');
        return false;
      }
      debugPrint('[ConnectionService] Server key fingerprint verified');
      return true;
    } catch (e) {
      debugPrint('[ConnectionService] Error verifying server key: $e');
      return false;
    }
  }

  // ── Public API ──────────────────────────────────────

  Stream<IncomingMessage> get messages => _messageCtrl.stream;
  Stream<IncomingMessage> get notifications => _notificationCtrl.stream;
  Stream<String> get typing => _typingCtrl.stream;
  Stream<UserStatusUpdate> get statusUpdates => _statusCtrl.stream;
  Stream<MessageDeletedEvent> get messageDeleted => _deleteCtrl.stream;
  Stream<Map<String, dynamic>> get messageStatusUpdates =>
      _messageStatusCtrl.stream;
  bool get isConnected => _isConnected;
  String? get currentUsername => _username;
  String? get sessionToken => _sessionToken;

  /// Watch a user's online status (real-time via WebSocket).
  void watchUser(String username) {
    _watchedUsers.add(username);
    if (_socket != null && _isConnected) {
      _socket!.emit('watch', username);
    }
  }

  /// Stop watching a user's status.
  void unwatchUser(String username) {
    _watchedUsers.remove(username);
    if (_socket != null && _isConnected) {
      _socket!.emit('unwatch', username);
    }
  }

  /// Send read/delivered status for messages.
  Future<bool> sendMessageStatus(String type, String from,
      {List<String>? msgIds}) async {
    final socket = _socket;
    if (socket == null ||
        !_isConnected ||
        !['read', 'delivered'].contains(type) ||
        msgIds == null ||
        msgIds.isEmpty) {
      return false;
    }
    final response = Completer<dynamic>();
    socket.emitWithAck(type, {'from': from, 'msgIds': msgIds}, ack: (data) {
      if (!response.isCompleted) response.complete(data);
    });
    try {
      final data = await response.future.timeout(const Duration(seconds: 10));
      return data is Map &&
          data['ok'] == true &&
          data['msgIds'] is List &&
          msgIds.every((id) => (data['msgIds'] as List).contains(id));
    } catch (_) {
      return false;
    }
  }

  /// Delete a message for everyone.
  Future<bool> sendDeleteMessage(String to, String msgId) async {
    final socket = _socket;
    if (socket == null || !_isConnected) return false;
    final result = Completer<dynamic>();
    socket.emitWithAck(
        'deleteMessage', {'to': to, 'msgId': msgId, 'forEveryone': true},
        ack: (data) {
      if (!result.isCompleted) result.complete(data);
    });
    try {
      final data = await result.future.timeout(const Duration(seconds: 10));
      return data is Map && data['ok'] == true;
    } catch (_) {
      return false;
    }
  }

  // ── REST ────────────────────────────────────────────────────

  /// Registers the current user on the server.
  Future<Map<String, dynamic>> register(String username,
      {String? googleIdToken, bool automatic = false}) async {
    if (_isDisposed || (automatic && _signedOut)) {
      throw StateError('Session closed');
    }
    if (!automatic) {
      _signedOut = false;
      _sessionGeneration++;
    }
    final generation = _sessionGeneration;
    final publicKey = await _crypto.getPublicKey();
    if (publicKey == null) {
      throw StateError('No public key — generate identity first');
    }

    username = username.trim().toLowerCase();
    final signature = await _crypto.signPublicKey();
    final challengeResponse = await _retryPost(
        Uri.parse('$serverUrl/auth/challenge'),
        body: jsonEncode({'username': username}));
    if (challengeResponse.statusCode != 200) {
      throw StateError('Не удалось получить запрос входа. Повторите позже.');
    }
    final challenge = jsonDecode(challengeResponse.body)['challenge'] as String;
    final privateKey = await _crypto.getPrivateKey();
    if (privateKey == null) throw StateError('Identity keys not found');
    final proof = await _crypto.signData(
        'shade-register:v1:$username:$challenge', privateKey);

    final response = await _retryPost(
      Uri.parse('$serverUrl/register'),
      body: jsonEncode({
        'username': username,
        'publicKey': publicKey,
        'signature': signature,
        'challenge': challenge,
        'proof': proof,
        if (googleIdToken != null) 'googleIdToken': googleIdToken,
      }),
    );

    if (response.statusCode != 200) {
      final body = jsonDecode(response.body);
      throw Exception(
          body['error'] ?? 'Registration failed (${response.statusCode})');
    }

    final body = jsonDecode(response.body);
    if (_isDisposed || _signedOut || generation != _sessionGeneration) {
      throw StateError('Login was cancelled');
    }
    _username = username;
    _sessionToken = body['token'];
    return Map<String, dynamic>.from(body['profile'] as Map? ?? {});
  }

  /// Fetches the public key bundle for [username] and verifies the server signature.
  Future<PublicKeyBundle?> getPublicKey(String username) async {
    try {
      final response = await _retryGet(
        Uri.parse('$serverUrl/user/$username'),
      );
      if (response.statusCode != 200) return null;

      final json = jsonDecode(response.body) as Map<String, dynamic>;
      final bundle = PublicKeyBundle.fromJson(json);

      // User doesn't exist (server returns null publicKey for non-existent users)
      if (bundle.publicKey.isEmpty) {
        debugPrint('[ConnectionService] User not found: $username');
        return null;
      }

      // If server signature exists, verify it
      if (bundle.serverSignatureVersion == 3 &&
          bundle.serverSignature != null &&
          bundle.serverSignature!.isNotEmpty) {
        final serverPubKey = await _getServerPublicKey();
        if (serverPubKey != null) {
          final valid = await _crypto.verifyPublicKeySignature(
            bundle.publicKey,
            bundle.serverSignature!,
            serverPubKey,
            username: username,
            serverOrigin: serverUrl,
          );
          if (!valid) {
            debugPrint(
                '[ConnectionService] Invalid server signature for $username');
            return null;
          }
        } else {
          return null;
        }
      } else {
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
    if (_isDisposed || _signedOut) return;
    // Always disconnect old socket first
    if (_socket != null) {
      _socket!.disconnect();
      _socket!.dispose();
      _socket = null;
      _isConnected = false;
    }

    _username = username;

    HttpOverrides.runWithHttpOverrides(() {
      _socket = io.io(
        serverUrl,
        io.OptionBuilder()
            .setTransports(['websocket'])
            .disableAutoConnect()
            .enableForceNew()
            .setReconnectionAttempts(-1)
            .setReconnectionDelay(2000)
            .setReconnectionDelayMax(15000)
            .setTimeout(20000)
            .build(),
      );

      _socket!.onConnect((_) {
        _cancelReconnect();
        _socket!.emit('register', {
          'username': username,
          'token': _sessionToken ?? '',
        });
        debugPrint('[ConnectionService] WS connected');
      });

      _socket!.on('registered', (_) {
        _setConnected(true);
        _scheduleProfileWatches();
        for (final username in _watchedUsers) {
          _socket!.emit('watch', username);
        }
        unawaited(flushOutbox());
        _outboxTimer?.cancel();
        _outboxTimer =
            Timer.periodic(const Duration(seconds: 5), (_) => flushOutbox());
      });
      _socket!.on('sessionRefreshed', (data) {
        _sessionToken = (data as Map)['token'] as String;
        if (_username != null) {
          unawaited(NotificationService.registerToken(
              serverUrl, _username!, _sessionToken));
        }
      });
      _socket!.on('message', _handleIncomingMessage);
      _socket!.on('avatarUpdated', (data) {
        if (data is Map &&
            data['username'] is String &&
            !_avatarCtrl.isClosed) {
          _avatarCtrl.add(data['username'] as String);
        }
      });

      // Typing indicator events
      _socket!.on('typing', (data) {
        final from = (data as Map)['from'] as String;
        if (!_typingCtrl.isClosed) _typingCtrl.add(from);
      });

      _socket!.on('stopTyping', (data) {
        // The UI will handle the timeout
      });

      _socket!.on('messageStatus', (data) async {
        try {
          final map = Map<String, dynamic>.from(data as Map);
          final status = map['status'] as String? ?? 'sent';
          final msgId = map['msgId'] as String?;
          final from = map['from'] as String?;

          if (msgId != null) await _db.updateMessageStatus(msgId, status);
          if (!_messageStatusCtrl.isClosed) {
            _messageStatusCtrl
                .add({'status': status, 'msgId': msgId, 'from': from});
          }
        } catch (_) {}
      });

      _socket!.on('authError', (data) async {
        if (_signedOut || _isDisposed) return;
        final error = (data is Map ? data['error'] : null)?.toString();
        if (error == 'upgrade_required') {
          _upgradeRequired = true;
          _cancelReconnect();
          _sessionToken = null;
          disconnect();
          if (!_upgradeCtrl.isClosed) _upgradeCtrl.add('account');
          return;
        }
        final username = _username;
        final generation = _sessionGeneration;
        _sessionToken = null;
        disconnect();
        if (username == null) return;
        try {
          await register(username, automatic: true);
          if (!_signedOut && !_isDisposed && generation == _sessionGeneration) {
            connect(username);
          }
        } catch (_) {
          debugPrint('[ConnectionService] Session recovery unavailable');
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

      _socket!.on('messageDeleted', (data) async {
        try {
          final event = MessageDeletedEvent.fromJson(
            Map<String, dynamic>.from(data as Map),
          );
          await _db.deleteIncomingMessage(event.from, event.msgId);
          if (!_deleteCtrl.isClosed) _deleteCtrl.add(event);
        } catch (_) {}
      });

      _socket!.onDisconnect((reason) {
        _setConnected(false);
        _outboxTimer?.cancel();
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
    }, ShadeHttpOverrides(Uri.parse(serverUrl), _certificateDigest));
  }

  /// Retries durable outgoing ciphertext with the SAME network ID after a
  /// disconnect/ACK loss. Server deduplication makes this safe.
  Future<void> flushOutbox() async {
    if (_flushing || !_isConnected || _socket == null) return;
    _flushing = true;
    try {
      for (final row in await _db.getOutbox()) {
        if (!_isConnected || _socket == null) break;
        if (!await _db.isPendingMessage(row['network_id'] as String)) continue;
        if (!_isConnected || _socket == null) break;
        final result = Completer<dynamic>();
        _socket!.emitWithAck('message', {
          'id': row['network_id'],
          'to': row['recipient'],
          'data': row['payload'],
        }, ack: (data) {
          if (!result.isCompleted) result.complete(data);
        });
        final ack = await result.future.timeout(const Duration(seconds: 10));
        if (ack is! Map || ack['ok'] != true) {
          if (ack is Map && ack['error'] == 'upgrade_required') {
            // Получатель переведён на v2: сообщение не доставлено и не будет
            // доставлено по v1. Честный статус вместо вечного ожидания.
            await _db.updateMessageStatus(
                row['network_id'] as String, 'upgrade_required');
            if (!_upgradeCtrl.isClosed) _upgradeCtrl.add('peer');
          }
          break;
        }
        final id = row['network_id'] as String;
        final status = ack['status'] as String? ?? 'sent';
        await _db.updateMessageStatus(id, status);
        if (!_messageStatusCtrl.isClosed) {
          _messageStatusCtrl
              .add({'msgId': id, 'status': status, 'from': row['recipient']});
        }
      }
    } catch (e) {
      debugPrint('[ConnectionService] Outbox retained for retry: $e');
    } finally {
      _flushing = false;
    }
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

  Future<void> signOut() async {
    _signedOut = true;
    _profileUploads.cancelAll();
    _sessionGeneration++;
    final token = _sessionToken, username = _username;
    disconnect();
    _sessionToken = null;
    _username = null;
    try {
      if (token != null && username != null) {
        await _httpClient.post(Uri.parse('$serverUrl/logout'), headers: {
          'x-session-token': token,
          'x-username': username,
        }).timeout(const Duration(seconds: 5));
      }
    } catch (_) {
      debugPrint('[ConnectionService] Remote logout could not be confirmed');
    }
  }

  void disconnect() {
    _cancelReconnect();
    _outboxTimer?.cancel();
    _socket?.disconnect();
    _socket?.dispose();
    _socket = null;
    _setConnected(false);
  }

  void dispose() {
    _isDisposed = true;
    disconnect();
    _httpClient.close();
    _profileUploads.cancelAll();
    _profileWatchTimer?.cancel();
    _avatarCtrl.close();
    _connectionCtrl.close();
    _messageCtrl.close();
    _notificationCtrl.close();
    _typingCtrl.close();
    _statusCtrl.close();
    _deleteCtrl.close();
    _messageStatusCtrl.close();
    _upgradeCtrl.close();
  }

  // ── Incoming message handler ────────────────────────────────

  /// Saves incoming message to DB, then broadcasts to UI listeners.
  Future<void> _handleIncomingMessage(dynamic raw) async {
    if (_signedOut || _isDisposed) return;
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

      if (await _db.hasNetworkMessage(msg.id, sender: msg.from)) {
        sendMessageStatus('delivered', msg.from, msgIds: [msg.id]);
        return;
      }
      // Persist into encrypted DB
      final convId = await ensureConversation(msg.from);
      await _db.insertMessage(
        conversationId: convId,
        senderId: msg.from.hashCode.abs(),
        encryptedContent: msg.data,
        networkId: msg.id,
        networkSender: msg.from,
        timestamp: msg.timestamp.millisecondsSinceEpoch,
      );

      sendMessageStatus('delivered', msg.from, msgIds: [msg.id]);

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

  Future<int> ensureConversation(String withUser) async {
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
    if (_isDisposed || _upgradeRequired) return;
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

  Future<Map<String, dynamic>> saveAvatarProfile(Map<String, dynamic> data,
      {void Function(double)? onProgress}) async {
    final owner = _username, generation = _sessionGeneration;
    final random = math.Random.secure();
    final uploadId =
        base64UrlEncode(List<int>.generate(18, (_) => random.nextInt(256)));
    final payload = {...data, 'uploadId': uploadId};
    try {
      return await profileRequest('PUT', '/profile/avatar', payload);
    } catch (e) {
      if (data['image'] is! String ||
          !(e is TimeoutException ||
              e is SocketException ||
              e is HttpException ||
              e is http.ClientException)) {
        rethrow;
      }
    }
    final image = data['image'] as String;
    final elapsed = Stopwatch()..start();
    var offset = 0;
    while (offset < image.length) {
      if (_signedOut ||
          _isDisposed ||
          owner != _username ||
          generation != _sessionGeneration) {
        throw StateError('Сеанс завершён');
      }
      if (elapsed.elapsed > const Duration(minutes: 2)) {
        throw TimeoutException('Загрузка фото заняла слишком много времени');
      }
      final end = math.min(offset + 32768, image.length);
      final part = {
        'uploadId': uploadId,
        'offset': offset,
        'total': image.length,
        'chunk': image.substring(offset, end),
        'frame': data['frame'],
        'revision': data['revision']
      };
      Map<String, dynamic> result;
      try {
        result = await profileRequest('POST', '/profile/avatar/chunk', part);
      } catch (e) {
        if (!(e is TimeoutException ||
            e is SocketException ||
            e is HttpException ||
            e is http.ClientException)) {
          rethrow;
        }
        // Parts are idempotent, including a retried final commit.
        result = await profileRequest('POST', '/profile/avatar/chunk', part);
      }
      if (result['complete'] == true) {
        onProgress?.call(1);
        return {
          ...Map<String, dynamic>.from(result['profile'] as Map),
          'image': image
        };
      }
      final next = result['offset'];
      if (next is! int || next != end) {
        throw StateError('Сервер не подтвердил загрузку фото');
      }
      offset = next;
      onProgress?.call(offset / image.length);
    }
    throw StateError('Сервер не подтвердил сохранение фото');
  }

  Future<Map<String, dynamic>> profileRequest(String method, String path,
      [Map<String, dynamic>? data]) async {
    if (_sessionToken == null || _username == null) {
      throw StateError('Требуется подключение к серверу');
    }
    final generation = _sessionGeneration;
    final request = http.Request(method, Uri.parse('$serverUrl$path'))
      ..followRedirects = false;
    request.headers.addAll({
      'Content-Type': 'application/json',
      'x-session-token': _sessionToken!,
      'x-username': _username!
    });
    if (data != null) request.body = jsonEncode(data);
    final response =
        path.startsWith('/profile/avatar')
            ? await _profileUploads.send(request)
            : await _httpClient
                .send(request)
                .then(http.Response.fromStream)
                .timeout(const Duration(seconds: 15));
    if (generation != _sessionGeneration || _signedOut || _isDisposed) {
      throw StateError('Сеанс завершён');
    }
    Map<String, dynamic> result;
    try {
      result = jsonDecode(response.body) as Map<String, dynamic>;
    } catch (_) {
      throw StateError('Сервер временно недоступен');
    }
    if (response.statusCode != 200) {
      throw StateError(result['error']?.toString() ?? 'Ошибка сервера');
    }
    return result;
  }

  Future<http.Response> _retryGet(Uri uri) async {
    for (var i = 0; i < _maxRetries; i++) {
      try {
        final headers = <String, String>{};
        if (_sessionToken != null && _username != null) {
          headers['x-session-token'] = _sessionToken!;
          headers['x-username'] = _username!;
        }
        return await _httpClient
            .get(uri, headers: headers)
            .timeout(const Duration(seconds: 15));
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
  defaultValue: 'https://45.81.255.81:3443',
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
