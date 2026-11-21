import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:fast_rsa/fast_rsa.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shade/core/services/crypto_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
      'existing Android CryptoService exchanges signed v2 messages over real HTTP without replacing RSA',
      () async {
    FlutterSecureStorage.setMockInitialValues({});
    final crypto = CryptoService();
    await crypto.generateIdentityKeys();
    final publicKey = (await crypto.getPublicKey())!;
    final privateKey = (await crypto.getPrivateKey())!;
    final process = await Process.start(
        'node', ['../server/tools/alpha-native-interop.mjs']);
    final lines = StreamIterator(
        process.stdout.transform(utf8.decoder).transform(const LineSplitter()));
    final stderr = process.stderr.transform(utf8.decoder).join();
    addTearDown(() async {
      await process.stdin.close();
      final exit = await process.exitCode.timeout(const Duration(seconds: 15),
          onTimeout: () {
        process.kill();
        return -1;
      });
      await lines.cancel();
      expect(exit, 0, reason: await stderr);
    });
    Future<Map<String, dynamic>> next() async {
      expect(await lines.moveNext().timeout(const Duration(seconds: 60)), true);
      return jsonDecode(lines.current) as Map<String, dynamic>;
    }

    Future<Map<String, dynamic>> request(Map<String, dynamic> value) async {
      process.stdin.writeln(jsonEncode(value));
      final result = await next();
      expect(result['ok'], true, reason: result['error']?.toString());
      return result['result'] as Map<String, dynamic>;
    }

    expect((await next())['ready'], true);
    final init = await request({'action': 'init', 'publicKey': publicKey});
    final enrolled = await request({
      'action': 'enroll',
      'genesisSignature':
          await crypto.signData(init['genesisText'] as String, privateKey),
      'manifestSignature':
          await crypto.signData(init['manifestText'] as String, privateKey)
    });
    expect(enrolled['websocket'], 'websocket');
    const toAndroid = 'Web → Android CryptoService через HTTP 🔐';
    var response = await request({'action': 'web-send', 'text': toAndroid});
    response = await request({
      'action': 'native-fetch',
      'proof':
          await crypto.signData(response['proofText'] as String, privateKey)
    });
    expect(
        await crypto.verifySignature(response['messageText'] as String,
            response['signature'] as String, init['webSigningKey'] as String),
        true);
    expect(
        await crypto.decryptData(jsonEncode(response['payload']), privateKey),
        toAndroid);
    final ack = await request({
      'action': 'native-ack',
      'proof':
          await crypto.signData(response['proofText'] as String, privateKey)
    });
    expect(ack['acknowledged'], 1);
    const toWeb = 'Android CryptoService → Web через HTTP 🌍';
    final prepared = await request({
      'action': 'prepare-native-send',
      'ownPayload': jsonDecode(await crypto.encryptData(toWeb, publicKey)),
      'webPayload': jsonDecode(
          await crypto.encryptData(toWeb, init['webPublicKey'] as String))
    });
    final sent = await request({
      'action': 'native-send',
      'signature':
          await crypto.signData(prepared['messageText'] as String, privateKey),
      'proof':
          await crypto.signData(prepared['proofText'] as String, privateKey)
    });
    expect(sent['accepted'], true);
    expect(sent['plaintext'], toWeb);
    final status = await request({
      'action': 'native-status',
      'proof': await crypto.signData(sent['proofText'] as String, privateKey)
    });
    expect((status['devices'] as List).single['acknowledgedAt'], isA<int>());
    final spki = (await RSA.convertPublicKeyToPKIX(publicKey))
        .split('\n')
        .where((s) => !s.startsWith('-----'))
        .join()
        .trim();
    expect(status['root'], spki);
    expect(enrolled['root'], spki);
    expect(await crypto.getPrivateKey(), privateKey);
    expect(await crypto.getPublicKey(), publicKey);
  }, timeout: const Timeout(Duration(minutes: 3)));
}
