import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fast_rsa/fast_rsa.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shade/core/services/crypto_service.dart';
import 'package:shade/core/services/device_v2/crypto.dart';
import 'package:shade/core/services/device_v2/protocol.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('PBKDF2-SHA256 600000 matches node:crypto cross-vector', () {
    final key = pbkdf2Sha256('synthetic cross-vector recovery phrase',
        base64.decode('AAECAwQFBgcICQoLDA0ODw=='));
    expect(base64.encode(key), 'xG88C86cRXGGA4cXpiQ2le+DLrLeUenVoTzetViSLlQ=');
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('Dart device-v2 port seals/opens E2EE with WebCrypto and exchanges recovery', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final crypto = CryptoService();
    final v2 = DeviceV2Crypto(crypto);
    final kp = await RSA.generate(4096);
    final root = await publicSpki(kp.publicKey);
    final process = await Process.start(
        'node', ['../server/tools/device-v2-port-interop.mjs']);
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
      expect(await lines.moveNext().timeout(const Duration(seconds: 90)), true);
      return jsonDecode(lines.current) as Map<String, dynamic>;
    }

    Future<Map<String, dynamic>> request(Map<String, dynamic> value) async {
      process.stdin.writeln(jsonEncode(value));
      final result = await next();
      expect(result['ok'], true, reason: result['error']?.toString());
      return result['result'] as Map<String, dynamic>;
    }

    final ready = await next();
    expect(ready['ready'], true);
    final web = ready['web'] as Map<String, dynamic>;

    const nativePhrase = 'synthetic native offline recovery phrase';
    final backup = await v2.createRecoveryBackup('port_native', root, nativePhrase);
    final genesis = v2.buildLegacyGenesis('port_native', root, backup['publicKey'] as String);
    genesis['signature'] = await crypto.signData(genesisText(genesis), kp.privateKey);
    final manifest = v2.buildLegacyManifest('port_native', root);
    manifest['signature'] = await crypto.signData(manifestText(manifest), kp.privateKey);
    final finalized = await v2.finalizeRecoveryBackup(backup, nativePhrase, genesis);

    await request({
      'action': 'accept-native',
      'publicKey': kp.publicKey,
      'genesis': genesis,
      'manifest': manifest
    });

    final session = DeviceV2Session(
        account: 'port_native',
        id: 'primary',
        encryptionKey: root,
        signingKey: root,
        encryptionPrivateKey: kp.privateKey,
        signingPrivateKey: kp.privateKey);
    final webTrust = AccountTrust(
        root: web['root'] as String, genesis: web['genesis'] as Map<String, dynamic>);
    final nativeTrust = AccountTrust(root: root, genesis: genesis);

    // Web → Android (Dart port opens a WebCrypto-sealed fanout message).
    const toNative = 'Web → Dart device-v2 port 🔐';
    final bundle = await request({'action': 'web-seal', 'text': toNative});
    expect(await v2.openMessage(bundle, session, webTrust, nativeTrust), toNative);

    // Android → Web (WebCrypto opens a Dart-sealed fanout message).
    const toWeb = 'Dart device-v2 port → Web 🌍';
    final sealed = await v2.sealMessage(toWeb, [manifest],
        [web['manifest']], session, nativeTrust, webTrust);
    final opened = await request({'action': 'native-open', 'message': sealed});
    expect(opened['plaintext'], toWeb);

    // JS-created recovery package unlocks in Dart; recovered key signs for JS.
    final jsRecovery = web['recovery'] as Map<String, dynamic>;
    final recoveredPem = await v2.unlockRecoveryBackup(
        jsRecovery['backup'] as Map<String, dynamic>,
        jsRecovery['phrase'] as String,
        jsRecovery['genesis'] as Map<String, dynamic>);
    final probe = base64.encode(randomBytes(32));
    final probeSignature = await crypto.signData(probe, recoveredPem);
    final verified = await request({
      'action': 'verify-recovery-signature',
      'probe': probe,
      'signature': probeSignature,
      'publicKey': (jsRecovery['backup'] as Map)['publicKey']
    });
    expect(verified['valid'], true);

    // Dart-created recovery package unlocks in WebCrypto.
    final dartUnlock = await request({
      'action': 'unlock-dart-recovery',
      'backup': finalized,
      'phrase': nativePhrase,
      'genesis': genesis
    });
    expect(
        await v2.verifier.verify(dartUnlock['probe'] as String,
            dartUnlock['signature'] as String, dartUnlock['publicKey'] as String),
        true);

    // Wrong passphrase and wrong genesis digest fail closed.
    expect(
        () => v2.unlockRecoveryBackup(jsRecovery['backup'] as Map<String, dynamic>,
            'wrong wrong wrong wrong wrong', jsRecovery['genesis'] as Map<String, dynamic>),
        throwsA(anything));
    final wrongDigest = Map<String, dynamic>.from(finalized)
      ..['genesisDigest'] = 'ab' * 32;
    expect(() => v2.unlockRecoveryBackup(wrongDigest, nativePhrase, genesis),
        throwsA(predicate((e) => e.toString().contains('pin the exact account genesis'))));
  }, timeout: const Timeout(Duration(minutes: 5)));
}