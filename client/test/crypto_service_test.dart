import 'package:flutter_test/flutter_test.dart';
import 'package:shade/core/services/crypto_service.dart';

void main() {
  group('CryptoService Tests', () {
    late CryptoService cryptoService;

    setUp(() async {
      cryptoService = CryptoService();
      await cryptoService.generateIdentityKeys();
    });

    tearDown(() async {
      await cryptoService.clearKeys();
    });

    test('should generate RSA key pair', () async {
      final publicKey = await cryptoService.getPublicKey();
      expect(publicKey, isNotNull);
      expect(publicKey!.isNotEmpty, true);
      expect(publicKey.contains('BEGIN PUBLIC KEY'), true);
    });

    test('should encrypt and decrypt data successfully', () async {
      const plainText = 'Hello, Shade!';

      final myPublicKey = await cryptoService.getPublicKey();
      final myPrivateKey = await cryptoService.getPrivateKey();
      expect(myPublicKey, isNotNull);
      expect(myPrivateKey, isNotNull);

      final encrypted = await cryptoService.encryptData(plainText, myPublicKey!);
      expect(encrypted, isNotNull);
      expect(encrypted.isNotEmpty, true);
      expect(encrypted != plainText, true);

      final decrypted = await cryptoService.decryptData(encrypted, myPrivateKey!);
      expect(decrypted, equals(plainText));
    });

    test('should encrypt different texts to different ciphertexts', () async {
      const text1 = 'Message 1';
      const text2 = 'Message 2';

      final publicKey = await cryptoService.getPublicKey();

      final encrypted1 = await cryptoService.encryptData(text1, publicKey!);
      final encrypted2 = await cryptoService.encryptData(text2, publicKey!);

      expect(encrypted1 != encrypted2, true);
    });

    test('should fail to decrypt with tampered ciphertext', () async {
      const plainText = 'Secret message';

      final publicKey = await cryptoService.getPublicKey();
      final privateKey = await cryptoService.getPrivateKey();
      final encrypted = await cryptoService.encryptData(plainText, publicKey!);

      final tampered = encrypted.substring(0, encrypted.length - 5) + 'XXXXX';

      expect(
        () => cryptoService.decryptData(tampered, privateKey!),
        throwsA(isA<Exception>()),
      );
    });

    test('should handle empty string encryption', () async {
      const plainText = '';

      final publicKey = await cryptoService.getPublicKey();
      final privateKey = await cryptoService.getPrivateKey();
      final encrypted = await cryptoService.encryptData(plainText, publicKey!);
      final decrypted = await cryptoService.decryptData(encrypted, privateKey!);

      expect(decrypted, equals(plainText));
    });

    test('should handle unicode and emoji in encryption', () async {
      const plainText = 'Привет мир! 🌍🔐 Привет 你好 مرحبا';

      final publicKey = await cryptoService.getPublicKey();
      final privateKey = await cryptoService.getPrivateKey();
      final encrypted = await cryptoService.encryptData(plainText, publicKey!);
      final decrypted = await cryptoService.decryptData(encrypted, privateKey!);

      expect(decrypted, equals(plainText));
    });
  });

  group('CryptoService Key Exchange Simulation', () {
    late CryptoService alice;
    late CryptoService bob;

    setUp(() async {
      alice = CryptoService();
      bob = CryptoService();
      await alice.generateIdentityKeys();
      await bob.generateIdentityKeys();
    });

    tearDown(() async {
      await alice.clearKeys();
      await bob.clearKeys();
    });

    test('Alice should send encrypted message to Bob', () async {
      const message = 'Hey Bob, this is a secret!';

      final bobPublicKey = await bob.getPublicKey();
      final bobPrivateKey = await bob.getPrivateKey();

      final encryptedForBob = await alice.encryptData(message, bobPublicKey!);

      final decryptedByBob = await bob.decryptData(encryptedForBob, bobPrivateKey!);

      expect(decryptedByBob, equals(message));
    });

    test('Bob should not be able to decrypt message encrypted with Alice\'s key', () async {
      const message = 'This is for Alice only';

      final alicePublicKey = await alice.getPublicKey();
      final bobPrivateKey = await bob.getPrivateKey();

      final encryptedForAlice = await alice.encryptData(message, alicePublicKey!);

      expect(
        () => bob.decryptData(encryptedForAlice, bobPrivateKey!),
        throwsA(isA<Exception>()),
      );
    });
  });
}
