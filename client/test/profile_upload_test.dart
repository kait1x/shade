import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shade/core/services/profile_upload.dart';

void main() {
  late SecurityContext context;
  late String pin;
  setUpAll(() async {
    const folder = '../artifacts/fixes/avatar-save/work/test-cert';
    final result = await Process.run(
        'python', ['../server/test/make-test-cert.py', folder]);
    expect(result.exitCode, 0, reason: result.stderr.toString());
    context = SecurityContext()
      ..useCertificateChain('$folder/cert.pem')
      ..usePrivateKey('$folder/key.pem');
    final pem = await File('$folder/cert.pem').readAsString();
    final der = base64Decode(pem.replaceAll(RegExp(r'-----[^-]+-----|\s'), ''));
    pin = base64Encode(sha256.convert(der).bytes);
  });

  test('120 KB authenticated JSON arrives intact over pinned TLS', () async {
    final server =
        await HttpServer.bindSecure(InternetAddress.loopbackIPv4, 0, context);
    addTearDown(() => server.close(force: true));
    final uri = Uri.parse('https://127.0.0.1:${server.port}/profile/avatar');
    final uploader = ProfileUploadTransport(uri, pin);
    addTearDown(uploader.cancelAll);
    final payload =
        jsonEncode({'image': 'A' * 120000, 'frame': 'silver', 'revision': 0});
    final received = Completer<String>();
    server.listen((request) async {
      expect(request.headers.value('x-session-token'), 'fixture');
      final body = await utf8.decoder.bind(request).join();
      received.complete(body);
      request.response.headers.contentType = ContentType.json;
      request.response.write('{"revision":1}');
      await request.response.close();
    });
    final request = http.Request('PUT', uri)
      ..headers.addAll(
          {'Content-Type': 'application/json', 'x-session-token': 'fixture'})
      ..body = payload;
    final response = await uploader.send(request);
    expect(response.statusCode, 200);
    expect(await received.future, payload);
    expect(jsonDecode(response.body)['revision'], 1);
  });

  test('timeout closes the upload socket instead of leaving a pending write',
      () async {
    final server =
        await HttpServer.bindSecure(InternetAddress.loopbackIPv4, 0, context);
    addTearDown(() => server.close(force: true));
    final disconnected = Completer<void>();
    server.listen((request) async {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      try {
        await request.drain<void>();
      } catch (_) {/* Aborted upload. */}
      if (!disconnected.isCompleted) disconnected.complete();
      try {
        await request.response.close();
      } catch (_) {/* Closed by client. */}
    });
    final uri = Uri.parse('https://127.0.0.1:${server.port}/profile/avatar');
    final uploader = ProfileUploadTransport(uri, pin);
    addTearDown(uploader.cancelAll);
    final request = http.Request('PUT', uri)..body = 'x' * 120000;
    await expectLater(
        uploader.send(request, timeout: const Duration(milliseconds: 150)),
        throwsA(isA<TimeoutException>()));
    await disconnected.future.timeout(const Duration(seconds: 3));
  });

  test('certificate mismatches and cross-origin uploads stay rejected',
      () async {
    final server =
        await HttpServer.bindSecure(InternetAddress.loopbackIPv4, 0, context);
    addTearDown(() => server.close(force: true));
    server.listen((request) {
      request.response.close();
    });
    final uri = Uri.parse('https://127.0.0.1:${server.port}/profile/avatar');
    final uploader = ProfileUploadTransport(uri, 'wrong-certificate-digest');
    addTearDown(uploader.cancelAll);
    await expectLater(uploader.send(http.Request('PUT', uri)),
        throwsA(isA<HandshakeException>()));
    await expectLater(
        uploader.send(http.Request(
            'PUT', Uri.parse('https://example.invalid/profile/avatar'))),
        throwsArgumentError);
  });
}
