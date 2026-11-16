/// Alpha wire payload agreement — точный порт codec из
/// client/web/alpha-client.mjs (ветка zcode/pwa-parity, PWA_PARITY_MATRIX).
///
/// Plain text остаётся plain text; reply добавляет {"shade":1,"t","r":{ref,from,text}}.
/// Сервер и подписи device-v2 рассматривают payload как opaque. Старые истории
/// без маркера отображаются как обычный текст (обратная совместимость).
library;

import 'dart:convert';

import 'protocol.dart';

const int replyPreviewLimit = 2000;

String encodePayload(String text, Map<String, dynamic>? reply) {
  if (reply == null) return text;
  final ref = reply['ref'];
  final from = reply['from'];
  final replyText = reply['text'];
  check(
      ref is String &&
          ref.length <= 200 &&
          from is String &&
          replyText is String &&
          replyText.isNotEmpty,
      'Некорректное сообщение для ответа');
  return jsonEncode({
    'shade': 1,
    't': text,
    'r': {
      'ref': ref,
      'from': from,
      'text': (replyText as String).length > replyPreviewLimit
          ? replyText.substring(0, replyPreviewLimit)
          : replyText
    }
  });
}

/// Возвращает {'text': String, 'reply': {ref, from, text} | null}.
Map<String, dynamic> decodePayload(String payload) {
  try {
    final parsed = jsonDecode(payload);
    if (parsed is Map<String, dynamic> &&
        parsed['shade'] == 1 &&
        parsed['t'] is String) {
      final r = parsed['r'];
      if (r == null) {
        return {'text': parsed['t'], 'reply': null};
      }
      if (r is Map<String, dynamic> &&
          r['ref'] is String &&
          r['from'] is String &&
          r['text'] is String) {
        return {
          'text': parsed['t'],
          'reply': {'ref': r['ref'], 'from': r['from'], 'text': r['text']}
        };
      }
    }
  } catch (_) {
    // JSON-подобный plain text отображается без изменений.
  }
  return {'text': payload, 'reply': null};
}