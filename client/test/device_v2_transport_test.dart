import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fast_rsa/fast_rsa.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shade/core/services/crypto_service.dart';
import 'package:shade/core/services/device_v2/crypto.dart';
import 'package:shade/core/services/device_v2/protocol.dart';
import 'package:shade/core/services/device_v2/transport.dart';

/// Реальный alpha.mjs (HTTP + WebSocket) поднимается node-мостом с синтетическим
/// OAuth и синтетическим legacy-пользователем. Dart AlphaTransport ходит в
/// сервер напрямую; приватный ключ Android не покидает Dart-процесс.
/// Реальная сеть для транспортного теста: стандартный binding мокает HttpClient.
class _RealNetworkBinding extends AutomatedTestWidgetsFlutterBinding {
  @override
  bool get overrideHttpClient => false;
}

void main() {
  _RealNetworkBinding();

  test('native AlphaTransport exchanges E2EE with Web over real alpha HTTP/WSS',
      () async {
    FlutterSecureStorage.setMockInitialValues({});
    final crypto = CryptoService();
    final v2 = DeviceV2Crypto(crypto);
    final kp = await RSA.generate(4096);
    final root = await publicSpki(kp.publicKey);
    final recoveryKp = await RSA.generate(4096);
    final recoverySpki = await publicSpki(recoveryKp.publicKey);

    final process = await Process.start(
        'node', ['../server/tools/alpha-native-transport.mjs']);
    final lines = StreamIterator(
        process.stdout.transform(utf8.decoder).transform(const LineSplitter()));
    final stderr = process.stderr.transform(utf8.decoder).join();
    addTearDown(() async {
      await process.stdin.close();
      final exit = await process.exitCode.timeout(const Duration(seconds: 20),
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

    expect((await next())['ready'], true);
    final init = await request({'action': 'init', 'publicKey': kp.publicKey});
    final web = init['web'] as Map<String, dynamic>;

    final transport = AlphaTransport(init['origin'] as String, crypto);
    transport.sessionCookie = init['nativeCookie'] as String;
    addTearDown(transport.dispose);

    final sessionInfo = await transport.session();
    expect(sessionInfo['authenticated'], true);
    expect(sessionInfo['account'], 'native_android');

    // Явная legacy-enrollment: исходный RSA остаётся primary-якорем.
    final genesis = v2.buildLegacyGenesis('native_android', root, recoverySpki);
    genesis['signature'] =
        await crypto.signData(genesisText(genesis), kp.privateKey);
    final manifest = v2.buildLegacyManifest('native_android', root);
    manifest['signature'] =
        await crypto.signData(manifestText(manifest), kp.privateKey);
    final enrolled = await transport.legacyEnrollment(genesis, manifest);
    expect(enrolled['revision'], 1);
    await request(
        {'action': 'accept-native', 'genesis': genesis, 'manifest': manifest});

    final session = DeviceV2Session(
        account: 'native_android',
        id: 'primary',
        encryptionKey: root,
        signingKey: root,
        encryptionPrivateKey: kp.privateKey,
        signingPrivateKey: kp.privateKey);
    final webTrust = AccountTrust(
        root: web['root'] as String,
        genesis: web['genesis'] as Map<String, dynamic>);
    final nativeTrust = AccountTrust(root: root, genesis: genesis);

    // Socket.IO hint будит native-клиент при новом сообщении.
    final wakes = <int>[];
    transport.onWake = () => wakes.add(DateTime.now().millisecondsSinceEpoch);
    await transport.connectSocket(
        account: 'native_android', id: 'primary', privateKey: kp.privateKey);
    await Future<void>.delayed(const Duration(seconds: 1));
    final wakesBefore = wakes.length;

    const toNative = 'Web → Android AlphaTransport 🔐';
    await request({'action': 'web-send', 'text': toNative});
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (wakes.length <= wakesBefore && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    expect(wakes.length, greaterThan(wakesBefore),
        reason: 'socket inbox hint missing');

    final inbox = await transport.fetch(
        account: 'native_android', id: 'primary', privateKey: kp.privateKey);
    final bundle =
        inbox.firstWhere((b) => (b as Map)['message']['from'] == 'native_web')
            as Map<String, dynamic>;
    expect(
        await v2.openMessage(bundle, session, webTrust, nativeTrust), toNative);
    final ref = messageRef(bundle['message'] as Map<String, dynamic>);
    final ack = await transport.ack([ref],
        account: 'native_android', id: 'primary', privateKey: kp.privateKey);
    expect(ack['acknowledged'], 1);

    // Android → Web: сервер принимает подписанный fanout, Web расшифровывает.
    const toWeb = 'Android AlphaTransport → Web 🌍';
    final sealed = await v2.sealMessage(
        toWeb, [manifest], [web['manifest']], session, nativeTrust, webTrust);
    final accepted = await transport.send(sealed, privateKey: kp.privateKey);
    expect(accepted['accepted'], true);
    final opened = await request({'action': 'web-fetch-open'});
    expect(opened['plaintext'], toWeb);

    // Подписанный ACK Web-устройства виден отправителю через status.
    final status = await transport.status([opened['ref'] as String],
        account: 'native_android', id: 'primary', privateKey: kp.privateKey);
    final devices = status[opened['ref']] as List;
    expect(devices.single['acknowledgedAt'], isA<int>());

    // Продление lease: install revision 2 тем же устройством, отправка после.
    final now = DateTime.now().millisecondsSinceEpoch;
    final manifest2 = <String, dynamic>{
      'account': 'native_android',
      'rootFingerprint': spkiFingerprint(root),
      'revision': 2,
      'previous': enrolled['digest'],
      'issuedAt': now,
      'expiresAt': now + maxLeaseMs,
      'devices': [
        {'id': 'primary', 'encryptionKey': root, 'signingKey': root}
      ],
      'signer': 'primary',
      'signature': ''
    };
    manifest2['signature'] =
        await crypto.signData(manifestText(manifest2), kp.privateKey);
    final installed = await transport.install(manifest2,
        account: 'native_android', id: 'primary', privateKey: kp.privateKey);
    expect(installed['revision'], 2);
    final sealed2 = await v2.sealMessage(
        'после продления lease',
        [manifest, manifest2],
        [web['manifest']],
        session,
        nativeTrust,
        webTrust);
    expect(
        (await transport.send(sealed2, privateKey: kp.privateKey))['accepted'],
        true);

    // Подделанный ciphertext отклоняется сервером.
    final tampered = jsonDecode(jsonEncode(sealed2)) as Map<String, dynamic>;
    final payload =
        ((tampered['envelopes'] as List).first as Map)['payload'] as Map;
    final bytes = base64.decode(payload['d'] as String);
    bytes[0] ^= 0xFF;
    payload['d'] = base64.encode(bytes);
    expect(() => transport.send(tampered, privateKey: kp.privateKey),
        throwsA(isA<AlphaTransportException>()));

    // Каталог собеседника доступен через подписанный operation.
    final dir = await transport.directory('native_web',
        account: 'native_android', id: 'primary', privateKey: kp.privateKey);
    expect(dir['root'], web['root']);

    // Исходный RSA не изменился.
    expect(await publicSpki(kp.publicKey), root);
  }, timeout: const Timeout(Duration(minutes: 5)));
}
