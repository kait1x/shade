import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Сервис для управления безопасностью приложения
/// Защита от скриншотов, записи экрана и превью в многозадачности
class SecurityService {
  static const MethodChannel _channel = MethodChannel('com.shade.app/security');

  /// Включить защиту от скриншотов и записи экрана
  /// 
  /// На Android: устанавливает флаг FLAG_SECURE
  /// На iOS: делает снимок экрана размытым (через UIWindow)
  static Future<void> enableSecureMode() async {
    try {
      await _channel.invokeMethod('enableSecureMode');
    } on PlatformException catch (e) {
      debugPrint('Failed to enable secure mode: ${e.message}');
    }
  }

  /// Отключить защиту от скриншотов
  static Future<void> disableSecureMode() async {
    try {
      await _channel.invokeMethod('disableSecureMode');
    } on PlatformException catch (e) {
      debugPrint('Failed to disable secure mode: ${e.message}');
    }
  }

  /// Скрыть приложение из списка недавних (превью)
  /// 
  /// На Android: устанавливает FLAG_excludeFromRecents
  static Future<void> excludeFromRecents() async {
    try {
      await _channel.invokeMethod('excludeFromRecents');
    } on PlatformException catch (e) {
      debugPrint('Failed to exclude from recents: ${e.message}');
    }
  }
}
