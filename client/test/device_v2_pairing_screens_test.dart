import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shade/core/services/device_v2/pairing.dart';
import 'package:shade/core/services/device_v2/repository.dart';
import 'package:shade/features/devices/presentation/pairing_approve_screen.dart';
import 'package:shade/features/devices/presentation/pairing_common.dart';
import 'package:shade/features/devices/presentation/pairing_new_device_screen.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

// Общие fake-хелперы (реестр/транспорт/ключи) живут в pairing-тесте репозитория.
import 'device_v2_pairing_test.dart';

/// Экраны pairing: рендеринг кода/countdown, semantics, честные русские ошибки
/// и expired-состояние. Отдельный файл: widget-тесты (fake async) изолированы
/// от тяжёлых real-async тестов репозитория (SQLCipher/FFI isolates).
/// Весь реальный I/O setup — внутри tester.runAsync после первого pump.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  Future<SharedKeys>? keysFuture;
  Future<SharedKeys> sharedKeys() => keysFuture ??= generateSharedKeys();

  testWidgets('approve: код, countdown, честная ошибка мусорного offer',
      (tester) async {
    await tester.pumpWidget(const SizedBox());
    late V2ChatRepository trusted;
    late FakeTransport transport;
    late Future<void> Function() close;
    await tester.runAsync(() async {
      final k = await sharedKeys();
      final registry = FakeRegistry();
      final (store, cleanup) = await openStore();
      close = cleanup;
      transport = FakeTransport(registry, k.crypto);
      trusted = await seedTrusted(k, store, transport, 'pair_flow');
    });
    await tester.pumpWidget(
        MaterialApp(home: PairingApproveScreen(repository: trusted)));
    await tester.pump();
    // Одноразовый код показан и доступен для копирования.
    final codeFinder = find.byWidgetPredicate((w) =>
        w is SelectableText &&
        RegExp(r'^[0-9A-HJKMNP-TV-Z]{6}(-[0-9A-HJKMNP-TV-Z]{6}){3}$')
            .hasMatch(w.data ?? ''));
    expect(codeFinder, findsOneWidget);
    expect(find.textContaining('Код действует ещё'), findsOneWidget);
    expect(tester.getSemantics(find.byType(PairingCodeCard).first).label,
        'Код подключения');
    // Мусорный offer: честная русская ошибка без изменения состояния.
    await tester.enterText(find.byType(TextField), 'мусорный запрос');
    await tester.tap(find.text('Проверить запрос'));
    await tester.pump();
    await tester.pump();
    expect(find.text('Неверный формат кода подключения'), findsOneWidget);
    expect(find.text('Сверьте перед подтверждением'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    transport.dispose();
    await tester.runAsync(close);
  }, timeout: const Timeout(Duration(minutes: 6)));

  testWidgets('approve: истёкший код блокирует проверку и обновляется',
      (tester) async {
    await tester.pumpWidget(const SizedBox());
    late V2ChatRepository trusted;
    late FakeTransport transport;
    late Future<void> Function() close;
    await tester.runAsync(() async {
      final k = await sharedKeys();
      final registry = FakeRegistry();
      final (store, cleanup) = await openStore();
      close = cleanup;
      transport = FakeTransport(registry, k.crypto);
      trusted = await seedTrusted(k, store, transport, 'pair_flow');
    });
    final expired = FirstChallengeExpiredRepo(
        transport: transport,
        crypto: trusted.crypto,
        store: trusted.store,
        account: 'pair_flow',
        root: trusted.root,
        privateKey: trusted.privateKey);
    await tester.pumpWidget(
        MaterialApp(home: PairingApproveScreen(repository: expired)));
    await tester.pump();
    expect(find.textContaining('Код подключения истёк'), findsOneWidget);
    // Проверка заблокирована до генерации нового кода.
    final reviewButton = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Проверить запрос'));
    expect(reviewButton.onPressed, null);
    await tester.tap(find.text('Сгенерировать новый код'));
    await tester.pump();
    expect(find.textContaining('Код действует ещё'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    transport.dispose();
    await tester.runAsync(close);
  }, timeout: const Timeout(Duration(minutes: 6)));

  testWidgets('new device: честные ошибки ввода кода', (tester) async {
    await tester.pumpWidget(const SizedBox());
    late V2ChatRepository newcomer;
    late FakeTransport transport;
    late Future<void> Function() close;
    await tester.runAsync(() async {
      final k = await sharedKeys();
      final registry = FakeRegistry();
      final (store, cleanup) = await openStore();
      close = cleanup;
      transport = FakeTransport(registry, k.crypto);
      newcomer = V2ChatRepository.pairing(
          transport: transport,
          crypto: k.crypto,
          store: store,
          account: 'pair_flow');
    });
    await tester.pumpWidget(
        MaterialApp(home: PairingNewDeviceScreen(repository: newcomer)));
    await tester.pump();
    await tester.tap(find.text('Создать запрос'));
    await tester.pump();
    expect(find.text('Введите код подключения с доверенного устройства.'),
        findsOneWidget);
    await tester.enterText(find.byType(TextField), 'ABCD-EFGH');
    await tester.tap(find.text('Создать запрос'));
    await tester.pump();
    await tester.pump();
    expect(find.text('Код подключения состоит из 24 символов'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'U' * 24);
    await tester.tap(find.text('Создать запрос'));
    await tester.pump();
    await tester.pump();
    expect(find.text('В коде подключения недопустимый символ'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    transport.dispose();
    await tester.runAsync(close);
  }, timeout: const Timeout(Duration(minutes: 6)));
}

/// Первый challenge истёк (сбой часов/долгая пауза), следующий — свежий.
class FirstChallengeExpiredRepo extends V2ChatRepository {
  FirstChallengeExpiredRepo({
    required super.transport,
    required super.crypto,
    required super.store,
    required super.account,
    required super.root,
    required super.privateKey,
  });

  bool _first = true;

  @override
  Map<String, dynamic> pairingChallenge({int? now}) {
    if (_first) {
      _first = false;
      return super.pairingChallenge(
          now: DateTime.now().millisecondsSinceEpoch - challengeTtlMs - 1000);
    }
    return super.pairingChallenge(now: now);
  }
}