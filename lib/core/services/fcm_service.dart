import 'dart:convert';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// Firebase Cloud Messaging service for push notifications.
///
/// Handles:
/// - FCM token generation and refresh
/// - Token registration with Shade server
/// - Foreground message display
/// - Background message handling
class FcmService {
  static String? _token;
  static String? _serverUrl;

  static String? get token => _token;

  /// Initialize Firebase and FCM.
  /// Call once at app startup.
  static Future<void> init() async {
    await Firebase.initializeApp();

    final messaging = FirebaseMessaging.instance;

    // Request permission
    final settings = await messaging.requestPermission(
      alert: true,
      badge: true,
      sound: true,
      provisional: false,
    );

    if (settings.authorizationStatus == AuthorizationStatus.denied) {
      debugPrint('[FCM] Permission denied');
      return;
    }

    debugPrint('[FCM] Permission granted');

    // Get token
    _token = await messaging.getToken();
    debugPrint('[FCM] Token: ${_token?.substring(0, 20)}...');

    // Listen for token refresh
    messaging.onTokenRefresh.listen((newToken) {
      _token = newToken;
      debugPrint('[FCM] Token refreshed');
      _registerTokenWithServer();
    });

    // Handle foreground messages
    FirebaseMessaging.onMessage.listen(_handleForegroundMessage);

    // Handle background messages
    FirebaseMessaging.onBackgroundMessage(_handleBackgroundMessage);

    // Handle notification tap
    FirebaseMessaging.onMessageOpenedApp.listen(_handleNotificationTap);
  }

  /// Register FCM token with Shade server.
  static Future<void> registerToken(String serverUrl, String username) async {
    _serverUrl = serverUrl;
    if (_token == null) {
      debugPrint('[FCM] No token to register');
      return;
    }

    try {
      final response = await http.post(
        Uri.parse('$serverUrl/fcm/register'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'username': username,
          'token': _token,
        }),
      );

      if (response.statusCode == 200) {
        debugPrint('[FCM] Token registered for $username');
      } else {
        debugPrint('[FCM] Registration failed: ${response.statusCode}');
      }
    } catch (e) {
      debugPrint('[FCM] Registration error: $e');
    }
  }

  static Future<void> _registerTokenWithServer() async {
    if (_serverUrl == null || _token == null) return;
    // Re-register on token refresh
    debugPrint('[FCM] Re-registering token');
  }

  static void _handleForegroundMessage(RemoteMessage message) {
    debugPrint('[FCM] Foreground: ${message.notification?.title}');
    // NotificationOverlay handles displaying
  }

  static void _handleNotificationTap(RemoteMessage message) {
    debugPrint('[FCM] Notification tapped: ${message.data}');
    // TODO: Navigate to chat
  }
}

/// Background message handler (must be top-level function)
@pragma('vm:entry-point')
Future<void> _handleBackgroundMessage(RemoteMessage message) async {
  await Firebase.initializeApp();
  debugPrint('[FCM] Background: ${message.notification?.title}');
}
