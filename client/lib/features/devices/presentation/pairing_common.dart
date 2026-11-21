import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/services/device_v2/protocol.dart';
import '../../../core/services/device_v2/transport.dart';
import '../../../core/theme/shade_theme.dart';

/// Общие элементы экранов pairing: честные русские ошибки, карточки кодов
/// для буфера обмена, кнопки и поля в токенах Shade AMOLED.

/// Текст ошибки для пользователя: причины протокола уже русские; служебные
/// английские причины и транспортные коды переводятся без выдуманных деталей.
String pairingErrorText(Object error) {
  if (error is ProtocolException) {
    const translations = {
      'Unsupported RSA key':
          'Ключ устройства не соответствует требованиям протокола (RSA-4096).',
      'Invalid protocol data': 'Неверный формат данных подключения.',
      'Unexpected fields': 'Неверный формат данных подключения.',
      'Invalid pairing challenge': 'Неверный код подключения.',
      'Duplicate or unordered devices': 'Неверный ростер устройств.',
    };
    return translations[error.reason] ?? error.reason;
  }
  if (error is StateError) return error.message;
  if (error is AlphaTransportException) {
    switch (error.code) {
      case 'login_required':
        return 'Сессия истекла. Войдите в аккаунт заново.';
      case 'device_auth_required':
        return 'Сервер отклонил proof устройства. Создайте запрос подключения заново.';
      case 'rate_limited':
        return 'Слишком много попыток. Подождите минуту и повторите.';
      default:
        return 'Сервер отклонил запрос (${error.code}). Повторите попытку.';
    }
  }
  if (error is SocketException ||
      error is HandshakeException ||
      error is TimeoutException) {
    return 'Нет связи с сервером. Проверьте сеть и повторите.';
  }
  if (error is FormatException) return 'Неверный формат кода подключения.';
  return 'Не удалось выполнить подключение: $error';
}

/// Оставшееся время действия кода: 'мм:сс' или 'истёк'.
String pairingRemaining(int expiresAt, int now) {
  final ms = expiresAt - now;
  if (ms <= 0) return 'истёк';
  final totalSeconds = (ms + 999) ~/ 1000;
  final minutes = totalSeconds ~/ 60;
  final seconds = totalSeconds % 60;
  return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
}

class PairingErrorBanner extends StatelessWidget {
  final String message;
  const PairingErrorBanner(this.message, {super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
        width: double.infinity,
        margin: const EdgeInsets.only(bottom: 16),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
            color: ShadeColors.surfaceCard,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0xFFEF4444).withValues(alpha: .5))),
        child: Text(message,
            style: const TextStyle(
                color: Color(0xFFEF4444), fontSize: 12.5, height: 1.4)));
  }
}

/// Карточка кода/длинного значения: моноширинный выделяемый текст + копирование
/// в буфер обмена (транспорт pairing — обычный буфер обмена).
class PairingCodeCard extends StatelessWidget {
  final String label;
  final String value;
  final double fontSize;
  const PairingCodeCard(
      {super.key, required this.label, required this.value, this.fontSize = 13});

  @override
  Widget build(BuildContext context) {
    return Semantics(
        label: label,
        value: value,
        container: true,
        child: Container(
            width: double.infinity,
            margin: const EdgeInsets.only(bottom: 16),
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
            decoration: BoxDecoration(
                color: ShadeColors.surfaceCard,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: ShadeColors.greyBorder)),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(
                  // Визуальная подпись/код не дублируют semantics-узел карточки.
                  child: ExcludeSemantics(
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                    Text(label,
                        style: const TextStyle(
                            color: ShadeColors.textSecondary, fontSize: 12)),
                    const SizedBox(height: 6),
                    SelectableText(value,
                        style: TextStyle(
                            color: ShadeColors.textPrimary,
                            fontFamily: 'monospace',
                            fontSize: fontSize,
                            height: 1.45))
                  ]))),
              IconButton(
                  tooltip: 'Скопировать',
                  icon: const Icon(Icons.copy_rounded,
                      size: 18, color: ShadeColors.textSecondary),
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: value));
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                          content: Text('Скопировано'),
                          duration: Duration(seconds: 2)));
                    }
                  })
            ])));
  }
}

InputDecoration pairingInputDecoration(String label, {String? hint}) {
  return InputDecoration(
      labelText: label,
      hintText: hint,
      labelStyle: const TextStyle(color: ShadeColors.textSecondary),
      hintStyle: const TextStyle(color: ShadeColors.textMuted),
      enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: ShadeColors.greyBorder)),
      focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: ShadeColors.textMuted)));
}

class PairingPrimaryButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  final bool busy;
  const PairingPrimaryButton(
      {super.key, required this.label, required this.onPressed, this.busy = false});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
        width: double.infinity,
        height: 48,
        child: FilledButton(
            onPressed: busy ? null : onPressed,
            style: FilledButton.styleFrom(
                backgroundColor: ShadeColors.surfaceElevated,
                foregroundColor: ShadeColors.textPrimary,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                    side: const BorderSide(color: ShadeColors.greyBorder))),
            child: busy
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: ShadeColors.textSecondary))
                : Text(label, style: const TextStyle(fontSize: 14))));
  }
}

/// Заголовок раздела экрана pairing.
class PairingHeading extends StatelessWidget {
  final String title;
  final String description;
  const PairingHeading(
      {super.key, required this.title, required this.description});

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(title,
          style: const TextStyle(
              color: ShadeColors.textPrimary,
              fontSize: 20,
              fontWeight: FontWeight.w600)),
      const SizedBox(height: 8),
      Text(description,
          style: const TextStyle(
              color: ShadeColors.textSecondary, fontSize: 13, height: 1.5)),
      const SizedBox(height: 20)
    ]);
  }
}