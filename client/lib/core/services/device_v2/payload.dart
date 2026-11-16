/// Alpha wire payload agreement — точный порт codec из
/// client/web/alpha-client.mjs (ветка zcode/pwa-parity, PWA_PARITY_MATRIX)
/// плюс медиа-контракт DEVICE_V2_API.md §5.
///
/// Plain text остаётся plain text; reply добавляет {"shade":1,"t","r":{ref,from,text}};
/// медиа — {"shade":1,"m":{id,mime,index,total,chunk}} (chunk = base64 сырых
/// байтов, RAW_CHUNK = 32768, итоговый plaintext ≤ 65536). Сервер и подписи
/// device-v2 рассматривают payload как opaque. Старые истории без маркера
/// отображаются как обычный текст (обратная совместимость).
library;

import 'dart:convert';
import 'dart:math' show min;
import 'dart:typed_data';

import 'protocol.dart';

const int replyPreviewLimit = 2000;
const int mediaChunkRawBytes = 32768;
const int maxPayloadBytes = 65536;

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

/// Возвращает {'text': String, 'reply': {ref, from, text} | null} либо
/// {'text': '', 'reply': null, 'media': {id, mime, index, total, chunk}}.
Map<String, dynamic> decodePayload(String payload) {
  try {
    final parsed = jsonDecode(payload);
    if (parsed is Map<String, dynamic> && parsed['shade'] == 1) {
      final m = parsed['m'];
      if (m is Map<String, dynamic> &&
          m['id'] is String &&
          m['mime'] is String &&
          m['index'] is int &&
          m['total'] is int &&
          (m['index'] as int) >= 0 &&
          (m['total'] as int) >= 1 &&
          (m['index'] as int) < (m['total'] as int) &&
          m['chunk'] is String) {
        return {
          'text': '',
          'reply': null,
          'media': {
            'id': m['id'],
            'mime': m['mime'],
            'index': m['index'],
            'total': m['total'],
            'chunk': m['chunk']
          }
        };
      }
      if (parsed['t'] is String) {
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
    }
  } catch (_) {
    // JSON-подобный plain text отображается без изменений.
  }
  return {'text': payload, 'reply': null};
}

/// Один медиа-чанк в wire-формате (plaintext ≤ 64 КиБ).
String encodeMediaPayload({
  required String id,
  required String mime,
  required int index,
  required int total,
  required Uint8List chunk,
}) {
  check(chunk.isNotEmpty && chunk.length <= mediaChunkRawBytes,
      'Некорректный размер медиа-чанка');
  check(index >= 0 && total >= 1 && index < total, 'Некорректный индекс чанка');
  final payload = jsonEncode({
    'shade': 1,
    'm': {'id': id, 'mime': mime, 'index': index, 'total': total, 'chunk': base64.encode(chunk)}
  });
  check(utf8.encode(payload).length <= maxPayloadBytes, 'Медиа-payload слишком большой');
  return payload;
}

/// Разбивает байты на чанки (порядок index = порядок отправки).
List<String> splitMediaPayloads(Uint8List bytes,
    {required String id, required String mime}) {
  check(bytes.isNotEmpty, 'Пустое медиа');
  final total = (bytes.length + mediaChunkRawBytes - 1) ~/ mediaChunkRawBytes;
  return [
    for (var i = 0; i < total; i++)
      encodeMediaPayload(
          id: id,
          mime: mime,
          index: i,
          total: total,
          chunk: Uint8List.sublistView(
              bytes, i * mediaChunkRawBytes, min(bytes.length, (i + 1) * mediaChunkRawBytes)))
  ];
}

/// Собирает медиа из декодированных чанков; null если набор неполный/несогласован.
Uint8List? assembleMedia(List<Map<String, dynamic>> parts) {
  if (parts.isEmpty) return null;
  final id = parts.first['id'];
  final total = parts.first['total'];
  if (total is! int || total < 1 || parts.length != total) return null;
  final byIndex = <int, Uint8List>{};
  for (final part in parts) {
    if (part['id'] != id || part['total'] != total) return null;
    final index = part['index'];
    final chunk = part['chunk'];
    if (index is! int || chunk is! String || byIndex.containsKey(index)) return null;
    final bytes = base64.decode(chunk);
    if (bytes.length > mediaChunkRawBytes) return null;
    byIndex[index] = bytes;
  }
  if (byIndex.length != total) return null;
  final builder = BytesBuilder(copy: false);
  for (var i = 0; i < total; i++) {
    final bytes = byIndex[i];
    if (bytes == null) return null;
    builder.add(bytes);
  }
  return builder.takeBytes();
}