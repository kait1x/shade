import 'dart:async';
import 'dart:convert';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:http/io_client.dart';
import 'package:shade/core/services/tls_policy.dart';

/// Local IDs use their decimal representation; remote notifications use user:<nick>.
typedef NotificationTapCallback = void Function(String target);

class NotificationService {
  static final _localPlugin = FlutterLocalNotificationsPlugin();
  static final List<StreamSubscription<dynamic>> _subscriptions = [];
  static String? _fcmToken;
  static bool _initialized = false;
  static Future<void>? _initializing;
  static int _epoch = 0;
  static NotificationTapCallback? _onTap;
  static String? _pendingTap;
  static String? _serverUrl, _username, _sessionToken;
  static String? get fcmToken => _fcmToken;

  static void setTapHandler(NotificationTapCallback? callback) {
    _onTap = callback;
    if (callback != null && _pendingTap != null) {
      final target = _pendingTap!;
      _pendingTap = null;
      scheduleMicrotask(() {
        if (_onTap == callback) callback(target);
      });
    }
  }

  static void _dispatchTap(String? target) {
    if (target == null || target.isEmpty) return;
    if (_onTap != null) {
      _onTap!(target);
    } else {
      _pendingTap = target;
    }
  }

  static String? targetForData(Map<String, dynamic> data) {
    final from = data['from'];
    return from is String && RegExp(r'^[a-z0-9_]{3,32}$').hasMatch(from)
        ? 'user:$from'
        : null;
  }

  static Future<void> init() async {
    if (_initialized) return;
    if (_initializing != null) return _initializing;
    final epoch = _epoch;
    _initializing = _initialize(epoch);
    try {
      await _initializing;
    } finally {
      if (_epoch == epoch) _initializing = null;
    }
  }

  static Future<void> _initialize(int epoch) async {
    await _localPlugin.initialize(
        const InitializationSettings(
            android: AndroidInitializationSettings('@mipmap/ic_launcher'),
            iOS: DarwinInitializationSettings()),
        onDidReceiveNotificationResponse: (response) {
      if (epoch == _epoch) _dispatchTap(response.payload);
    });
    final launch = await _localPlugin.getNotificationAppLaunchDetails();
    if (epoch != _epoch) return;
    if (launch?.didNotificationLaunchApp == true) {
      _dispatchTap(launch?.notificationResponse?.payload);
    }
    const channel = AndroidNotificationChannel('shade_messages', 'Messages',
        description: 'Incoming messages', importance: Importance.high);
    await _localPlugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(channel);
    try {
      await Firebase.initializeApp();
      if (epoch != _epoch) return;
      final messaging = FirebaseMessaging.instance;
      final permission = await messaging.requestPermission();
      if (epoch != _epoch) return;
      if (permission.authorizationStatus != AuthorizationStatus.denied) {
        _fcmToken = await messaging.getToken();
        if (epoch != _epoch) return;
        _subscriptions.add(messaging.onTokenRefresh.listen((token) {
          if (epoch != _epoch) return;
          _fcmToken = token;
          unawaited(_registerCurrentToken());
        }));
        _subscriptions.add(FirebaseMessaging.onMessage.listen((message) {
          if (epoch != _epoch) return;
          unawaited(_showLocalNotification(
              title: 'Shade',
              body: 'Новое сообщение',
              payload: targetForData(message.data)));
        }));
        _subscriptions
            .add(FirebaseMessaging.onMessageOpenedApp.listen((message) {
          if (epoch == _epoch) _dispatchTap(targetForData(message.data));
        }));
        final initial = await messaging.getInitialMessage();
        if (epoch != _epoch) return;
        if (initial != null) _dispatchTap(targetForData(initial.data));
        await _registerCurrentToken();
      }
    } catch (_) {
      debugPrint(
          '[NotificationService] Push unavailable; local notifications remain available');
    }
    if (epoch == _epoch) _initialized = true;
  }

  /// FCM needs the original device token. TLS protects transport and the relay
  /// encrypts token storage; no incompatible extra RSA envelope is transmitted.
  static Future<void> registerToken(String serverUrl, String username,
      [String? sessionToken]) async {
    _serverUrl = serverUrl;
    _username = username;
    _sessionToken = sessionToken;
    await _registerCurrentToken();
  }

  static Future<bool> _registerCurrentToken() async {
    final url = _serverUrl,
        username = _username,
        session = _sessionToken,
        token = _fcmToken;
    if (url == null || username == null || session == null || token == null) {
      return false;
    }
    return _tokenRequest(url, username, session, token, 'register');
  }

  static Future<bool> _tokenRequest(String url, String username, String session,
      String token, String action) async {
    if (Uri.parse(url).scheme != 'https') return false;
    final client = IOClient(ShadeHttpOverrides(
            Uri.parse(url), const String.fromEnvironment('TLS_CERT_SHA256'))
        .createHttpClient(null));
    try {
      final response = await client
          .post(Uri.parse('$url/fcm/$action'),
              headers: {
                'Content-Type': 'application/json',
                'x-session-token': session,
                'x-username': username
              },
              body: jsonEncode({'token': token, 'format': 'fcm-v1'}))
          .timeout(const Duration(seconds: 10));
      return response.statusCode == 200;
    } catch (_) {
      return false;
    } finally {
      client.close();
    }
  }

  static Future<void> showMessageNotification(
          {required String from, required String conversationId}) =>
      _showLocalNotification(
          title: 'Shade',
          body: 'Новое сообщение от $from',
          payload: conversationId);

  static Future<void> _showLocalNotification(
      {required String title, required String body, String? payload}) async {
    if (!_initialized && _initializing == null) return;
    try {
      await _localPlugin.show(
          payload?.hashCode ?? 0,
          title,
          body,
          const NotificationDetails(
              android: AndroidNotificationDetails('shade_messages', 'Messages',
                  channelDescription: 'Incoming messages',
                  importance: Importance.high,
                  priority: Priority.high),
              iOS: DarwinNotificationDetails()),
          payload: payload);
    } catch (_) {
      debugPrint('[NotificationService] Local notification unavailable');
    }
  }

  static Future<void> cancelForConversation(String conversationId) =>
      _localPlugin.cancel(conversationId.hashCode);
  static Future<void> cancelAll() => _localPlugin.cancelAll();

  static Future<void> unregisterToken(
      String serverUrl, String? username) async {
    final token = _fcmToken, session = _sessionToken;
    if (token != null && session != null && username != null) {
      await _tokenRequest(serverUrl, username, session, token, 'unregister');
    }
  }

  static Future<void> dispose() async {
    _epoch++;
    final subscriptions = List<StreamSubscription<dynamic>>.of(_subscriptions);
    _subscriptions.clear();
    _fcmToken = null;
    _serverUrl = null;
    _username = null;
    _sessionToken = null;
    _initialized = false;
    _initializing = null;
    _onTap = null;
    _pendingTap = null;
    await Future.wait(
        subscriptions.map((subscription) => subscription.cancel()));
    await cancelAll();
  }
}

/// Notification payloads are displayed by Android/iOS while backgrounded.
@pragma('vm:entry-point')
Future<void> handleBackgroundMessage(RemoteMessage message) async {
  await Firebase.initializeApp();
}
