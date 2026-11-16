import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shade/core/database/database_service.dart';
import 'package:shade/core/services/connection_service.dart';
import 'package:shade/core/services/crypto_service.dart';

class _ChunkConnection extends ConnectionService {
  _ChunkConnection()
      : super(
            serverUrl: 'https://localhost',
            cryptoService: CryptoService(),
            databaseService: DatabaseService());
  final parts = <int, String>{};
  String? uploadId;
  bool lostAck = false, validationFailure = false;
  bool clientFailure = false;
  int commits = 0;
  @override
  Future<Map<String, dynamic>> profileRequest(String method, String path,
      [Map<String, dynamic>? data]) async {
    if (method == 'PUT') {
      uploadId = data!['uploadId'];
      if (validationFailure) throw StateError('Аватар уже изменился');
      if (clientFailure) throw http.ClientException('connection interrupted');
      throw TimeoutException('simulated stalled large upload');
    }
    expect(path, '/profile/avatar/chunk');
    expect(method, 'POST');
    expect(data!['uploadId'], uploadId);
    final chunk = data['chunk'] as String, offset = data['offset'] as int;
    expect(chunk.length, lessThanOrEqualTo(32768));
    if (parts.containsKey(offset)) expect(parts[offset], chunk);
    parts[offset] = chunk;
    if (!lostAck && offset == 32768) {
      lostAck = true;
      throw http.ClientException('simulated lost acknowledgement');
    }
    if (offset + chunk.length == data['total']) {
      commits++;
      return {
        'complete': true,
        'profile': {
          'revision': 4,
          'frame': data['frame'],
          'displayName': 'User',
          'imageUrl': null
        }
      };
    }
    return {'complete': false, 'offset': offset + chunk.length};
  }
}

void main() {
  test('HTTP client failures also use the idempotent upload fallback', () async {
    final conn = _ChunkConnection()..clientFailure = true;
    addTearDown(conn.dispose);
    final result = await conn.saveAvatarProfile(
        {'image': 'AAAA', 'frame': 'none', 'revision': 3});
    expect(result['revision'], 4);
    expect(conn.commits, 1);
    expect(conn.parts[0], 'AAAA');
  });
  test(
      'stalled upload falls back to acknowledged parts without losing image bytes',
      () async {
    final conn = _ChunkConnection();
    addTearDown(conn.dispose);
    final image = base64Encode(List<int>.generate(90000, (i) => i % 256));
    final progress = <double>[];
    final result = await conn.saveAvatarProfile(
        {'image': image, 'frame': 'silver', 'revision': 3},
        onProgress: progress.add);
    final offsets = conn.parts.keys.toList()..sort();
    expect(offsets.map((offset) => conn.parts[offset]).join(), image);
    expect(result['image'], image);
    expect(result['revision'], 4);
    expect(conn.commits, 1);
    expect(conn.lostAck, isTrue);
    expect(progress.last, 1);
    expect(progress, orderedEquals([...progress]..sort()));
  });
  test(
      'server validation failures are shown without attempting a different upload',
      () async {
    final conn = _ChunkConnection()..validationFailure = true;
    addTearDown(conn.dispose);
    await expectLater(
        conn.saveAvatarProfile(
            {'image': 'AAAA', 'frame': 'none', 'revision': 0}),
        throwsStateError);
    expect(conn.parts, isEmpty);
  });
}
