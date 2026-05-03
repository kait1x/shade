import 'dart:convert';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:http/http.dart' as http;

/// Callback when user taps a notification. Payload = conversationId.
typedef NotificationTapCallback = void Function(String conversationId);

/// Combined notification service: Firebase FCM + local notifications.
///
/// - FCM: works when app is fully closed (requires Firebase)
/// - Local: works when app is in background (no external services)
///
/// This gives maximum reliability while keeping setup simple.
class NotificationService {
  static final FlutterLocalNotificationsPlugin _localPlugin =
      FlutterLocalNotificationsPlugin();

  static String? _fcmToken;
  static bool _initialized = false;
  static NotificationTapCallback? _onTap;

  static String? get fcmToken => _fcmToken;

  /// Set callback for notification taps.
  static void setTapHandler(NotificationTapCallback callback) {
    _onTap = callback;
  }

  /// Initialize both local notifications and Firebase FCM.
  /// Call once at app startup (after user authentication).
  static Future<void> init() async {
    if (_initialized) return;

    // ── Local notifications ─────────────────────────────────
    const androidSettings =
        AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosSettings = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );
    const settings = InitializationSettings(
      android: androidSettings,
      iOS: iosSettings,
    );

    await _localPlugin.initialize(
      settings,
      onDidReceiveNotificationResponse: (response) {
        final payload = response.payload;
        if (payload != null && payload.isNotEmpty && _onTap != null) {
          _onTap!(payload);
        }
      },
    );
    debugPrint('[NotificationService] Local notifications initialized');

    // ── Firebase FCM ────────────────────────────────────────
    try {
      await Firebase.initializeApp();

      final messaging = FirebaseMessaging.instance;

      final fcmSettings = await messaging.requestPermission(
        alert: true,
        badge: true,
        sound: true,
      );

      if (fcmSettings.authorizationStatus == AuthorizationStatus.denied) {
        debugPrint('[NotificationService] FCM permission denied');
      } else {
        _fcmToken = await messaging.getToken();
        debugPrint('[NotificationService] FCM token registered');

        messaging.onTokenRefresh.listen((token) {
          _fcmToken = token;
          debugPrint('[NotificationService] FCM token refreshed');
        });

        // Show local notification for foreground FCM messages
        FirebaseMessaging.onMessage.listen((message) {
          _showLocalNotification(
            title: 'Shade',
            body: 'Новое сообщение',
            payload: message.data['conversationId']?.toString(),
          );
        });

        // Handle notification tap when app was terminated
        messaging.getInitialMessage().then((message) {
          if (message != null) {
            final convId = message.data['conversationId']?.toString();
            if (convId != null && _onTap != null) {
              _onTap!(convId);
            }
          }
        });

        // Handle notification tap when app is in background
        FirebaseMessaging.onMessageOpenedApp.listen((message) {
          final convId = message.data['conversationId']?.toString();
          if (convId != null && _onTap != null) {
            _onTap!(convId);
          }
        });

        debugPrint('[NotificationService] FCM initialized');
      }
    } catch (e) {
      debugPrint('[NotificationService] FCM init failed: $e');
    }

    _initialized = true;
  }

  /// Register FCM token with Shade server.
  static Future<void> registerToken(String serverUrl, String username) async {
    if (_fcmToken == null) return;

    try {
      await http.post(
        Uri.parse('$serverUrl/fcm/register'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'username': username,
          'token': _fcmToken,
        }),
      );
      debugPrint('[NotificationService] FCM token registered');
    } catch (e) {
      debugPrint('[NotificationService] Token registration failed: $e');
    }
  }

  /// Show a local notification (works without FCM).
  static Future<void> showMessageNotification({
    required String from,
    required String conversationId,
  }) async {
    await _showLocalNotification(
      title: 'Shade',
      body: 'Новое сообщение от $from',
      payload: conversationId,
    );
  }

  static Future<void> _showLocalNotification({
    required String title,
    required String body,
    String? payload,
  }) async {
    const androidDetails = AndroidNotificationDetails(
      'shade_messages',
      'Messages',
      channelDescription: 'Incoming messages',
      importance: Importance.high,
      priority: Priority.high,
      showWhen: true,
    );

    const iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
    );

    const details = NotificationDetails(
      android: androidDetails,
      iOS: iosDetails,
    );

    await _localPlugin.show(
      payload?.hashCode ?? 0,
      title,
      body,
      details,
      payload: payload,
    );
  }

  /// Cancel notifications for a specific conversation.
  static Future<void> cancelForConversation(String conversationId) async {
    await _localPlugin.cancel(conversationId.hashCode);
  }

  /// Cancel all notifications.
  static Future<void> cancelAll() async {
    await _localPlugin.cancelAll();
  }

  /// Unregister FCM token from Shade server (called during logout).
  static Future<void> unregisterToken(String serverUrl, String? username) async {
    if (_fcmToken == null || username == null) return;

    try {
      await http.post(
        Uri.parse('$serverUrl/fcm/unregister'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'username': username,
          'token': _fcmToken,
        }),
      );
      debugPrint('[NotificationService] FCM token unregistered');
    } catch (e) {
      debugPrint('[NotificationService] Token unregister failed (non-fatal): $e');
    }
  }

  /// Dispose the notification service (called during logout).
  /// 
  /// This cancels all pending notifications and resets the service state.
  static Future<void> dispose() async {
    await cancelAll();
    _fcmToken = null;
    _initialized = false;
    _onTap = null;
    debugPrint('[NotificationService] Disposed');
  }
}

/// Background message handler (must be top-level)
@pragma('vm:entry-point')
Future<void> handleBackgroundMessage(RemoteMessage message) async {
  await Firebase.initializeApp();
}
