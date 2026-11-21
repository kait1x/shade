/// Нативное восстановление с recovery-пакетом (PRF_RECOVERY_BLOCKER §3).
///
/// Widget-тесты экрана (рендер/валидация/ошибки/плашка/очистка секретов) на
/// fake-репозитории; оркестрация recoverWithBackup на scripted transport с
/// КРИПТОГРАФИЧЕСКОЙ проверкой recovery-proof/манифеста/possession-proof как
/// в server/test/recovery-session.test.mjs; полный flow против РЕАЛЬНОГО
/// локального alpha-сервера (server/tools/alpha-native-recovery.mjs).
/// Только синтетические ключи.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fast_rsa/fast_rsa.dart';
import 'package:shade/core/services/picked_file.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/export.dart' show InvalidCipherTextException;
import 'package:shade/core/database/database_service.dart';
import 'package:shade/core/services/crypto_service.dart';
import 'package:shade/core/services/device_v2/crypto.dart';
import 'package:shade/core/services/device_v2/pairing.dart';
import 'package:shade/core/services/device_v2/protocol.dart';
import 'package:shade/core/services/device_v2/repository.dart';
import 'package:shade/core/services/device_v2/store.dart';
import 'package:shade/core/services/device_v2/transport.dart';
import 'package:shade/features/devices/presentation/recovery_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Реальный HttpClient против локального alpha-процесса (не mock-сеть).
class _RealNetworkBinding extends AutomatedTestWidgetsFlutterBinding {
  @override
  bool get overrideHttpClient => false;
}

const _recoveryPhrase = 'independent synthetic offline recovery passphrase only';
const _account = 'rec_native';

void main() {
  _RealNetworkBinding();
  sqfliteFfiInit();

  // ── Widget-тесты экрана ──────────────────────────────────────────────────

  group('экран восстановления', () {
    void phone(WidgetTester tester) {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
    }

    Finder field(String label) => find.widgetWithText(TextField, label);

    Future<void> tapText(WidgetTester tester, String text) async {
      final finder = find.text(text);
      await tester.ensureVisible(finder);
      await tester.pumpAndSettle();
      await tester.tap(finder);
      await tester.pumpAndSettle();
    }

    /// Синтетический пакет правильной ФОРМЫ (криптография не выполняется:
    /// репозиторий подменён fake-обработчиком).
    Map<String, dynamic> syntheticPackage({String account = 'rec_widget'}) {
      String b64(String s) => base64.encode(utf8.encode(s));
      return {
        'backup': {
          'version': 2,
          'account': account,
          'rootFingerprint': 'cd' * 32,
          'publicKey': b64('recovery-public'),
          'salt': base64.encode(List.filled(16, 1)),
          'iv': base64.encode(List.filled(12, 2)),
          'ciphertext': base64.encode(List.filled(64, 3)),
          'genesisDigest': 'ef' * 32
        },
        'genesis': {
          'version': 2,
          'account': account,
          'nonce': 'ab' * 32,
          'createdAt': 1763000000000,
          'legacy': true,
          'firstDevice': {
            'id': 'primary',
            'encryptionKey': b64('encryption'),
            'signingKey': b64('signing')
          },
          'recoveryKey': b64('recovery-public'),
          'signature': b64('signature')
        }
      };
    }

    PickedFile packageFile(Map<String, dynamic> pkg,
        {String name = 'shade-recovery-rec_widget.json'}) {
      final bytes = Uint8List.fromList(utf8.encode(jsonEncode(pkg)));
      return PickedFile(name: name, size: bytes.length, bytes: bytes);
    }

    /// Экран с fake-репозиторием: обработчик управляется тестом.
    Future<(_FakeRepository, _FakeTransport)> pumpScreen(
        WidgetTester tester,
        {Future<Map<String, dynamic>> Function(
                Map<String, dynamic> pkg, String phrase,
                {void Function(String)? onStep})? handler,
        Future<PickedFile?> Function()? picker}) async {
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({});
      final crypto = CryptoService();
      // Fake-репозиторий не обращается к store: не opened БД достаточно.
      // Реальный sqflite I/O внутри FakeAsync-зоны testWidgets не завершается.
      final store = V2Store(DatabaseService());
      final transport = _FakeTransport(crypto);
      transport.sessionCookie = 'shade-alpha=recovered-cookie';
      addTearDown(transport.dispose);
      final repo = _FakeRepository(
          transport: transport, crypto: crypto, store: store);
      repo.handler = handler ??
          (pkg, phrase, {onStep}) async => {
                'account': 'rec_widget',
                'revision': 2,
                'deviceId': 'ab' * 32
              };
      await tester.pumpWidget(MaterialApp(
          home: NativeRecoveryScreen(
              repository: repo, pickPackage: picker)));
      await tester.pumpAndSettle();
      return (repo, transport);
    }

    testWidgets('рендер: плашка, файл, фраза, честная защита без PRF-gate',
        (tester) async {
      phone(tester);
      await pumpScreen(tester);
      expect(find.text('Восстановление аккаунта'), findsOneWidget);
      expect(
          find.textContaining(
              'Старая переписка недоступна: она шифровалась под утраченные ключи'),
          findsOneWidget);
      expect(find.text('Выбрать файл пакета (JSON)'), findsOneWidget);
      expect(field('Recovery-фраза'), findsOneWidget);
      expect(find.text('Восстановить аккаунт'), findsOneWidget);
      // Нативная защита — SQLCipher/Keystore: фразовый gate устройства НЕ
      // показывается (решение lead: без декоративной защиты), PRF — позже.
      expect(find.textContaining('Фраза устройства'), findsNothing);
      expect(find.text('Биометрия (PRF)'), findsNothing);
      expect(
          find.textContaining('Новые ключи защищены шифрованным хранилищем устройства'),
          findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('submit без пакета: честная ошибка, вызова нет',
        (tester) async {
      phone(tester);
      final (repo, _) = await pumpScreen(tester);
      await tapText(tester, 'Восстановить аккаунт');
      expect(find.text('Выберите файл recovery-пакета.'), findsOneWidget);
      expect(repo.calls, isEmpty);
    });

    testWidgets('выбор пакета: имя/аккаунт; битый JSON/форма/размер отсекаются',
        (tester) async {
      phone(tester);
      PickedFile? next;
      final (repo, _) = await pumpScreen(tester, picker: () async => next);

      // Валидный пакет: имя и аккаунт видны ДО ввода фразы.
      next = packageFile(syntheticPackage());
      await tapText(tester, 'Выбрать файл пакета (JSON)');
      expect(find.textContaining('shade-recovery-rec_widget.json'), findsOneWidget);
      expect(find.textContaining('@rec_widget'), findsOneWidget);
      expect(find.text('Выбрать другой файл'), findsOneWidget);

      // Битый JSON.
      next = PickedFile(
          name: 'broken.json',
          size: 5,
          bytes: Uint8List.fromList(utf8.encode('{oops')));
      await tapText(tester, 'Выбрать другой файл');
      expect(
          find.text(
              'Файл не похож на recovery-пакет Shade: не удалось разобрать JSON.'),
          findsOneWidget);

      // Нет genesis.
      next = packageFile({'backup': syntheticPackage()['backup']});
      await tapText(tester, 'Выбрать другой файл');
      expect(
          find.text(
              'Файл не похож на recovery-пакет Shade: ожидается JSON с полями backup и genesis.'),
          findsOneWidget);

      // Genesis неверной формы (нет nonce) — каноническая проверка genesisText.
      final badGenesis = syntheticPackage();
      (badGenesis['genesis'] as Map).remove('nonce');
      next = packageFile(badGenesis);
      await tapText(tester, 'Выбрать другой файл');
      expect(find.textContaining('ожидается JSON с полями backup и genesis'),
          findsOneWidget);

      // Размер >1 МБ отсекается до разбора.
      next = PickedFile(
          name: 'huge.json',
          size: 1024 * 1024 + 1,
          bytes: Uint8List(1024 * 1024 + 1));
      await tapText(tester, 'Выбрать другой файл');
      expect(find.textContaining('ожидается JSON с полями backup и genesis'),
          findsOneWidget);
      expect(repo.calls, isEmpty);
    });

    testWidgets('валидация фразы: <24 символов — ошибка без вызова',
        (tester) async {
      phone(tester);
      PickedFile? next;
      final (repo, _) = await pumpScreen(tester, picker: () async => next);
      next = packageFile(syntheticPackage());
      await tapText(tester, 'Выбрать файл пакета (JSON)');
      await tester.enterText(field('Recovery-фраза'), 'короткая фраза');
      await tapText(tester, 'Восстановить аккаунт');
      expect(find.textContaining('Введите recovery-фразу из пакета'), findsOneWidget);
      expect(repo.calls, isEmpty);
    });

    testWidgets('успех: шаги, плашка, очистка секретов, фиксация сессии, переход',
        (tester) async {
      phone(tester);
      PickedFile? next;
      final gate = Completer<void>();
      final (repo, transport) = await pumpScreen(tester, picker: () async => next,
          handler: (pkg, phrase, {onStep}) async {
        onStep?.call('unlock');
        onStep?.call('keys');
        onStep?.call('session');
        onStep?.call('install');
        await gate.future;
        onStep?.call('bootstrap');
        return {'account': 'rec_widget', 'revision': 2, 'deviceId': 'ab' * 32};
      });
      next = packageFile(syntheticPackage());
      await tapText(tester, 'Выбрать файл пакета (JSON)');
      const phrase = 'correct horse battery staple correct horse battery';
      await tester.enterText(field('Recovery-фраза'), phrase);
      final phraseController =
          tester.widget<TextField>(field('Recovery-фраза')).controller!;
      // Submit под busy: одиночные pump (спиннер анимируется бесконечно,
      // pumpAndSettle не завершится, пока поток идёт).
      final submitFinder = find.text('Восстановить аккаунт');
      await tester.ensureVisible(submitFinder);
      await tester.pump();
      await tester.tap(submitFinder);
      await tester.pump();
      // Поток идёт: шаги видны, контролы заблокированы.
      expect(find.text('Проверяем recovery-пакет и фразу'), findsOneWidget);
      expect(find.text('Обновляем список устройств аккаунта'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsWidgets);
      final submit = tester.widget<FilledButton>(find.byType(FilledButton));
      expect(submit.onPressed, isNull);
      gate.complete();
      await tester.pumpAndSettle();
      // Успех: плашка в done-варианте, экран успеха, секреты очищены.
      expect(repo.calls.single.$2, phrase);
      expect(
          find.text(
              'Старая переписка недоступна: она шифровалась под утраченные ключи. Восстановлена личность и доступ к новым сообщениям.'),
          findsOneWidget);
      expect(find.text('Личность восстановлена'), findsOneWidget);
      expect(find.textContaining('@rec_widget'), findsWidgets);
      expect(phraseController.text, '');
      // Долговечная связка сессии для restore() после перезапуска.
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('alpha_v2_origin'), 'https://recovery.fake');
      expect(prefs.getString('alpha_v2_account'), 'rec_widget');
      const secure = FlutterSecureStorage(
          aOptions: AndroidOptions(encryptedSharedPreferences: true));
      expect(await secure.read(key: 'alpha_v2_cookie'),
          'shade-alpha=recovered-cookie');
      expect(transport.sessionCookie, 'shade-alpha=recovered-cookie');
      // Переход в чаты: маршрут закрывается с результатом true.
      bool? popped;
      await tester.pumpWidget(MaterialApp(
          home: Builder(
              builder: (context) => TextButton(
                  onPressed: () async {
                    popped = await Navigator.of(context).push<bool>(
                        MaterialPageRoute(
                            builder: (_) => NativeRecoveryScreen(
                                repository: repo,
                                pickPackage: () async => next)));
                  },
                  child: const Text('launch')))));
      await tester.tap(find.text('launch'));
      await tester.pumpAndSettle();
      // Повторный вход: пакет уже выбран ранее не сохраняется — выбираем снова.
      await tapText(tester, 'Выбрать файл пакета (JSON)');
      await tester.enterText(field('Recovery-фраза'), phrase);
      await tapText(tester, 'Восстановить аккаунт');
      await tapText(tester, 'Перейти в чаты');
      expect(popped, true);
    });

    testWidgets('ошибки: 429, неверная фраза, чужой пакет, genesis, нет сети',
        (tester) async {
      phone(tester);
      PickedFile? next;
      Object? failure;
      final (repo, _) = await pumpScreen(tester, picker: () async => next,
          handler: (pkg, phrase, {onStep}) async {
        throw failure!;
      });
      next = packageFile(syntheticPackage());
      await tapText(tester, 'Выбрать файл пакета (JSON)');
      await tester.enterText(
          field('Recovery-фраза'), 'correct horse battery staple correct horse');

      final cases = <Object, String>{
        AlphaTransportException(429, 'rate_limited'):
            'Слишком много попыток, подожди час',
        InvalidCipherTextException('mac check in GCM failed'):
            'Неверная recovery-фраза или повреждённый пакет. Проверьте фразу и файл.',
        ProtocolException('Recovery identity mismatch'):
            'Recovery-пакет не соответствует аккаунту: ключ или отпечаток не совпадают. Возможно, файл повреждён или это чужой пакет.',
        ProtocolException('Genesis digest mismatch'):
            'Genesis аккаунта на сервере не совпадает с пакетом. Восстановление остановлено; ключи не заменены.',
        AlphaTransportException(400, 'operation_rejected'):
            'Сервер отклонил операцию восстановления. Повторите попытку.',
        AlphaTransportException(401, 'login_required'):
            'Recovery-сессия истекла. Повторите восстановление.',
        const SocketException('Network is unreachable'):
            'Нет сети. Подключитесь к интернету и повторите попытку.',
      };
      for (final entry in cases.entries) {
        failure = entry.key;
        await tapText(tester, 'Восстановить аккаунт');
        expect(find.text(entry.value), findsOneWidget, reason: '${entry.key}');
        // Экран остаётся на форме: повтор возможен, состояние не тронуто.
        expect(find.text('Восстановить аккаунт'), findsOneWidget);
        expect(find.text('Личность восстановлена'), findsNothing);
      }
      expect(repo.calls.length, cases.length);
    });
  });

  // ── Оркестрация на scripted transport (криптопроверки как на сервере) ────

  group('recoverWithBackup: scripted transport', () {
    Future<_SharedIdentity>? identityFuture;
    Future<_SharedIdentity> sharedIdentity() =>
        identityFuture ??= _buildIdentity();

    test('полный flow: шаги, recovery-манифест, ростер заменён, фиксация',
        () async {
      final id = await sharedIdentity();
      final registry = _RecoveryRegistry.seeded(id);
      final (store, close) = await openStore();
      addTearDown(close);
      final transport = _ScriptedRecoveryTransport(registry, id.crypto);
      addTearDown(transport.dispose);
      final repo = V2ChatRepository.pairing(
          transport: transport,
          crypto: id.crypto,
          store: store,
          account: '');
      await repo.load();
      expect(repo.enrolled, false);

      final steps = <String>[];
      final result = await repo.recoverWithBackup(id.package, _recoveryPhrase,
          onStep: steps.add);
      expect(steps, ['unlock', 'keys', 'session', 'install', 'bootstrap']);
      expect(result['account'], _account);
      expect(result['revision'], 2);
      final deviceId = result['deviceId'] as String;
      expect(deviceId, matches(RegExp(r'^[a-f0-9]{64}$')));
      expect(deviceId, isNot('primary'));

      // Серверный ростер заменён: старое устройство retired, манифест recovery.
      expect(registry.installs, 1);
      expect(registry.retired, contains('primary'));
      final tip = registry.history.last;
      expect(tip['signer'], 'recovery');
      expect((tip['devices'] as List).map((d) => d['id']), [deviceId]);
      // Possession proof — challenge-bound v2 с self-generated challenge.
      final proof = registry.lastProofs!.single as Map<String, dynamic>;
      expect(proof['pairingVersion'], 2);
      expect(proof['challenge'], matches(RegExp(r'^[a-f0-9]{30}$')));
      expect(proof['id'], deviceId);

      // Локальная фиксация: ключи + состояние + сохранённый пакет.
      expect(repo.enrolled, true);
      expect(repo.account, _account);
      expect(repo.pairedSession!.id, deviceId);
      final acc = await store.loadAccount(_account);
      expect(acc!['sessionId'], deviceId);
      expect((acc['checkpoint'] as Map)['revision'], 2);
      expect((acc['checkpoint'] as Map)['genesisDigest'],
          sha256Hex(genesisText(id.genesis)));
      expect(acc['recovery'], id.package['backup']);
      final keys = await store.loadDeviceKeys(_account);
      expect(keys!['deviceId'], deviceId);
      expect(await store.loadPairingJournal(_account), null);

      // Повторный recoverWithBackup тем же пакетом создаёт НОВЫЕ ключи и
      // заменяет ростер ещё раз (веб-контракт: повтор не переиспользует ключи).
      final again = await repo.recoverWithBackup(id.package, _recoveryPhrase);
      expect(again['revision'], 3);
      expect(again['deviceId'], isNot(deviceId));
      expect(registry.retired, containsAll(['primary', deviceId]));
      expect((registry.history.last['devices'] as List).single['id'],
          again['deviceId']);
    }, timeout: const Timeout(Duration(minutes: 6)));

    test('прерванная попытка не оставляет ключей без состояния; повтор — новые ключи',
        () async {
      final id = await sharedIdentity();
      final registry = _RecoveryRegistry.seeded(id);
      final (store, close) = await openStore();
      addTearDown(close);
      final transport = _ScriptedRecoveryTransport(registry, id.crypto);
      addTearDown(transport.dispose);
      final repo = V2ChatRepository.pairing(
          transport: transport, crypto: id.crypto, store: store, account: '');
      await repo.load();

      // Сбой на install: ничего не закоммичено локально.
      registry.failNextOp = 'install';
      await expectLater(
          repo.recoverWithBackup(id.package, _recoveryPhrase),
          throwsA(isA<AlphaTransportException>()));
      expect(await store.loadAccount(_account), null);
      expect(await store.loadDeviceKeys(_account), null);
      expect(await store.loadPairingJournal(_account), null);
      expect(repo.enrolled, false);
      final firstAttemptDevice =
          (registry.lastAttemptManifest!['devices'] as List).single['id'];

      // Повтор создаёт новые ключи и завершает восстановление.
      final result = await repo.recoverWithBackup(id.package, _recoveryPhrase);
      expect(result['deviceId'], isNot(firstAttemptDevice));
      expect(result['revision'], 2);
      expect((await store.loadDeviceKeys(_account))!['deviceId'],
          result['deviceId']);
      expect(registry.installs, 1);

      // Сбой на bootstrap ПОСЛЕ серверного install: локально пусто, повтор
      // перенимает каталог новым манифестом (rev3) с ещё более новыми ключами.
      final registry2 = _RecoveryRegistry.seeded(id);
      final (store2, close2) = await openStore();
      addTearDown(close2);
      final transport2 = _ScriptedRecoveryTransport(registry2, id.crypto);
      addTearDown(transport2.dispose);
      final repo2 = V2ChatRepository.pairing(
          transport: transport2, crypto: id.crypto, store: store2, account: '');
      await repo2.load();
      registry2.failNextOp = 'bootstrap';
      await expectLater(
          repo2.recoverWithBackup(id.package, _recoveryPhrase),
          throwsA(isA<AlphaTransportException>()));
      expect(registry2.installs, 1); // сервер зафиксировал rev2
      expect(await store2.loadAccount(_account), null);
      expect(await store2.loadDeviceKeys(_account), null);
      final retry = await repo2.recoverWithBackup(id.package, _recoveryPhrase);
      expect(retry['revision'], 3);
      expect(retry['deviceId'], isNot(result['deviceId']));
      expect(registry2.installs, 2);
      expect((await store2.loadAccount(_account))!['sessionId'],
          retry['deviceId']);
    }, timeout: const Timeout(Duration(minutes: 6)));

    test('неверная фраза: сбой расшифровки до сети, состояние не тронуто',
        () async {
      final id = await sharedIdentity();
      final registry = _RecoveryRegistry.seeded(id);
      final (store, close) = await openStore();
      addTearDown(close);
      final transport = _ScriptedRecoveryTransport(registry, id.crypto);
      addTearDown(transport.dispose);
      final repo = V2ChatRepository.pairing(
          transport: transport, crypto: id.crypto, store: store, account: '');
      await repo.load();
      await expectLater(
          repo.recoverWithBackup(
              id.package, 'wrong recovery phrase wrong recovery phrase'),
          throwsA(isA<InvalidCipherTextException>()));
      expect(registry.challengesIssued, 0);
      expect(registry.installs, 0);
      expect(await store.loadAccount(_account), null);
      expect(await store.loadDeviceKeys(_account), null);
    }, timeout: const Timeout(Duration(minutes: 6)));

    test('чужой/подменённый genesis и чужой аккаунт пакета отсекаются',
        () async {
      final id = await sharedIdentity();
      final registry = _RecoveryRegistry.seeded(id);
      final (store, close) = await openStore();
      addTearDown(close);
      final transport = _ScriptedRecoveryTransport(registry, id.crypto);
      addTearDown(transport.dispose);
      final repo = V2ChatRepository.pairing(
          transport: transport, crypto: id.crypto, store: store, account: '');
      await repo.load();

      // Чужой genesis (другой аккаунт) с своим backup: identity mismatch.
      final foreignGenesis = Map<String, dynamic>.from(id.genesis)
        ..['account'] = 'someone_else';
      await expectLater(
          repo.recoverWithBackup(
              {'backup': id.package['backup'], 'genesis': foreignGenesis},
              _recoveryPhrase),
          throwsA(predicate(
              (e) => e.toString().contains('Recovery identity mismatch'))));

      // Подменённый genesis того же аккаунта (другой nonce): пакет не привязан.
      final substituted = Map<String, dynamic>.from(id.genesis)
        ..['nonce'] = 'f' * 64;
      await expectLater(
          repo.recoverWithBackup(
              {'backup': id.package['backup'], 'genesis': substituted},
              _recoveryPhrase),
          throwsA(predicate((e) =>
              e.toString().contains('must pin the exact account genesis'))));

      // Репозиторий уже привязан к аккаунту — чужой пакет не меняет личность.
      final bound = V2ChatRepository.pairing(
          transport: transport,
          crypto: id.crypto,
          store: store,
          account: 'another_account');
      await expectLater(
          bound.recoverWithBackup(id.package, _recoveryPhrase),
          throwsA(predicate((e) =>
              e.toString().contains('принадлежит другому аккаунту'))));
      expect(registry.challengesIssued, 0);
      expect(await store.loadAccount(_account), null);
    }, timeout: const Timeout(Duration(minutes: 6)));

    test('серверные негативы: replay nonce, чужой genesis на сервере, квота 429',
        () async {
      final id = await sharedIdentity();
      final registry = _RecoveryRegistry.seeded(id);
      final (store, close) = await openStore();
      addTearDown(close);
      final transport = _ScriptedRecoveryTransport(registry, id.crypto);
      addTearDown(transport.dispose);

      // Recovery-вход вручную: nonce + proof recovery-ключом.
      Future<Map<String, dynamic>> login() async {
        final nonce = await transport.recoveryChallenge(_account);
        final operation = operationDigest(
            'recovery-session', sha256Hex(genesisText(id.genesis)));
        final pem = await id.v2
            .unlockRecoveryBackup(id.backup, _recoveryPhrase, id.genesis);
        final proof = await id.crypto.signData(
            requestText(_account, 'primary', nonce, operation), pem);
        return transport.recoverySession(_account, id.genesis, nonce, proof);
      }

      final ok = await login();
      expect(ok['kind'], 'recovery');
      // Replay того же nonce+proof → 400 (nonce потреблён).
      await expectLater(
          transport.recoverySession(_account, id.genesis,
              registry.lastRecoveryNonce!, registry.lastRecoveryProof!),
          throwsA(predicate(
              (e) => e is AlphaTransportException && e.status == 400)));
      // Тот же proof с новым nonce → 400 (proof привязан к nonce).
      final freshNonce = await transport.recoveryChallenge(_account);
      await expectLater(
          transport.recoverySession(_account, id.genesis, freshNonce,
              registry.lastRecoveryProof!),
          throwsA(predicate(
              (e) => e is AlphaTransportException && e.status == 400)));
      // Подменённый genesis на сервере (тот же аккаунт, другой nonce) → 400.
      final substituted = Map<String, dynamic>.from(id.genesis)
        ..['nonce'] = 'e' * 64;
      final nonce3 = await transport.recoveryChallenge(_account);
      final operation3 = operationDigest(
          'recovery-session', sha256Hex(genesisText(id.genesis)));
      final pem = await id.v2
          .unlockRecoveryBackup(id.backup, _recoveryPhrase, id.genesis);
      final proof3 = await id.crypto.signData(
          requestText(_account, 'primary', nonce3, operation3), pem);
      await expectLater(
          transport.recoverySession(_account, substituted, nonce3, proof3),
          throwsA(predicate(
              (e) => e is AlphaTransportException && e.status == 400)));

      // Квота: 5 попыток/час (включая неудачные), 6-я → 429.
      // Уже было 4 попытки (ok + replay + freshNonce + substituted).
      await login(); // 5-я — успех
      await expectLater(login(),
          throwsA(predicate((e) =>
              e is AlphaTransportException &&
              e.status == 429 &&
              e.code == 'rate_limited')));
      expect(await store.loadAccount(_account), null);
    }, timeout: const Timeout(Duration(minutes: 6)));

    test('install: ростер со старым устройством отклоняется сервером',
        () async {
      final id = await sharedIdentity();
      final registry = _RecoveryRegistry.seeded(id);
      final (store, close) = await openStore();
      addTearDown(close);
      final transport = _ScriptedRecoveryTransport(registry, id.crypto);
      addTearDown(transport.dispose);
      final nonce = await transport.recoveryChallenge(_account);
      final operation = operationDigest(
          'recovery-session', sha256Hex(genesisText(id.genesis)));
      final pem = await id.v2
          .unlockRecoveryBackup(id.backup, _recoveryPhrase, id.genesis);
      final proof = await id.crypto.signData(
          requestText(_account, 'primary', nonce, operation), pem);
      await transport.recoverySession(_account, id.genesis, nonce, proof);

      // Манифест, сохраняющий старое устройство, подписан recovery-ключом,
      // но сервер требует ЗАМЕНЫ ростера только новыми устройствами.
      final newSession = await id.pairing.generateDeviceSession(_account);
      final tip = registry.history.last;
      final now = DateTime.now().millisecondsSinceEpoch;
      final keepOld = <String, dynamic>{
        'account': _account,
        'rootFingerprint': spkiFingerprint(id.root),
        'revision': (tip['revision'] as int) + 1,
        'previous': sha256Hex(manifestText(tip)),
        'issuedAt': now,
        'expiresAt': now + maxLeaseMs,
        'devices': [
          ...(tip['devices'] as List).cast<Map<String, dynamic>>(),
          newSession.descriptor
        ]..sort((a, b) => (a['id'] as String).compareTo(b['id'] as String)),
        'signer': 'recovery',
        'signature': ''
      };
      keepOld['signature'] =
          await id.crypto.signData(manifestText(keepOld), pem);
      await expectLater(
          transport.recoveryOperation('install',
              {'manifest': keepOld, 'proofs': []}, account: _account),
          throwsA(predicate(
              (e) => e is AlphaTransportException && e.status == 400)));
      expect(registry.installs, 0);
      // Прочие ops recovery-сессии запрещены.
      await expectLater(
          transport.recoveryOperation('fetch', null, account: _account),
          throwsA(predicate(
              (e) => e is AlphaTransportException && e.status == 400)));
    }, timeout: const Timeout(Duration(minutes: 6)));
  });

  // ── Оркестрация против РЕАЛЬНОГО локального alpha-сервера ────────────────

  test('recoverWithBackup против реального alpha.mjs: полный flow + неверная фраза',
      () async {
    FlutterSecureStorage.setMockInitialValues({});
    final crypto = CryptoService();
    final folder = await Directory.systemTemp.createTemp('shade-v2-recovery-');
    final db = await DatabaseService.openForTest(
        databaseFactoryFfi, '${folder.path}/db');
    final store = V2Store(db);

    final process = await Process.start(
        'node', ['../server/tools/alpha-native-recovery.mjs']);
    final lines = StreamIterator(process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter()));
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
      await db.close();
      await folder.delete(recursive: true);
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
    final init = await request({'action': 'init'});
    final transport = AlphaTransport(init['origin'] as String, crypto);
    addTearDown(transport.dispose);
    final repo = V2ChatRepository.pairing(
        transport: transport, crypto: crypto, store: store, account: '');
    await repo.load();
    expect(repo.enrolled, false);

    final steps = <String>[];
    final result = await repo.recoverWithBackup(
        Map<String, dynamic>.from(init['package'] as Map),
        init['recoveryPhrase'] as String,
        onStep: steps.add);
    expect(steps, ['unlock', 'keys', 'session', 'install', 'bootstrap']);
    expect(result['account'], 'native_rec');
    expect(result['revision'], 2);
    final deviceId = result['deviceId'] as String;
    expect(repo.enrolled, true);
    expect(repo.pairedSession!.id, deviceId);
    final acc = await store.loadAccount('native_rec');
    expect(acc!['sessionId'], deviceId);
    expect(acc['recovery'], isNotNull);
    expect((acc['checkpoint'] as Map)['revision'], 2);
    expect((await store.loadDeviceKeys('native_rec'))!['deviceId'], deviceId);

    // Сервер: старое устройство retired, ростер только из нового, signer recovery.
    final snap = await request({'action': 'snapshot'});
    expect(snap['retired'], contains(init['oldDeviceId']));
    expect(snap['devices'], [deviceId]);
    expect(snap['signer'], 'recovery');
    expect(snap['revision'], 2);
    // Старое устройство больше не получает challenge.
    expect((await request({'action': 'old-challenge'}))['status'], 400);
    // Новая device-сессия работает: подписанный fetch проходит.
    final fetched = await transport.operation('fetch', null,
        account: 'native_rec',
        id: deviceId,
        privateKey: repo.pairedSession!.signingPrivateKey);
    expect(fetched, isEmpty);

    // Неверная фраза после успеха: сбой до сети, состояние не тронуто.
    await expectLater(
        repo.recoverWithBackup(
            Map<String, dynamic>.from(init['package'] as Map),
            'wrong recovery phrase wrong recovery phrase'),
        throwsA(isA<InvalidCipherTextException>()));
    expect((await store.loadDeviceKeys('native_rec'))!['deviceId'], deviceId);
    expect((await store.loadAccount('native_rec'))!['sessionId'], deviceId);
  }, timeout: const Timeout(Duration(minutes: 6)));
}

// ── Фикстуры ────────────────────────────────────────────────────────────────

/// Свежая SQLCipher-БД (ffi factory) во временной папке + очистка.
Future<(V2Store, Future<void> Function())> openStore() async {
  final folder = await Directory.systemTemp.createTemp('shade-recovery-');
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

/// Общая синтетическая идентичность: legacy-genesis подписан исходным RSA,
/// recovery-ключ независим, пакет финализирован (привязан к точному genesis).
/// Генерация RSA-4096 дорогая — набор мемоизируется на весь файл.
class _SharedIdentity {
  final CryptoService crypto;
  final DeviceV2Crypto v2;
  final DeviceV2Pairing pairing;
  final String root;
  final String privateKey;
  final Map<String, dynamic> genesis;
  final Map<String, dynamic> manifest;
  final Map<String, dynamic> backup;
  _SharedIdentity(this.crypto, this.v2, this.pairing, this.root, this.privateKey,
      this.genesis, this.manifest, this.backup);

  Map<String, dynamic> get package => {'backup': backup, 'genesis': genesis};
}

Future<_SharedIdentity> _buildIdentity() async {
  FlutterSecureStorage.setMockInitialValues({});
  final crypto = CryptoService();
  final v2 = DeviceV2Crypto(crypto);
  final pairing = DeviceV2Pairing(crypto);
  final kp = await RSA.generate(4096);
  final root = await publicSpki(kp.publicKey);
  final backup =
      await v2.createRecoveryBackup(_account, root, _recoveryPhrase);
  final genesis =
      v2.buildLegacyGenesis(_account, root, backup['publicKey'] as String);
  genesis['signature'] =
      await crypto.signData(genesisText(genesis), kp.privateKey);
  final finalized =
      await v2.finalizeRecoveryBackup(backup, _recoveryPhrase, genesis);
  final manifest = v2.buildLegacyManifest(_account, root);
  manifest['signature'] =
      await crypto.signData(manifestText(manifest), kp.privateKey);
  return _SharedIdentity(
      crypto, v2, pairing, root, kp.privateKey, genesis, manifest, finalized);
}

/// In-memory реестр recovery-контракта: проверяет genesis digest, recovery-proof,
/// цепочку манифестов с authority recovery-ключа и challenge-bound possession
/// proofs той же криптографией, что и server/alpha.mjs + registry.mjs.
class _RecoveryRegistry {
  Map<String, dynamic>? genesis;
  final List<Map<String, dynamic>> history = [];
  final Set<String> retired = {};
  final Map<String, (String account, int expiresAt)> challenges = {};
  final Map<String, List<int>> attempts = {};
  bool recoverySession = false;
  String? sessionAccount;
  int installs = 0;
  int deviceSessions = 0;
  int challengesIssued = 0;
  List<dynamic>? lastProofs;
  Map<String, dynamic>? lastAttemptManifest;
  String? lastRecoveryNonce;
  String? lastRecoveryProof;
  String? failNextOp;

  _RecoveryRegistry.seeded(_SharedIdentity id) {
    genesis = jsonDecode(jsonEncode(id.genesis)) as Map<String, dynamic>;
    history.add(jsonDecode(jsonEncode(id.manifest)) as Map<String, dynamic>);
  }

  String get root => (genesis!['firstDevice'] as Map)['signingKey'] as String;

  Map<String, dynamic> directory() =>
      {'root': root, 'genesis': genesis, 'history': history};
}

Never _reject(int status, String code) =>
    throw AlphaTransportException(status, code);

class _ScriptedRecoveryTransport extends AlphaTransport {
  final _RecoveryRegistry registry;
  final DeviceV2Verifier verifier;

  _ScriptedRecoveryTransport(this.registry, CryptoService crypto)
      : verifier = DeviceV2Verifier(crypto),
        super('https://recovery.fake', crypto);

  @override
  Future<String> recoveryChallenge(String account) async {
    final reg = registry;
    if (reg.genesis == null ||
        reg.history.isEmpty ||
        reg.genesis!['account'] != account) {
      _reject(400, 'operation_rejected'); // Account is not enrolled
    }
    final nonce = randomHex(32); // 64 hex — формат серверного token()
    reg.challenges[nonce] = (
      account,
      DateTime.now().millisecondsSinceEpoch + 60000
    );
    reg.challengesIssued++;
    return nonce;
  }

  @override
  Future<Map<String, dynamic>> recoverySession(String account,
      Map<String, dynamic> genesis, String nonce, String proof) async {
    final reg = registry;
    final now = DateTime.now().millisecondsSinceEpoch;
    // Квота попыток на аккаунт (включая неудачные): ≤5/час.
    final list = (reg.attempts[account] ?? [])
      ..removeWhere((t) => t <= now - 3600000);
    if (list.length >= 5) _reject(429, 'rate_limited');
    list.add(now);
    reg.attempts[account] = list;
    // Nonce одноразовый: потребляется даже при неудаче.
    final challenge = reg.challenges.remove(nonce);
    if (challenge == null ||
        challenge.$1 != account ||
        challenge.$2 <= now) {
      _reject(400, 'operation_rejected'); // Invalid or replayed challenge
    }
    if (reg.genesis == null || reg.history.isEmpty) {
      _reject(400, 'operation_rejected');
    }
    final String broughtDigest;
    try {
      broughtDigest = sha256Hex(genesisText(genesis));
    } catch (_) {
      _reject(400, 'operation_rejected');
    }
    if (broughtDigest != sha256Hex(genesisText(reg.genesis!)) ||
        genesis['recoveryKey'] != reg.genesis!['recoveryKey']) {
      _reject(400, 'operation_rejected'); // Genesis digest / key mismatch
    }
    final operation = operationDigest('recovery-session', broughtDigest);
    if (!await verifier.verify(
        requestText(account, 'primary', nonce, operation),
        proof,
        reg.genesis!['recoveryKey'] as String)) {
      _reject(400, 'operation_rejected'); // Invalid recovery proof
    }
    reg.recoverySession = true;
    reg.sessionAccount = account;
    reg.lastRecoveryNonce = nonce;
    reg.lastRecoveryProof = proof;
    return {
      'authenticated': true,
      'account': account,
      'kind': 'recovery',
      'directory': reg.directory()
    };
  }

  @override
  Future<dynamic> recoveryOperation(String op, Object? body,
      {required String account}) async {
    final reg = registry;
    if (!reg.recoverySession || reg.sessionAccount != account) {
      _reject(401, 'login_required');
    }
    if (op == 'directory') {
      if (body != account) _reject(400, 'operation_rejected');
      if (reg.failNextOp == 'directory') {
        reg.failNextOp = null;
        _reject(500, 'http_500');
      }
      return reg.directory();
    }
    if (op == 'install') {
      final payload = body as Map<String, dynamic>;
      final manifest = Map<String, dynamic>.from(payload['manifest'] as Map);
      reg.lastAttemptManifest = manifest;
      if (reg.failNextOp == 'install') {
        reg.failNextOp = null;
        _reject(500, 'http_500');
      }
      final proofs = (payload['proofs'] as List?) ?? [];
      if (manifest['account'] != account || manifest['signer'] != 'recovery') {
        _reject(400, 'operation_rejected');
      }
      final tip = reg.history.last;
      // Ростер заменяется ТОЛЬКО новыми устройствами; старые retire-ятся.
      if (!(manifest['devices'] as List).every((d) =>
          !(tip['devices'] as List).any((o) => o['id'] == d['id']))) {
        _reject(400, 'operation_rejected');
      }
      final now = DateTime.now().millisecondsSinceEpoch;
      try {
        check(manifest['revision'] == (tip['revision'] as int) + 1);
        check(manifest['previous'] == sha256Hex(manifestText(tip)));
        // Полная цепочка: authority recovery-ключа, ключи устройств, подпись.
        await verifier.verifyHistory([...reg.history, manifest], reg.root, null,
            now: manifest['issuedAt'] as int, genesis: reg.genesis);
        // Possession proof нового устройства: challenge-bound v2.
        for (final raw in proofs) {
          final proof = raw as Map<String, dynamic>;
          final device = (manifest['devices'] as List)
              .cast<Map<String, dynamic>>()
              .firstWhere((d) => d['id'] == proof['id']);
          check((proof['expiresAt'] as int) > now, 'Stale proof');
          check(proof['pairingVersion'] == 2, 'Recovery requires v2 proof');
          final text = pairingTextV2(
              account,
              device,
              proof['nonce'] as String,
              proof['expiresAt'] as int,
              proof['challenge'] as String);
          check(
              await verifier.verify(text, proof['signature'] as String,
                  device['signingKey'] as String),
              'Invalid pairing proof');
        }
      } on ProtocolException {
        _reject(400, 'operation_rejected');
      }
      for (final d in tip['devices']) {
        reg.retired.add(d['id'] as String);
      }
      reg.history.add(manifest);
      reg.installs++;
      reg.lastProofs = proofs;
      return {
        'revision': manifest['revision'],
        'digest': sha256Hex(manifestText(manifest))
      };
    }
    _reject(400, 'operation_rejected'); // Recovery allows directory/install only
  }

  @override
  Future<Map<String, dynamic>> deviceSession(
      String account, String id, String privateKey) async {
    final reg = registry;
    if (reg.failNextOp == 'bootstrap') {
      reg.failNextOp = null;
      _reject(500, 'http_500');
    }
    final tip = reg.history.last;
    if (!(tip['devices'] as List).any((d) => d['id'] == id) ||
        reg.retired.contains(id)) {
      _reject(400, 'operation_rejected');
    }
    reg.deviceSessions++;
    // Обычная device-сессия заменяет recovery-сессию.
    reg.recoverySession = false;
    reg.sessionAccount = account;
    return {
      'authenticated': true,
      'account': account,
      'directory': reg.directory()
    };
  }

  @override
  Future<dynamic> operation(String op, Object? body,
      {required String account,
      required String id,
      required String privateKey}) async {
    final reg = registry;
    if (op == 'directory') {
      if (reg.failNextOp == 'fresh-directory') {
        reg.failNextOp = null;
        _reject(500, 'http_500');
      }
      if (!(reg.history.last['devices'] as List).any((d) => d['id'] == id)) {
        _reject(400, 'operation_rejected');
      }
      return reg.directory();
    }
    if (op == 'fetch') {
      if (!(reg.history.last['devices'] as List).any((d) => d['id'] == id)) {
        _reject(400, 'operation_rejected');
      }
      return [];
    }
    throw UnimplementedError('op $op');
  }
}

/// Fake-транспорт для widget-тестов: сеть не используется.
class _FakeTransport extends AlphaTransport {
  _FakeTransport(CryptoService crypto) : super('https://recovery.fake', crypto);
}

/// Fake-репозиторий для widget-тестов: обработчик recoverWithBackup управляется
/// тестом (криптография и сеть проверяются в оркестрационных тестах выше).
class _FakeRepository extends V2ChatRepository {
  _FakeRepository(
      {required super.transport, required super.crypto, required super.store})
      : super(account: '', root: '', privateKey: '');

  final calls = <(Map<String, dynamic>, String)>[];
  Future<Map<String, dynamic>> Function(Map<String, dynamic> pkg, String phrase,
      {void Function(String)? onStep})? handler;

  @override
  Future<Map<String, dynamic>> recoverWithBackup(
      Map<String, dynamic> pkg, String recoveryPhrase,
      {void Function(String step)? onStep}) {
    calls.add((pkg, recoveryPhrase));
    return handler!(pkg, recoveryPhrase, onStep: onStep);
  }
}