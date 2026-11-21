import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:fast_rsa/fast_rsa.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shade/core/services/crypto_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
      'real native CryptoService interoperates with WebCrypto without exporting the Android identity',
      () async {
    FlutterSecureStorage.setMockInitialValues({});
    final crypto = CryptoService();
    await crypto.generateIdentityKeys();
    final publicPem = (await crypto.getPublicKey())!;
    final privateBefore = await crypto.getPrivateKey();
    final bridge = await Process.start(
        'node', ['../server/tools/device-crypto-interop.mjs']);
    final lines = StreamIterator(
        bridge.stdout.transform(utf8.decoder).transform(const LineSplitter()));
    final stderr = bridge.stderr.drain<void>();
    addTearDown(() async {
      await bridge.stdin.close();
      await bridge.exitCode;
      await lines.cancel();
      await stderr;
    });
    Future<Map<String, dynamic>> next() async {
      expect(await lines.moveNext().timeout(const Duration(seconds: 60)), true);
      return jsonDecode(lines.current) as Map<String, dynamic>;
    }

    Future<dynamic> request(Map<String, dynamic> value) async {
      bridge.stdin.writeln(jsonEncode(value));
      final reply = await next();
      expect(reply['ok'], true);
      return reply['result'];
    }

    final device = (await next())['descriptor'] as Map<String, dynamic>;
    final browserPem =
        '-----BEGIN PUBLIC KEY-----\n${device['encryptionKey']}\n-----END PUBLIC KEY-----';
    const toBrowser = 'Android → Web: Привет 🔐';
    final nativeCiphertext = await crypto.encryptData(toBrowser, browserPem);
    expect(
        await request(
            {'action': 'decrypt', 'payload': jsonDecode(nativeCiphertext)}),
        toBrowser);

    const toAndroid = 'Web → Android: 你好 🌍';
    final browserCiphertext = await request(
        {'action': 'encrypt', 'text': toAndroid, 'publicKey': publicPem});
    expect(
        await crypto.decryptData(jsonEncode(browserCiphertext), privateBefore!),
        toAndroid);

    const signedText =
        'shade-message:v2 synthetic native/browser signature test';
    final browserSignature =
        await request({'action': 'sign', 'text': signedText}) as String;
    final signingPem =
        '-----BEGIN PUBLIC KEY-----\n${device['signingKey']}\n-----END PUBLIC KEY-----';
    expect(
        await crypto.verifySignature(signedText, browserSignature, signingPem),
        true);
    expect(
        await crypto.verifySignature(
            '$signedText changed', browserSignature, signingPem),
        false);

    final spkiPem = await RSA.convertPublicKeyToPKIX(publicPem);
    final spki = spkiPem
        .split('\n')
        .where((line) => !line.startsWith('-----'))
        .join()
        .trim();
    final now = DateTime.now().millisecondsSinceEpoch;
    final devices = <Map<String, dynamic>>[
      device,
      {'id': 'primary', 'encryptionKey': spki, 'signingKey': spki},
    ]..sort((a, b) => (a['id'] as String).compareTo(b['id'] as String));
    final manifest = <String, dynamic>{
      'account': 'interop_test',
      'rootFingerprint': sha256.convert(base64Decode(spki)).toString(),
      'revision': 1,
      'previous': '',
      'issuedAt': now,
      'expiresAt': now + 86400000,
      'devices': devices,
      'signer': 'primary',
      'signature': '',
    };
    final canonical = jsonEncode([
      'shade-devices:v2',
      manifest['account'],
      manifest['rootFingerprint'],
      1,
      '',
      now,
      now + 86400000,
      'primary',
      devices
          .map((d) => [d['id'], d['encryptionKey'], d['signingKey']])
          .toList()
    ]);
    manifest['signature'] = await crypto.signData(canonical, privateBefore);
    final digest = await request(
        {'action': 'manifest', 'manifest': manifest, 'publicKey': publicPem});
    expect(digest, sha256.convert(utf8.encode(canonical)).toString());
    expect(await crypto.getPrivateKey(), privateBefore);
    expect(await crypto.getPublicKey(), publicPem);
  }, timeout: const Timeout(Duration(minutes: 3)));
}
