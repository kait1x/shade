import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shade/core/services/device_v2/payload.dart';
import 'package:shade/core/services/device_v2/protocol.dart';

/// Контракт Alpha wire payload (zcode/pwa-parity, PWA_PARITY_MATRIX):
/// plain text без маркера; reply = {"shade":1,"t","r":{ref,from,text}}.
void main() {
  test('plain text passes through unchanged', () {
    expect(encodePayload('привет', null), 'привет');
    expect(decodePayload('привет'), {'text': 'привет', 'reply': null});
  });

  test('reply encodes to the exact Alpha wire JSON', () {
    final encoded = encodePayload('ответ', {
      'ref': 'native_web:primary:abcd',
      'from': 'native_web',
      'text': 'исходное'
    });
    expect(
        encoded,
        '{"shade":1,"t":"ответ","r":{"ref":"native_web:primary:abcd",'
        '"from":"native_web","text":"исходное"}}');
  });

  test('reply preview is truncated at 2000 UTF-16 units', () {
    final long = 'x' * 2500;
    final encoded = encodePayload('t', {'ref': 'r', 'from': 'f', 'text': long});
    final decoded = decodePayload(encoded);
    expect((decoded['reply'] as Map)['text'], 'x' * 2000);
  });

  test('decode accepts JS-produced samples', () {
    expect(decodePayload('{"shade":1,"t":"hi","r":null}'),
        {'text': 'hi', 'reply': null});
    expect(decodePayload('{"shade":1,"t":"hi"}'),
        {'text': 'hi', 'reply': null});
    expect(
        decodePayload(
            '{"shade":1,"t":"hi","r":{"ref":"a:b:c","from":"a","text":"q"}}'),
        {
          'text': 'hi',
          'reply': {'ref': 'a:b:c', 'from': 'a', 'text': 'q'}
        });
  });

  test('JSON-like plain text without the marker renders unchanged', () {
    for (final raw in [
      '{"shade":2,"t":"hi"}',
      '{"t":"hi"}',
      '[1,2,3]',
      '{"shade":1,"t":5}',
      'not json at all'
    ]) {
      expect(decodePayload(raw), {'text': raw, 'reply': null});
    }
  });

  test('invalid reply shape falls back to raw text', () {
    const raw = '{"shade":1,"t":"hi","r":{"ref":1}}';
    expect(decodePayload(raw), {'text': raw, 'reply': null});
  });

  test('encode rejects invalid reply metadata', () {
    expect(
        () => encodePayload(
            'x', {'ref': 'a' * 201, 'from': 'b', 'text': 'c'}),
        throwsA(isA<ProtocolException>()));
    expect(() => encodePayload('x', {'ref': 'a', 'from': 'b', 'text': ''}),
        throwsA(isA<ProtocolException>()));
  });

  test('roundtrip preserves text and reply', () {
    final reply = {'ref': 'peer:primary:id', 'from': 'peer', 'text': 'цитата'};
    final decoded = decodePayload(encodePayload('текст', reply));
    expect(decoded['text'], 'текст');
    expect(decoded['reply'], reply);
  });

  test('media chunks encode/decode/assemble per DEVICE_V2_API contract', () {
    final bytes = Uint8List.fromList(List.generate(70000, (i) => i % 251));
    final payloads = splitMediaPayloads(bytes, id: 'media1', mime: 'image/jpeg');
    expect(payloads.length, 3);
    final parts = <Map<String, dynamic>>[];
    for (final payload in payloads) {
      expect(utf8.encode(payload).length, lessThanOrEqualTo(65536));
      final decoded = decodePayload(payload);
      expect(decoded['media'], isNotNull);
      expect(decoded['text'], '');
      parts.add(decoded['media'] as Map<String, dynamic>);
    }
    // Reassembly is order-independent.
    final assembled = assembleMedia(parts.reversed.toList());
    expect(assembled, bytes);
    // Incomplete or inconsistent sets return null, never partial data.
    expect(assembleMedia(parts.sublist(0, 2)), isNull);
    final mixed = [parts[0], {...parts[1], 'id': 'other'}];
    expect(assembleMedia(mixed), isNull);
    final duplicated = [parts[0], parts[0], parts[2]];
    expect(assembleMedia(duplicated), isNull);
  });

  test('media wire JSON matches the documented shape', () {
    final payload = encodeMediaPayload(
        id: 'm1', mime: 'image/jpeg', index: 0, total: 1, chunk: Uint8List.fromList([1, 2, 3]));
    expect(payload, '{"shade":1,"m":{"id":"m1","mime":"image/jpeg","index":0,"total":1,"chunk":"AQID"}}');
    // Legacy text/reply decoding is unchanged by the media extension.
    expect(decodePayload('plain'), {'text': 'plain', 'reply': null});
    expect(decodePayload('{"shade":1,"t":"hi"}'), {'text': 'hi', 'reply': null});
    // Malformed media falls back to raw text.
    const bad = '{"shade":1,"m":{"id":"m1","mime":"image/jpeg","index":5,"total":1,"chunk":"AQID"}}';
    expect(decodePayload(bad), {'text': bad, 'reply': null});
  });

  test('oversized media chunks are rejected', () {
    expect(
        () => encodeMediaPayload(
            id: 'm', mime: 'image/jpeg', index: 0, total: 1, chunk: Uint8List(32769)),
        throwsA(isA<ProtocolException>()));
    expect(() => splitMediaPayloads(Uint8List(0), id: 'm', mime: 'image/jpeg'),
        throwsA(isA<ProtocolException>()));
  });
}