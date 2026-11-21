import 'dart:convert';
import 'dart:io';

import 'package:fast_rsa/fast_rsa.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shade/core/database/database_service.dart';
import 'package:shade/core/services/crypto_service.dart';
import 'package:shade/core/services/device_v2/crypto.dart';
import 'package:shade/core/services/device_v2/pairing.dart';
import 'package:shade/core/services/device_v2/protocol.dart';
import 'package:shade/core/services/device_v2/repository.dart';
import 'package:shade/core/services/device_v2/store.dart';
import 'package:shade/core/services/device_v2/transport.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Pairing второго устройства: golden-совместимость Dart↔JS (фикстуры
/// сгенерированы из client/web/pairing.mjs), полный flow на fake-транспорте,
/// негативы (подпись/аккаунт/replay/expired) и идемпотентность журнала.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  final fixtures = jsonDecode(
      File('test/fixtures/pairing_vectors.json').readAsStringSync())
      as Map<String, dynamic>;

  // Общие синтетические ключи: генерация RSA-4096 дорогая, переиспользуется
  // тестами (каждый тест получает свежую БД и свежий fake-реестр).
  Future<SharedKeys>? keysFuture;
  Future<SharedKeys> sharedKeys() => keysFuture ??= generateSharedKeys();

  group('golden-совместимость с pairing.mjs', () {
    test('канонические тексты pairingTextV2/pairingText байт-в-байт', () {
      final v2 = fixtures['pairingTextV2'] as Map<String, dynamic>;
      final text = pairingTextV2(
          v2['account'] as String,
          v2['device'] as Map<String, dynamic>,
          v2['nonce'] as String,
          v2['expiresAt'] as int,
          v2['challenge'] as String);
      expect(text, v2['text']);
      expect(sha256Hex(text), v2['hash']);
      final v1 = fixtures['pairingTextV1'] as Map<String, dynamic>;
      final legacy = pairingText(
          v1['account'] as String,
          v1['device'] as Map<String, dynamic>,
          v1['nonce'] as String,
          v1['expiresAt'] as int);
      expect(legacy, v1['text']);
      expect(sha256Hex(legacy), v1['hash']);
    });

    test('challenge: код, нормализация и одноразовый формат', () async {
      await sharedKeys();
      final challenge = fixtures['challenge'] as Map<String, dynamic>;
      expect(decodeChallenge(challenge['code'] as String), challenge['nonce']);
      expect(decodeChallenge(challenge['mangledLowerSpaced'] as String),
          challenge['nonce']);
      expect(decodeChallenge(challenge['mangledILO'] as String),
          challenge['nonce']);
      expect(challengeCodeOf(challenge['nonce'] as String), challenge['code']);
      expect(challenge['expiresAt'],
          (fixtures['now'] as int) + challengeTtlMs);
      // Свежий challenge: 120 бит -> 24 символа, round-trip и срок 5 минут.
      final created = createPairingChallenge(now: 1763000000000);
      expect(created['nonce'], matches(RegExp(r'^[a-f0-9]{30}$')));
      expect(created['code'],
          matches(RegExp(r'^[0-9A-HJKMNP-TV-Z]{6}(-[0-9A-HJKMNP-TV-Z]{6}){3}$')));
      expect(created['expiresAt'], 1763000000000 + challengeTtlMs);
      expect(decodeChallenge(created['code'] as String), created['nonce']);
      expect(() => decodeChallenge('ABCD-EFGH'),
          throwsA(predicate((e) => e.toString().contains('24 символов'))));
      expect(() => decodeChallenge('U' * 24),
          throwsA(predicate((e) => e.toString().contains('недопустимый символ'))));
    });

    test('offer v2: decode/encode байт-в-байт и проверка JS-подписи', () async {
      final k = await sharedKeys();
      final golden = fixtures['offerV2'] as Map<String, dynamic>;
      final decoded = decodeOffer(golden['text'] as String);
      expect(decoded, golden['offer']);
      // Повторное кодирование обязано дать тот же код (порядок полей JSON).
      expect(encodeOffer(decoded), golden['text']);
      final device = await k.pairing.verifyPairingOffer(decoded,
          account: fixtures['account'] as String,
          challenge: (fixtures['challenge'] as Map)['nonce'] as String,
          now: golden['verifyNow'] as int);
      expect(device['id'], fixtures['deviceId']);
    });

    test('offer v1 (переходный период): decode/encode и legacy-подпись', () async {
      final k = await sharedKeys();
      final golden = fixtures['offerV1'] as Map<String, dynamic>;
      final decoded = decodeOffer(golden['text'] as String);
      expect(decoded, golden['offer']);
      expect(encodeOffer(decoded), golden['text']);
      final device = await k.pairing.verifyPairingOffer(decoded,
          account: fixtures['account'] as String,
          challenge: (fixtures['challenge'] as Map)['nonce'] as String,
          now: golden['verifyNow'] as int);
      expect(device['id'], fixtures['deviceId']);
    });

    test('offer: чужой аккаунт, неверный challenge, expired, greedy, подпись, ключи',
        () async {
      final k = await sharedKeys();
      final golden = fixtures['offerV2'] as Map<String, dynamic>;
      final offer = golden['offer'] as Map<String, dynamic>;
      final challenge = (fixtures['challenge'] as Map)['nonce'] as String;
      final account = fixtures['account'] as String;
      final now = golden['verifyNow'] as int;
      Future<void> expectReject(Map<String, dynamic> value, String reason,
          {String? accountOverride, String? challengeOverride, int? nowOverride}) async {
        await expectLater(
            k.pairing.verifyPairingOffer(value,
                account: accountOverride ?? account,
                challenge: challengeOverride ?? challenge,
                now: nowOverride ?? now),
            throwsA(predicate((e) => e.toString().contains(reason))));
      }

      await expectReject(offer, 'другому аккаунту', accountOverride: 'someone_else');
      await expectReject(offer, 'Код подключения не совпадает',
          challengeOverride: 'f' * 30);
      await expectReject(offer, 'Срок запроса истёк',
          nowOverride: offer['expiresAt'] as int);
      await expectReject(offer, 'Срок запроса превышает допустимый',
          nowOverride: (offer['expiresAt'] as int) - 300001);
      // Подменённая подпись (валидная base64-форма, другой байт).
      final tampered = Map<String, dynamic>.from(offer);
      final signature = offer['signature'] as String;
      tampered['signature'] =
          (signature[0] == 'A' ? 'B' : 'A') + signature.substring(1);
      await expectReject(tampered, 'Подпись устройства недействительна');
      // Подменённые ключи: id перестаёт совпадать с парой ключей.
      final swapped = Map<String, dynamic>.from(offer);
      swapped['device'] = {
        ...(offer['device'] as Map<String, dynamic>),
        'encryptionKey': fixtures['root']
      };
      await expectReject(swapped, 'Идентификатор устройства не совпадает');
      // Слабый/не-RSA ключ не проходит проверку формы SPKI.
      final blob = base64.encode(List.filled(294, 0x11));
      final weakDevice = {
        'id': deviceIdOf(blob, blob),
        'encryptionKey': blob,
        'signingKey': blob
      };
      final weak = Map<String, dynamic>.from(offer);
      weak['device'] = weakDevice;
      await expectReject(weak, 'Unsupported RSA key');
    });

    test('decodeOffer: мусорный ввод отвергается честно', () async {
      await sharedKeys();
      expect(() => decodeOffer('мусор'),
          throwsA(predicate((e) => e.toString().contains('Неверный формат кода'))));
      expect(() => decodeOffer('$offerPrefixV2!!!'), throwsA(isA<ProtocolException>()));
      expect(
          () => decodeOffer(offerPrefixV2 +
              base64.encode(utf8.encode('42')).replaceAll('=', '')),
          throwsA(predicate(
              (e) => e.toString().contains('Неверный формат запроса'))));
      // Несовпадение версии префикса и поля v.
      final v1Text = (fixtures['offerV1'] as Map)['text'] as String;
      final mismatched = offerPrefixV2 + v1Text.substring(offerPrefixV1.length);
      expect(() => decodeOffer(mismatched),
          throwsA(predicate((e) => e.toString().contains('Неверный формат кода'))));
      // Лишние поля запрещены строгой формой.
      final extra = {
        ...(fixtures['offerV2'] as Map)['offer'] as Map<String, dynamic>,
        'extra': 1
      };
      expect(() => encodeOffer(extra),
          throwsA(predicate((e) => e.toString().contains('Неверный формат запроса'))));
      // Невалидный UTF-8 внутри кода.
      final badUtf8 = offerPrefixV2 + base64.encode([0xff, 0xfe]).replaceAll('=', '');
      expect(() => decodeOffer(badUtf8), throwsA(isA<ProtocolException>()));
    });

    test('confirmation: decode/encode байт-в-байт, genesis и ростер', () async {
      final k = await sharedKeys();
      final golden = fixtures['confirmation'] as Map<String, dynamic>;
      final decoded = decodeConfirmation(golden['text'] as String);
      expect(decoded, golden['value']);
      expect(encodeConfirmation(decoded), golden['text']);
      final verified = await k.pairing.verifyPairingConfirmation(decoded,
          account: fixtures['account'] as String,
          deviceId: fixtures['deviceId'] as String,
          now: golden['verifyNow'] as int);
      expect(verified['root'], fixtures['root']);
      expect(verified['genesisDigest'], fixtures['genesisDigest']);
      expect((verified['tip'] as Map)['revision'], 2);
    });

    test('confirmation: чужой аккаунт, подмена genesis, отсутствие устройства, expired',
        () async {
      final k = await sharedKeys();
      final golden = fixtures['confirmation'] as Map<String, dynamic>;
      final value = golden['value'] as Map<String, dynamic>;
      final account = fixtures['account'] as String;
      final now = golden['verifyNow'] as int;
      final foreign = Map<String, dynamic>.from(value)..['account'] = 'someone_else';
      await expectLater(
          k.pairing.verifyPairingConfirmation(foreign,
              account: account, deviceId: fixtures['deviceId'] as String, now: now),
          throwsA(predicate((e) => e.toString().contains('другому аккаунту'))));
      final tampered = Map<String, dynamic>.from(value);
      final genesis = Map<String, dynamic>.from(value['genesis'] as Map);
      genesis['createdAt'] = (genesis['createdAt'] as int) + 1;
      tampered['genesis'] = genesis;
      await expectLater(
          k.pairing.verifyPairingConfirmation(tampered,
              account: account, deviceId: fixtures['deviceId'] as String, now: now),
          throwsA(predicate((e) => e.toString().contains('Invalid genesis signature'))));
      await expectLater(
          k.pairing.verifyPairingConfirmation(value,
              account: account, deviceId: 'b' * 64, now: now),
          throwsA(predicate(
              (e) => e.toString().contains('отсутствует в подтверждённом ростере'))));
      await expectLater(
          k.pairing.verifyPairingConfirmation(value,
              account: account,
              deviceId: fixtures['deviceId'] as String,
              now: (value['tip'] as Map)['expiresAt'] as int),
          throwsA(predicate((e) => e.toString().contains('Срок каталога подтверждения истёк'))));
      expect(() => decodeConfirmation('мусор'), throwsA(isA<ProtocolException>()));
      expect(
          () => decodeConfirmation(confirmPrefix +
              base64.encode(utf8.encode('{"v":2}')).replaceAll('=', '')),
          throwsA(predicate(
              (e) => e.toString().contains('Неверный формат подтверждения'))));
    });
  });

  group('repository: полный flow на fake-транспорте', () {
    test('offer → approve → confirmation → install → complete; идемпотентность',
        () async {
      final k = await sharedKeys();
      final registry = FakeRegistry();
      final (trustedStore, closeTrusted) = await openStore();
      final (newStore, closeNew) = await openStore();
      addTearDown(() async {
        await closeTrusted();
        await closeNew();
      });
      final trustedTransport = FakeTransport(registry, k.crypto);
      final newTransport = FakeTransport(registry, k.crypto);
      addTearDown(trustedTransport.dispose);
      addTearDown(newTransport.dispose);
      final trusted = await seedTrusted(
          k, trustedStore, trustedTransport, 'pair_flow');
      final newcomer = V2ChatRepository.pairing(
          transport: newTransport,
          crypto: k.crypto,
          store: newStore,
          account: 'pair_flow');
      await newcomer.load();
      expect(newcomer.enrolled, false);

      final challenge = trusted.pairingChallenge();
      final started =
          await newcomer.startPairing(challengeCode: challenge['code'] as String);
      expect(started['challengeEcho'], challenge['code']);
      expect(started['deviceId'], matches(RegExp(r'^[a-f0-9]{64}$')));
      // Ключи долговечны ДО offer: журнал уже хранит приватные части.
      final journal = await newStore.loadPairingJournal('pair_flow');
      expect(journal!['deviceId'], started['deviceId']);
      expect(journal['encryptionPrivate'], isNotNull);

      final confirmText =
          await trusted.approvePairing(started['offerText'] as String);
      expect(registry.installs, 1);
      expect(registry.history.last['revision'], 2);
      // Proof challenge-bound v2: registry перепроверил подпись pairingTextV2.
      final proof = registry.lastProofs!.single as Map<String, dynamic>;
      expect(proof['pairingVersion'], 2);
      expect(proof['challenge'], decodeChallenge(challenge['code'] as String));
      // Локальное состояние доверенной стороны обновлено, challenge потреблён.
      final trustedAcc = await trustedStore.loadAccount('pair_flow');
      expect((trustedAcc!['history'] as List).length, 2);
      expect((trustedAcc['checkpoint'] as Map)['revision'], 2);
      await expectLater(trusted.reviewPairingOffer(started['offerText'] as String),
          throwsA(predicate((e) => e.toString().contains('Код подключения истёк'))));

      final completed = await newcomer.completePairing(confirmText);
      expect(completed['revision'], 2);
      expect(newcomer.enrolled, true);
      final acc = await newStore.loadAccount('pair_flow');
      expect(acc!['sessionId'], started['deviceId']);
      expect((acc['checkpoint'] as Map)['revision'], 2);
      final keys = await newStore.loadDeviceKeys('pair_flow');
      expect(keys!['deviceId'], started['deviceId']);
      expect(await newStore.loadPairingJournal('pair_flow'), null);
      // Сессия вторичного устройства восстановлена из долговечных ключей.
      expect(newcomer.pairedSession!.id, started['deviceId']);

      // Идемпотентность: повтор не устанавливает и не пересоздаёт состояние.
      final again = await newcomer.completePairing(confirmText);
      expect(again['alreadyPaired'], true);
      expect(registry.installs, 1);
      expect(registry.deviceSessions, 1);
    }, timeout: const Timeout(Duration(minutes: 6)));

    test('crash-safe: сбой после коммита возобновляется тем же ключом', () async {
      final k = await sharedKeys();
      final registry = FakeRegistry();
      final (trustedStore, closeTrusted) = await openStore();
      final (newStore, closeNew) = await openStore();
      addTearDown(() async {
        await closeTrusted();
        await closeNew();
      });
      final trustedTransport = FakeTransport(registry, k.crypto);
      final newTransport = FakeTransport(registry, k.crypto);
      addTearDown(trustedTransport.dispose);
      addTearDown(newTransport.dispose);
      final trusted = await seedTrusted(
          k, trustedStore, trustedTransport, 'pair_flow');
      final newcomer = V2ChatRepository.pairing(
          transport: newTransport,
          crypto: k.crypto,
          store: newStore,
          account: 'pair_flow');
      await seedNewJournal(newStore, 'pair_flow', k.session);

      final challenge = trusted.pairingChallenge();
      final first = await newcomer.startPairing(
          challengeCode: challenge['code'] as String);
      // Повтор startPairing тем же ключом: идентичность не пересоздаётся.
      final second = await newcomer.startPairing(
          challengeCode: challenge['code'] as String);
      expect(second['deviceId'], first['deviceId']);
      expect((second['offer'] as Map)['nonce'],
          isNot((first['offer'] as Map)['nonce']));

      final confirmText =
          await trusted.approvePairing(second['offerText'] as String);
      // «Сбой» клиента после серверного коммита, до локальной фиксации.
      registry.failNextDeviceSession = true;
      await expectLater(newcomer.completePairing(confirmText),
          throwsA(isA<AlphaTransportException>()));
      final journal = await newStore.loadPairingJournal('pair_flow');
      expect(journal!['deviceId'], first['deviceId']);
      expect(journal['confirmation'], isNotNull);
      expect(journal['phase'], 'confirming');
      expect(await newStore.loadAccount('pair_flow'), null);

      // Повтор продолжает с журнала: тот же ключ, то же подтверждение.
      final completed = await newcomer.completePairing(confirmText);
      expect(completed['revision'], 2);
      expect(completed['deviceId'], first['deviceId']);
      expect((await newStore.loadDeviceKeys('pair_flow'))!['deviceId'],
          first['deviceId']);
      expect(await newStore.loadPairingJournal('pair_flow'), null);
      expect(registry.installs, 1);
    }, timeout: const Timeout(Duration(minutes: 6)));

    test('crash-safe доверенной стороны: install зафиксирован, клиент упал',
        () async {
      final k = await sharedKeys();
      final registry = FakeRegistry();
      final (trustedStore, closeTrusted) = await openStore();
      final (newStore, closeNew) = await openStore();
      addTearDown(() async {
        await closeTrusted();
        await closeNew();
      });
      final trustedTransport = FakeTransport(registry, k.crypto);
      final newTransport = FakeTransport(registry, k.crypto);
      addTearDown(trustedTransport.dispose);
      addTearDown(newTransport.dispose);
      final trusted = await seedTrusted(
          k, trustedStore, trustedTransport, 'pair_flow');
      final newcomer = V2ChatRepository.pairing(
          transport: newTransport,
          crypto: k.crypto,
          store: newStore,
          account: 'pair_flow');
      await seedNewJournal(newStore, 'pair_flow', k.session);
      final challenge = trusted.pairingChallenge();
      final started = await newcomer.startPairing(
          challengeCode: challenge['code'] as String);
      // Сбой после install, до локального сохранения доверенной стороны.
      registry.failDirectoryAfterInstall = true;
      await expectLater(
          trusted.approvePairing(started['offerText'] as String),
          throwsA(isA<AlphaTransportException>()));
      expect(registry.installs, 1);
      final journal = await trustedStore.loadPairingJournal('pair_flow');
      expect(journal!['role'], 'trusted');
      expect(journal['manifest'], isNotNull);
      // Повтор того же offer перенимает зафиксированный каталог без второго install.
      final confirmText =
          await trusted.approvePairing(started['offerText'] as String);
      expect(registry.installs, 1);
      expect(await trustedStore.loadPairingJournal('pair_flow'), null);
      final completed = await newcomer.completePairing(confirmText);
      expect(completed['revision'], 2);
    }, timeout: const Timeout(Duration(minutes: 6)));

    test('неверная подпись, чужой аккаунт, replay и expired challenge/offer',
        () async {
      final k = await sharedKeys();
      final registry = FakeRegistry();
      final (trustedStore, closeTrusted) = await openStore();
      final (newStore, closeNew) = await openStore();
      addTearDown(() async {
        await closeTrusted();
        await closeNew();
      });
      final trustedTransport = FakeTransport(registry, k.crypto);
      final newTransport = FakeTransport(registry, k.crypto);
      addTearDown(trustedTransport.dispose);
      addTearDown(newTransport.dispose);
      final trusted = await seedTrusted(
          k, trustedStore, trustedTransport, 'pair_flow');
      final newcomer = V2ChatRepository.pairing(
          transport: newTransport,
          crypto: k.crypto,
          store: newStore,
          account: 'pair_flow');
      await seedNewJournal(newStore, 'pair_flow', k.session);
      final challenge = trusted.pairingChallenge();
      final nonce = decodeChallenge(challenge['code'] as String);
      final started = await newcomer.startPairing(
          challengeCode: challenge['code'] as String);

      // Чужой аккаунт: offer подписан ключом устройства, но account другой.
      final foreign = await k.pairing.buildPairingOffer(
          account: 'someone_else',
          device: k.session.descriptor,
          signingPrivateKey: k.session.signingPrivateKey,
          challenge: nonce);
      await expectLater(trusted.approvePairing(encodeOffer(foreign)),
          throwsA(predicate((e) => e.toString().contains('другому аккаунту'))));

      // Неверная подпись: подменённый байт при валидной форме.
      final tampered = decodeOffer(started['offerText'] as String);
      final signature = tampered['signature'] as String;
      tampered['signature'] =
          (signature[0] == 'A' ? 'B' : 'A') + signature.substring(1);
      await expectLater(trusted.approvePairing(encodeOffer(tampered)),
          throwsA(predicate(
              (e) => e.toString().contains('Подпись устройства недействительна'))));

      // Неверный challenge (эхо не совпадает с кодом экрана).
      final wrongEcho = await k.pairing.buildPairingOffer(
          account: 'pair_flow',
          device: k.session.descriptor,
          signingPrivateKey: k.session.signingPrivateKey,
          challenge: 'f' * 30);
      await expectLater(trusted.approvePairing(encodeOffer(wrongEcho)),
          throwsA(predicate(
              (e) => e.toString().contains('Код подключения не совпадает'))));

      // Истёкший challenge доверенного экрана.
      trusted.pairingChallenge(
          now: DateTime.now().millisecondsSinceEpoch - challengeTtlMs - 1000);
      await expectLater(trusted.approvePairing(started['offerText'] as String),
          throwsA(predicate((e) => e.toString().contains('Код подключения истёк'))));

      // Истёкший offer: создан в прошлом, срок вышел.
      final fresh = trusted.pairingChallenge();
      final stale = await newcomer.startPairing(
          challengeCode: fresh['code'] as String,
          now: DateTime.now().millisecondsSinceEpoch - offerTtlMs - 1000);
      await expectLater(trusted.approvePairing(stale['offerText'] as String),
          throwsA(predicate((e) => e.toString().contains('Срок запроса истёк'))));

      // Happy approve, затем replay того же offer и повтор с новым кодом.
      final live = trusted.pairingChallenge();
      final offer = await newcomer.startPairing(
          challengeCode: live['code'] as String);
      final confirmText =
          await trusted.approvePairing(offer['offerText'] as String);
      expect(registry.installs, 1);
      // Challenge потреблён: повторное подтверждение тем же offer невозможно.
      await expectLater(trusted.approvePairing(offer['offerText'] as String),
          throwsA(predicate((e) => e.toString().contains('Код подключения истёк'))));
      // Новый код и свежий offer тем же ключом: устройство уже в ростере.
      final next = trusted.pairingChallenge();
      final repeat = await newcomer.startPairing(
          challengeCode: next['code'] as String);
      expect(repeat['deviceId'], offer['deviceId']);
      await expectLater(trusted.approvePairing(repeat['offerText'] as String),
          throwsA(predicate(
              (e) => e.toString().contains('Это устройство уже подключено'))));
      expect(registry.installs, 1);
      // Подтверждение при этом действительно и завершает подключение.
      expect((await newcomer.completePairing(confirmText))['revision'], 2);
    }, timeout: const Timeout(Duration(minutes: 6)));

    test('v1 offer переходного периода принимается без challenge в proof',
        () async {
      final k = await sharedKeys();
      final registry = FakeRegistry();
      final (trustedStore, closeTrusted) = await openStore();
      final (newStore, closeNew) = await openStore();
      addTearDown(() async {
        await closeTrusted();
        await closeNew();
      });
      final trustedTransport = FakeTransport(registry, k.crypto);
      final newTransport = FakeTransport(registry, k.crypto);
      addTearDown(trustedTransport.dispose);
      addTearDown(newTransport.dispose);
      final trusted = await seedTrusted(
          k, trustedStore, trustedTransport, 'pair_flow');
      await seedNewJournal(newStore, 'pair_flow', k.session);
      final challenge = trusted.pairingChallenge();
      final offer = await k.pairing.buildPairingOffer(
          account: 'pair_flow',
          device: k.session.descriptor,
          signingPrivateKey: k.session.signingPrivateKey,
          challenge: decodeChallenge(challenge['code'] as String),
          version: 1);
      final confirmText = await trusted.approvePairing(encodeOffer(offer));
      final proof = registry.lastProofs!.single as Map<String, dynamic>;
      expect(proof.containsKey('pairingVersion'), false);
      expect(proof.containsKey('challenge'), false);
      expect(registry.installs, 1);
      // Новое устройство завершает подключение тем же подтверждением.
      final newcomer = V2ChatRepository.pairing(
          transport: newTransport,
          crypto: k.crypto,
          store: newStore,
          account: 'pair_flow');
      expect((await newcomer.completePairing(confirmText))['revision'], 2);
    }, timeout: const Timeout(Duration(minutes: 6)));
  });

}

/// Общие синтетические ключи тестов (приватные части не покидают isolate).
class SharedKeys {
  final CryptoService crypto;
  final DeviceV2Pairing pairing;
  final KeyPair primary;
  final KeyPair recovery;
  final DeviceV2Session session;
  SharedKeys(this.crypto, this.pairing, this.primary, this.recovery, this.session);
}

/// Генерация общего набора ключей: primary, recovery и сессия нового
/// устройства. Дорогая (RSA-4096); вызывающий мемоизирует результат.
Future<SharedKeys> generateSharedKeys() async {
  FlutterSecureStorage.setMockInitialValues({});
  final crypto = CryptoService();
  final primary = await RSA.generate(4096);
  final recovery = await RSA.generate(4096);
  final pairing = DeviceV2Pairing(crypto);
  final session = await pairing.generateDeviceSession('pair_flow');
  return SharedKeys(crypto, pairing, primary, recovery, session);
}

/// Свежая SQLCipher-БД (ffi factory) во временной папке + очистка.
Future<(V2Store, Future<void> Function())> openStore() async {
  final folder = await Directory.systemTemp.createTemp('shade-pairing-');
  final db = await DatabaseService.openForTest(
      databaseFactoryFfi, '${folder.path}/db');
  return (
    V2Store(db),
    () async {
      await db.close();
      await folder.delete(recursive: true);
    }
  );
}

/// In-memory реестр alpha-процесса: проверяет цепочку манифестов и
/// challenge-bound pairing proofs той же криптографией, что и сервер.
class FakeRegistry {
  Map<String, dynamic>? genesis;
  final List<Map<String, dynamic>> history = [];
  int installs = 0;
  int deviceSessions = 0;
  List<dynamic>? lastProofs;
  bool failNextDeviceSession = false;
  bool failDirectoryAfterInstall = false;

  String get root =>
      ((genesis!['firstDevice'] as Map)['signingKey']) as String;

  Map<String, dynamic> directory() =>
      {'root': root, 'genesis': genesis, 'history': history};
}

class FakeTransport extends AlphaTransport {
  final FakeRegistry registry;
  final DeviceV2Verifier verifier;

  FakeTransport(this.registry, CryptoService crypto)
      : verifier = DeviceV2Verifier(crypto),
        super('https://pairing.fake', crypto);

  @override
  Future<Map<String, dynamic>> session() async => {
        'account': registry.genesis?['account'],
        'directory': registry.history.isEmpty ? null : registry.directory()
      };

  @override
  Future<Map<String, dynamic>> deviceSession(
      String account, String id, String privateKey) async {
    if (registry.failNextDeviceSession) {
      registry.failNextDeviceSession = false;
      throw AlphaTransportException(500, 'http_500');
    }
    final tip = registry.history.last;
    check((tip['devices'] as List).any((d) => d['id'] == id),
        'Unknown device');
    registry.deviceSessions++;
    return {
      'authenticated': true,
      'account': account,
      'directory': registry.directory()
    };
  }

  @override
  Future<dynamic> operation(String op, Object? body,
      {required String account,
      required String id,
      required String privateKey}) async {
    if (op == 'directory') {
      if (registry.installs > 0 && registry.failDirectoryAfterInstall) {
        registry.failDirectoryAfterInstall = false;
        throw AlphaTransportException(500, 'http_500');
      }
      check(body == account, 'Wrong directory target');
      return registry.directory();
    }
    if (op == 'install') {
      final payload = body as Map<String, dynamic>;
      final manifest = Map<String, dynamic>.from(payload['manifest'] as Map);
      final proofs = (payload['proofs'] as List?) ?? [];
      final tip = registry.history.last;
      final now = DateTime.now().millisecondsSinceEpoch;
      check(manifest['revision'] == (tip['revision'] as int) + 1,
          'Stale revision');
      check(manifest['previous'] == sha256Hex(manifestText(tip)),
          'Stale previous');
      // Полная цепочка: authority, ключи устройств, подпись манифеста.
      await verifier.verifyHistory([...registry.history, manifest],
          registry.root, null,
          now: manifest['issuedAt'] as int, genesis: registry.genesis);
      // Possession proof нового устройства: v2 challenge-bound, v1 legacy.
      for (final raw in proofs) {
        final proof = raw as Map<String, dynamic>;
        final device = (manifest['devices'] as List)
            .cast<Map<String, dynamic>>()
            .firstWhere((d) => d['id'] == proof['id']);
        check((proof['expiresAt'] as int) > now, 'Stale proof');
        final text = proof['pairingVersion'] == 2
            ? pairingTextV2(
                account,
                device,
                proof['nonce'] as String,
                proof['expiresAt'] as int,
                proof['challenge'] as String)
            : pairingText(account, device, proof['nonce'] as String,
                proof['expiresAt'] as int);
        check(
            await verifier.verify(
                text, proof['signature'] as String, device['signingKey'] as String),
            'Invalid pairing proof');
      }
      registry.history.add(manifest);
      registry.installs++;
      registry.lastProofs = proofs;
      return {
        'revision': manifest['revision'],
        'digest': sha256Hex(manifestText(manifest))
      };
    }
    throw UnimplementedError('op $op');
  }
}

/// Доверенное устройство: legacy-аккаунт, зарегистрированный в fake-реестре.
Future<V2ChatRepository> seedTrusted(SharedKeys k, V2Store store,
    FakeTransport transport, String account) async {
  final root = await publicSpki(k.primary.publicKey);
  final recoverySpki = await publicSpki(k.recovery.publicKey);
  final v2 = DeviceV2Crypto(k.crypto);
  final genesis = v2.buildLegacyGenesis(account, root, recoverySpki);
  genesis['signature'] =
      await k.crypto.signData(genesisText(genesis), k.primary.privateKey);
  final manifest = v2.buildLegacyManifest(account, root);
  manifest['signature'] =
      await k.crypto.signData(manifestText(manifest), k.primary.privateKey);
  transport.registry.genesis = genesis;
  transport.registry.history.add(manifest);
  await store.saveAccount(
      account: account,
      root: root,
      genesis: genesis,
      history: [manifest],
      checkpoint: {
        'account': account,
        'rootFingerprint': spkiFingerprint(root),
        'revision': 1,
        'digest': sha256Hex(manifestText(manifest)),
        'genesisDigest': sha256Hex(genesisText(genesis))
      },
      sessionId: 'primary');
  final repo = V2ChatRepository(
      transport: transport,
      crypto: k.crypto,
      store: store,
      account: account,
      root: root,
      privateKey: k.primary.privateKey);
  await repo.load();
  return repo;
}

/// Журнал нового устройства с уже созданными долговечными ключами.
Future<void> seedNewJournal(
    V2Store store, String account, DeviceV2Session session) async {
  await store.savePairingJournal(account, {
    'role': 'new',
    'phase': 'keys',
    'deviceId': session.id,
    'encryptionKey': session.encryptionKey,
    'signingKey': session.signingKey,
    'encryptionPrivate': session.encryptionPrivateKey,
    'signingPrivate': session.signingPrivateKey
  });
}