import 'package:flutter/foundation.dart';

/// Placeholder for Firebase Cloud Messaging integration.
///
/// To activate:
/// 1. Create a Firebase project at https://console.firebase.google.com
/// 2. Add google-services.json (Android) / GoogleService-Info.plist (iOS)
/// 3. Uncomment the Firebase code below
/// 4. Add firebase_core and firebase_messaging to pubspec.yaml
class FcmService {
  static String? _token;

  static String? get token => _token;

  /// Initialize FCM and request permissions.
  /// Call this after user authentication.
  static Future<void> init() async {
    // TODO: Uncomment when Firebase is configured
    // await Firebase.initializeApp();
    // final messaging = FirebaseMessaging.instance;
    // await messaging.requestPermission(alert: true, badge: true, sound: true);
    // _token = await messaging.getToken();
    // debugPrint('[FCM] Token: $_token');
    // 
    // // Listen for token refresh
    // messaging.onTokenRefresh.listen((newToken) {
    //   _token = newToken;
    //   debugPrint('[FCM] Token refreshed: $newToken');
    //   // TODO: Send new token to server
    // });
    // 
    // // Handle foreground messages
    // FirebaseMessaging.onMessage.listen((RemoteMessage message) {
    //   debugPrint('[FCM] Foreground message: ${message.notification?.title}');
    //   // NotificationOverlay will handle showing the notification
    // });
    debugPrint('[FCM] Placeholder — Firebase not configured');
  }

  /// Register token with the Shade server.
  static Future<void> registerToken(String serverUrl, String username) async {
    if (_token == null) return;
    // TODO: POST token to server
    // await http.post(
    //   Uri.parse('$serverUrl/fcm/register'),
    //   body: jsonEncode({'username': username, 'token': _token}),
    // );
    debugPrint('[FCM] Would register token for $username');
  }
}
