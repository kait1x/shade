import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shade/core/services/crypto_service.dart';
import 'package:shade/core/services/notification_service.dart';
import 'package:shade/core/services/tls_policy.dart';

class _Certificate implements X509Certificate {
  @override
  final Uint8List der;
  _Certificate(List<int> data) : der = Uint8List.fromList(data);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('untrusted TLS exception only accepts the configured DER, host and port',
      () {
    final certificate = _Certificate([1, 2, 3]);
    final digest = base64Encode(sha256.convert(certificate.der).bytes);
    final policy =
        ShadeHttpOverrides(Uri.parse('https://relay.example:3443'), digest);
    expect(
        policy.acceptsUntrustedCertificate(certificate, 'relay.example', 3443),
        isTrue);
    expect(
        policy.acceptsUntrustedCertificate(
            certificate, 'attacker.example', 3443),
        isFalse);
    expect(
        policy.acceptsUntrustedCertificate(certificate, 'relay.example', 443),
        isFalse);
    expect(
        policy.acceptsUntrustedCertificate(
            _Certificate([4]), 'relay.example', 3443),
        isFalse);
    expect(
        ShadeHttpOverrides(Uri.parse('https://relay.example:3443'), '')
            .acceptsUntrustedCertificate(certificate, 'relay.example', 3443),
        isFalse);
  });
  test(
      'key signature requires explicit trust, correct username and the same relay',
      () async {
    FlutterSecureStorage.setMockInitialValues({});
    final crypto = CryptoService();
    final keys = await crypto.generateIdentityKeys();
    final key = keys['publicKey']!, private = keys['privateKey']!;
    const origin = 'https://relay.example:3443';
    final signature =
        await crypto.signData('shade-user-key:v1:alice:$key', private);
    expect(
        await crypto.verifyPublicKeySignature(key, signature, key,
            username: 'alice', serverOrigin: origin),
        isFalse);
    final first =
        await crypto.checkServerKeyForConfirmation(key, serverOrigin: origin);
    expect(first.status, ServerKeyTrustStatus.newKeyRequiresConfirmation);
    await crypto.trustServerKey(first.fingerprint, serverOrigin: origin);
    expect(
        await crypto.verifyPublicKeySignature(key, signature, key,
            username: 'alice', serverOrigin: origin),
        isTrue);
    expect(
        await crypto.verifyPublicKeySignature(key, signature, key,
            username: 'bob', serverOrigin: origin),
        isFalse);
    expect(
        await crypto.verifyPublicKeySignature(key, signature, key,
            username: 'alice', serverOrigin: 'https://other.example'),
        isFalse);
    final rotated = await crypto.generateIdentityKeys();
    expect(
        (await crypto.checkServerKeyForConfirmation(rotated['publicKey']!,
                serverOrigin: origin))
            .status,
        ServerKeyTrustStatus.mismatchDetected);
    await crypto.clearKeys();
  });
  test(
      'push routes use validated sender names rather than server-local conversation IDs',
      () {
    expect(NotificationService.targetForData({'from': 'alice'}), 'user:alice');
    expect(NotificationService.targetForData({'from': '../admin'}), isNull);
    expect(
        NotificationService.targetForData({'conversationId': '999'}), isNull);
  });
}
