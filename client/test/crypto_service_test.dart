import 'package:flutter_test/flutter_test.dart';
import 'package:shade/core/services/crypto_service.dart';

void main() {
  group('CryptoService Tests', () {
    late CryptoService cryptoService;

    setUp(() async {
      cryptoService = CryptoService();
      await cryptoService.initialize();
    });

    tearDown(() async {
      await cryptoService.dispose();
    });

    test('should generate RSA key pair on initialization', () async {
      final publicKey = await cryptoService.getPublicKey();
      expect(publicKey, isNotNull);
      expect(publicKey!.isNotEmpty, true);
      expect(publicKey.contains('BEGIN PUBLIC KEY'), true);
    });

    test('should encrypt and decrypt data successfully', () async {
      const plainText = 'Hello, Shade! 🔐';
      
      // Get our own public key for self-encryption test
      final myPublicKey = await cryptoService.getPublicKey();
      expect(myPublicKey, isNotNull);

      // Encrypt
      final encrypted = await cryptoService.encryptData(plainText, myPublicKey!);
      expect(encrypted, isNotNull);
      expect(encrypted.isNotEmpty, true);
      expect(encrypted != plainText, true);

      // Decrypt
      final decrypted = await cryptoService.decryptData(encrypted);
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
      final encrypted = await cryptoService.encryptData(plainText, publicKey!);
      
      // Tamper with the ciphertext
      final tampered = encrypted.substring(0, encrypted.length - 5) + 'XXXXX';
      
      // Should throw exception or return different data
      expect(
        () => cryptoService.decryptData(tampered),
        throwsA(isA<Exception>()),
      );
    });

    test('should handle empty string encryption', () async {
      const plainText = '';
      
      final publicKey = await cryptoService.getPublicKey();
      final encrypted = await cryptoService.encryptData(plainText, publicKey!);
      final decrypted = await cryptoService.decryptData(encrypted);
      
      expect(decrypted, equals(plainText));
    });

    test('should handle unicode and emoji in encryption', () async {
      const plainText = 'Привет мир! 🌍🔐 Привет 你好 مرحبا';
      
      final publicKey = await cryptoService.getPublicKey();
      final encrypted = await cryptoService.encryptData(plainText, publicKey!);
      final decrypted = await cryptoService.decryptData(encrypted);
      
      expect(decrypted, equals(plainText));
    });

    test('should handle long text encryption', () async {
      const plainText = 'Lorem ipsum dolor sit amet, consectetur adipiscing elit. '
          'Sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. '
          'Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris '
          'nisi ut aliquip ex ea commodo consequat. Duis aute irure dolor in '
          'reprehenderit in voluptate velit esse cillum dolore eu fugiat nulla '
          'pariatur. Excepteur sint occaecat cupidatat non proident, sunt in '
          'culpa qui officia deserunt mollit anim id est laborum.' * 10;
      
      final publicKey = await cryptoService.getPublicKey();
      final encrypted = await cryptoService.encryptData(plainText, publicKey!);
      final decrypted = await cryptoService.decryptData(encrypted);
      
      expect(decrypted, equals(plainText));
    });
  });

  group('CryptoService Key Exchange Simulation', () {
    late CryptoService alice;
    late CryptoService bob;

    setUp(() async {
      alice = CryptoService();
      bob = CryptoService();
      await alice.initialize();
      await bob.initialize();
    });

    tearDown(() async {
      await alice.dispose();
      await bob.dispose();
    });

    test('Alice should send encrypted message to Bob', () async {
      const message = 'Hey Bob, this is a secret!';
      
      // Get Bob's public key
      final bobPublicKey = await bob.getPublicKey();
      
      // Alice encrypts message with Bob's public key
      final encryptedForBob = await alice.encryptData(message, bobPublicKey!);
      
      // Bob decrypts with his private key
      final decryptedByBob = await bob.decryptData(encryptedForBob);
      
      expect(decryptedByBob, equals(message));
    });

    test('Bob should not be able to decrypt message encrypted with Alice\'s key', () async {
      const message = 'This is for Alice only';
      
      // Get Alice's public key
      final alicePublicKey = await alice.getPublicKey();
      
      // Encrypt with Alice's key
      final encryptedForAlice = await alice.encryptData(message, alicePublicKey!);
      
      // Bob tries to decrypt (should fail)
      expect(
        () => bob.decryptData(encryptedForAlice),
        throwsA(isA<Exception>()),
      );
    });
  });
}
