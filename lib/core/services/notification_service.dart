import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Local notification service — works without Firebase/Google/Apple.
///
/// Shows system notifications when messages arrive:
/// - Android: notification in status bar
/// - iOS: notification in Notification Center
/// - Windows: toast notification
///
/// No external services required. 100% local. 100% anonymous.
class NotificationService {
  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  static bool _initialized = false;

  /// Initialize the notification service.
  /// Call once at app startup.
  static Future<void> init() async {
    if (_initialized) return;

    // Android settings
    const androidSettings =
        AndroidInitializationSettings('@mipmap/ic_launcher');

    // iOS settings
    const iosSettings = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );

    const settings = InitializationSettings(
      android: androidSettings,
      iOS: iosSettings,
    );

    await _plugin.initialize(
      settings,
      onDidReceiveNotificationResponse: _onNotificationTap,
    );

    // Request iOS permissions
    await _plugin
        .resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin>()
        ?.requestPermissions(alert: true, badge: true, sound: true);

    _initialized = true;
    debugPrint('[NotificationService] Initialized');
  }

  /// Show a notification for an incoming message.
  static Future<void> showMessageNotification({
    required String from,
    required String conversationId,
  }) async {
    if (!_initialized) await init();

    const androidDetails = AndroidNotificationDetails(
      'shade_messages',
      'Messages',
      channelDescription: 'Incoming messages',
      importance: Importance.high,
      priority: Priority.high,
      showWhen: true,
      icon: '@mipmap/ic_launcher',
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

    await _plugin.show(
      conversationId.hashCode, // unique id per conversation
      'Shade',
      'Новое сообщение от $from',
      details,
      payload: conversationId,
    );

    debugPrint('[NotificationService] Showed notification from $from');
  }

  /// Handle notification tap — navigate to chat.
  static void _onNotificationTap(NotificationResponse response) {
    final conversationId = response.payload;
    if (conversationId != null) {
      debugPrint('[NotificationService] Tapped: $conversationId');
      // TODO: Navigate to chat screen using GoRouter
    }
  }

  /// Cancel all notifications.
  static Future<void> cancelAll() async {
    await _plugin.cancelAll();
  }

  /// Cancel notification for a specific conversation.
  static Future<void> cancel(String conversationId) async {
    await _plugin.cancel(conversationId.hashCode);
  }
}
