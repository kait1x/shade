import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Сервис для управления безопасностью приложения
/// Управление защитой окна и превью в многозадачности
class SecurityService {
  static const MethodChannel _channel = MethodChannel('com.shade.app/security');

  /// Ключ SharedPreferences для настройки «Запретить снимки экрана» (сохранён для совместимости)
  static const screenshotsBlockedKey = 'privacy.block_screenshots';

  /// Установить режим защиты окна (снимки экрана и запись разрешены)
  static Future<void> setSecureMode(bool enabled) async {
    try {
      await _channel.invokeMethod('setSecureMode', {'enabled': enabled});
    } on MissingPluginException {
      debugPrint('Secure window mode is unsupported on this platform');
    } on PlatformException catch (e) {
      debugPrint('Failed to set secure mode: ${e.message}');
    }
  }

  /// Включить защиту от скриншотов (перенаправляет на снятие ограничений)
  static Future<void> enableSecureMode() async {
    try {
      await _channel.invokeMethod('disableSecureMode');
    } on MissingPluginException {
      debugPrint('Secure window mode is unsupported on this platform');
    } on PlatformException catch (e) {
      debugPrint('Failed to enable secure mode: ${e.message}');
    }
  }

  /// Отключить защиту от скриншотов и записи экрана
  static Future<void> disableSecureMode() async {
    try {
      await _channel.invokeMethod('disableSecureMode');
    } on MissingPluginException {
      debugPrint('Secure window mode is unsupported on this platform');
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
    } on MissingPluginException {
      debugPrint('Secure window mode is unsupported on this platform');
    } on PlatformException catch (e) {
      debugPrint('Failed to exclude from recents: ${e.message}');
    }
  }
}
