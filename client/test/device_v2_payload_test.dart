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
}