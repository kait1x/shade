import 'dart:convert';
import 'dart:io';

import 'package:fast_rsa/fast_rsa.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shade/core/services/crypto_service.dart';
import 'package:shade/core/services/device_v2/protocol.dart';

/// Кросс-векторы генерируются из JS-протокола:
/// node client/tools/generate_v2_vectors.mjs
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('device-v2 canonical cross-vectors', () {
    final vectors = jsonDecode(
            File('test/assets/device_v2_vectors.json').readAsStringSync())
        as Map<String, dynamic>;

    test('fingerprint and deviceId match JS', () {
      for (final v in vectors['fingerprint'] as List) {
        expect(spkiFingerprint(v['spki'] as String), v['hash']);
      }
      for (final v in vectors['deviceId'] as List) {
        expect(deviceIdOf(v['encryptionKey'] as String, v['signingKey'] as String),
            v['id']);
      }
    });

    test('genesisText matches JS byte-for-byte', () {
      for (final v in vectors['genesis'] as List) {
        final input = v['input'] as Map<String, dynamic>;
        expect(genesisText(input), v['text']);
        expect(sha256Hex(genesisText(input)), v['hash']);
      }
    });

    test('manifestText matches JS byte-for-byte', () {
      for (final v in vectors['manifest'] as List) {
        final input = v['input'] as Map<String, dynamic>;
        expect(manifestText(input), v['text']);
        expect(sha256Hex(manifestText(input)), v['hash']);
      }
    });

    test('messageText matches JS byte-for-byte', () {
      for (final v in vectors['message'] as List) {
        final input = v['input'] as Map<String, dynamic>;
        expect(messageText(input), v['text']);
        expect(sha256Hex(messageText(input)), v['hash']);
      }
    });

    test('requestText and pairingText match JS', () {
      for (final v in vectors['request'] as List) {
        final text = requestText(v['account'] as String, v['id'] as String,
            v['nonce'] as String, v['operation'] as String);
        expect(text, v['text']);
        expect(sha256Hex(text), v['hash']);
      }
      for (final v in vectors['pairing'] as List) {
        final text = pairingText(v['account'] as String,
            v['device'] as Map<String, dynamic>, v['nonce'] as String,
            v['expiresAt'] as int);
        expect(text, v['text']);
        expect(sha256Hex(text), v['hash']);
      }
    });

    test('operationDigest matches registry.mjs', () {
      for (final v in vectors['operation'] as List) {
        expect(operationDigest(v['op'] as String, v['body']), v['digest']);
      }
    });

    test('shape violations are rejected', () {
      final genesis = (vectors['genesis'] as List).first['input'] as Map<String, dynamic>;
      final bad = Map<String, dynamic>.from(genesis)..['extra'] = 1;
      expect(() => genesisText(bad), throwsA(isA<ProtocolException>()));
      final message = (vectors['message'] as List).first['input'] as Map<String, dynamic>;
      final shortFanout = Map<String, dynamic>.from(message)
        ..['envelopes'] = (message['envelopes'] as List).sublist(0, 1);
      expect(() => messageText(shortFanout), throwsA(isA<ProtocolException>()));
      expect(() => requestText('Alice', 'primary', 'ab' * 32, 'cd' * 32),
          throwsA(isA<ProtocolException>()));
    });
  });

  group('device-v2 signed verification with real native RSA', () {
    late CryptoService crypto;
    late DeviceV2Verifier verifier;
    late String nativePublic, nativePrivate, nativeSpki;
    late String peerPublic, peerPrivate, peerSpki;
    late String recoverySpki;
    late Map<String, dynamic> genesis;
    late Map<String, dynamic> manifest;
    late Map<String, dynamic> peerGenesis;
    late Map<String, dynamic> peerManifest;
    const now = 1763000000000;

    Future<String> spkiOf(String pem) async => (await RSA.convertPublicKeyToPKIX(pem))
        .split('\n')
        .where((s) => !s.startsWith('-----'))
        .join()
        .trim();

    setUpAll(() async {
      FlutterSecureStorage.setMockInitialValues({});
      crypto = CryptoService();
      verifier = DeviceV2Verifier(crypto);
      final native = await RSA.generate(4096);
      nativePublic = native.publicKey;
      nativePrivate = native.privateKey;
      nativeSpki = await spkiOf(nativePublic);
      final peer = await RSA.generate(4096);
      peerPublic = peer.publicKey;
      peerPrivate = peer.privateKey;
      peerSpki = await spkiOf(peerPublic);
      final recovery = await RSA.generate(4096);
      recoverySpki = await spkiOf(recovery.publicKey);

      genesis = {
        'version': 2, 'account': 'alice_android', 'nonce': 'ab' * 32,
        'createdAt': now, 'legacy': true,
        'firstDevice': {'id': 'primary', 'encryptionKey': nativeSpki, 'signingKey': nativeSpki},
        'recoveryKey': recoverySpki, 'signature': ''
      };
      genesis['signature'] = await crypto.signData(genesisText(genesis), nativePrivate);
      manifest = {
        'account': 'alice_android', 'rootFingerprint': spkiFingerprint(nativeSpki),
        'revision': 1, 'previous': '', 'issuedAt': now, 'expiresAt': now + 86400000,
        'devices': [genesis['firstDevice']], 'signer': 'primary', 'signature': ''
      };
      manifest['signature'] = await crypto.signData(manifestText(manifest), nativePrivate);

      peerGenesis = {
        'version': 2, 'account': 'bob_android', 'nonce': 'cd' * 32,
        'createdAt': now, 'legacy': true,
        'firstDevice': {'id': 'primary', 'encryptionKey': peerSpki, 'signingKey': peerSpki},
        'recoveryKey': recoverySpki, 'signature': ''
      };
      peerGenesis['signature'] = await crypto.signData(genesisText(peerGenesis), peerPrivate);
      peerManifest = {
        'account': 'bob_android', 'rootFingerprint': spkiFingerprint(peerSpki),
        'revision': 1, 'previous': '', 'issuedAt': now, 'expiresAt': now + 86400000,
        'devices': [peerGenesis['firstDevice']], 'signer': 'primary', 'signature': ''
      };
      peerManifest['signature'] = await crypto.signData(manifestText(peerManifest), peerPrivate);
    });

    test('verifyGenesis and verifyHistory accept the signed legacy chain', () async {
      final digest = await verifier.verifyGenesis(genesis, nativeSpki);
      expect(digest, sha256Hex(genesisText(genesis)));
      final result = await verifier.verifyHistory([manifest], nativeSpki, null,
          now: now + 1000, genesis: genesis);
      expect(result['revision'], 1);
      expect(result['digest'], sha256Hex(manifestText(manifest)));
      expect(result['genesisDigest'], digest);
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('tampered genesis signature and substituted root are rejected', () async {
      final tampered = Map<String, dynamic>.from(genesis)..['nonce'] = 'ef' * 32;
      expect(() => verifier.verifyGenesis(tampered, nativeSpki),
          throwsA(predicate((e) => e.toString().contains('Invalid genesis signature'))));
      expect(() => verifier.verifyGenesis(genesis, peerSpki),
          throwsA(predicate((e) => e.toString().contains('Genesis anchor substitution'))));
    });

    test('manifest rollback and fork are rejected against a checkpoint', () async {
      final checkpoint = await verifier.acceptManifest(manifest, nativeSpki, null, now: now + 1000);
      expect(checkpoint['revision'], 1);
      expect(
          () => verifier.acceptManifest(manifest, nativeSpki,
              {...checkpoint, 'revision': 2}, now: now + 1000),
          throwsA(predicate((e) => e.toString().contains('Directory rollback'))));
      final forked = Map<String, dynamic>.from(manifest)
        ..['issuedAt'] = now + 500
        ..['expiresAt'] = now + 86400500;
      forked['signature'] = await crypto.signData(manifestText(forked), nativePrivate);
      expect(() => verifier.acceptManifest(forked, nativeSpki, checkpoint, now: now + 1000),
          throwsA(predicate((e) => e.toString().contains('Directory fork'))));
    });

    test('signed fanout message verifies; tamper and incomplete fanout fail', () async {
      const text = 'Android ↔ Web E2EE 🔐';
      final message = {
        'version': 2, 'id': 'ef' * 32, 'from': 'alice_android', 'deviceId': 'primary',
        'to': 'bob_android', 'fromRevision': 1, 'toRevision': 1,
        'fromDigest': sha256Hex(manifestText(manifest)),
        'toDigest': sha256Hex(manifestText(peerManifest)),
        'createdAt': now + 2000,
        'envelopes': [
          {'account': 'alice_android', 'deviceId': 'primary',
            'payload': jsonDecode(await crypto.encryptData(text, nativePublic))},
          {'account': 'bob_android', 'deviceId': 'primary',
            'payload': jsonDecode(await crypto.encryptData(text, peerPublic))}
        ],
        'signature': ''
      };
      message['signature'] = await crypto.signData(messageText(message), nativePrivate);
      final digest = await verifier.verifyMessage(message, manifest, peerManifest, now: now + 3000);
      expect(digest, sha256Hex(messageText(message)));
      // Получатель расшифровывает свой конверт существующим CryptoService.
      final own = (message['envelopes'] as List)[1] as Map<String, dynamic>;
      expect(await crypto.decryptData(jsonEncode(own['payload']), peerPrivate), text);

      final tampered = jsonDecode(jsonEncode(message)) as Map<String, dynamic>;
      final payload = ((tampered['envelopes'] as List)[1] as Map)['payload'] as Map;
      final bytes = base64.decode(payload['d'] as String);
      bytes[0] ^= 0xFF;
      payload['d'] = base64.encode(bytes);
      expect(() => verifier.verifyMessage(tampered, manifest, peerManifest, now: now + 3000),
          throwsA(predicate((e) => e.toString().contains('Invalid device message signature'))));

      final incomplete = jsonDecode(jsonEncode(message)) as Map<String, dynamic>;
      incomplete['envelopes'] = (incomplete['envelopes'] as List).sublist(0, 1);
      expect(() => verifier.verifyMessage(incomplete, manifest, peerManifest, now: now + 3000),
          throwsA(isA<ProtocolException>()));
    });

    test('RSA-2048 SPKI is rejected by the v2 key validator', () async {
      final small = await RSA.generate(2048);
      final smallSpki = await spkiOf(small.publicKey);
      expect(() => validateRsaSpki(smallSpki),
          throwsA(predicate((e) => e.toString().contains('Unsupported RSA key'))));
      validateRsaSpki(nativeSpki);
    });
  });
}