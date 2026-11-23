import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shade/features/web/presentation/alpha_app.dart';
import 'package:shade/features/web/presentation/alpha_controller.dart';
import 'package:shade/features/web/presentation/recovery_screen.dart';

// Экран восстановления (PRF_RECOVERY_BLOCKER §3): Flutter — проекция,
// криптография и сеть живут в JS-ядре. Тесты проверяют рендер, валидацию
// полей, честные ошибки, шаги загрузки, плашку и dispatch действий моста.
void main() {
  // Форма выше viewport телефона: экран обязан скроллиться без overflow.
  void phone(WidgetTester tester) {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
  }

  Map<String, dynamic> projection({
    String step = 'form',
    bool busy = false,
    String? stepId,
    String? fileName,
    String? packageAccount,
    bool prfAvailable = false,
    String? error,
  }) =>
      {
        'mode': 'recovery',
        'recovery': {
          'step': step,
          'busy': busy,
          'stepId': stepId,
          'fileName': fileName,
          'packageAccount': packageAccount,
          'prfAvailable': prfAvailable,
          'error': error,
        },
      };

  const phrase = 'correct horse battery staple correct horse battery';
  const devicePhrase = 'device passphrase 123';

  Finder field(String label) => find.widgetWithText(TextField, label);

  Future<void> tapText(WidgetTester tester, String text) async {
    final finder = find.text(text);
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  testWidgets('Recovery screen renders with honest banner and live controls',
      (tester) async {
    phone(tester);
    final c = AlphaController((_, __) async => null);
    c.apply(projection());
    await tester.pumpWidget(ShadeAlphaApp(controller: c));
    await tester.pumpAndSettle();
    expect(find.byType(RecoveryScreen), findsOneWidget);
    // Чатная оболочка не строится до появления device-сессии.
    expect(find.byTooltip('Профиль'), findsNothing);
    expect(find.text('Восстановление аккаунта'), findsOneWidget);
    expect(
        find.textContaining('Старая переписка недоступна: она шифровалась под утраченные ключи'),
        findsOneWidget);
    expect(find.text('Выбрать файл пакета (JSON)'), findsOneWidget);
    expect(field('Пароль восстановления'), findsOneWidget);
    expect(field('Фраза устройства · от 16 символов'), findsOneWidget);
    expect(field('Повторите фразу устройства'), findsOneWidget);
    expect(find.text('Восстановить аккаунт'), findsOneWidget);
    expect(find.text('Назад к разблокировке'), findsOneWidget);
    // PRF недоступен: варианта нет, есть честное объяснение.
    expect(find.text('Биометрия (PRF)'), findsNothing);
    expect(
        find.textContaining('Биометрическая защита (PRF) недоступна в этом браузере'),
        findsOneWidget);
    expect(tester.takeException(), isNull);
    c.dispose();
  });

  testWidgets('Submit without a package shows an honest error, no dispatch',
      (tester) async {
    phone(tester);
    final actions = <String>[];
    final c = AlphaController((action, _) async {
      actions.add(action);
      return null;
    });
    c.apply(projection());
    await tester.pumpWidget(ShadeAlphaApp(controller: c));
    await tester.pumpAndSettle();
    await tapText(tester, 'Восстановить аккаунт');
    expect(find.text('Выберите файл recovery-пакета.'), findsOneWidget);
    expect(actions, isEmpty);
    c.dispose();
  });

  testWidgets('Field validation: phrase length, device phrase, confirmation',
      (tester) async {
    phone(tester);
    final runs = <Map<String, dynamic>>[];
    final c = AlphaController((action, payload) async {
      if (action == 'recovery.run') runs.add({...payload});
      return null;
    });
    c.apply(projection(
        fileName: 'shade-recovery-alice.json', packageAccount: 'alice'));
    await tester.pumpWidget(ShadeAlphaApp(controller: c));
    await tester.pumpAndSettle();
    // Пароль короче минимальной длины.
    await tester.enterText(field('Пароль восстановления'), 'CobaltMaple');
    await tapText(tester, 'Восстановить аккаунт');
    expect(find.textContaining('Введите пароль восстановления'), findsOneWidget);
    expect(runs, isEmpty);
    // Фраза устройства короче 16 символов.
    await tester.enterText(field('Пароль восстановления'), phrase);
    await tester.enterText(field('Фраза устройства · от 16 символов'), 'short');
    await tapText(tester, 'Восстановить аккаунт');
    expect(find.text('Фраза устройства должна быть не короче 16 символов.'),
        findsOneWidget);
    expect(runs, isEmpty);
    // Подтверждение не совпадает.
    await tester.enterText(
        field('Фраза устройства · от 16 символов'), devicePhrase);
    await tester.enterText(
        field('Повторите фразу устройства'), 'other passphrase 123');
    await tapText(tester, 'Восстановить аккаунт');
    expect(find.text('Фразы устройства не совпадают.'), findsOneWidget);
    expect(runs, isEmpty);
    // Валидный ввод уходит в JS-ядро ровно один раз.
    await tester.enterText(
        field('Повторите фразу устройства'), devicePhrase);
    await tapText(tester, 'Восстановить аккаунт');
    expect(runs, [
      {
        'recoveryPhrase': phrase,
        'protection': 'phrase',
        'devicePassphrase': devicePhrase,
      }
    ]);
    c.dispose();
  });

  testWidgets('PRF protection dispatches without a device passphrase',
      (tester) async {
    phone(tester);
    final runs = <Map<String, dynamic>>[];
    final c = AlphaController((action, payload) async {
      if (action == 'recovery.run') runs.add({...payload});
      return null;
    });
    c.apply(projection(
        fileName: 'shade-recovery-alice.json',
        packageAccount: 'alice',
        prfAvailable: true));
    await tester.pumpWidget(ShadeAlphaApp(controller: c));
    await tester.pumpAndSettle();
    await tapText(tester, 'Биометрия (PRF)');
    // Фразовые поля исчезают: секрет выводит аутентификатор.
    expect(field('Фраза устройства · от 16 символов'), findsNothing);
    expect(find.textContaining('При утрате passkey снова понадобится recovery-пакет'),
        findsOneWidget);
    await tester.enterText(field('Пароль восстановления'), phrase);
    await tapText(tester, 'Восстановить аккаунт');
    expect(runs, [
      {'recoveryPhrase': phrase, 'protection': 'prf'}
    ]);
    c.dispose();
  });

  testWidgets('PRF lost mid-flow falls back to the device phrase honestly',
      (tester) async {
    phone(tester);
    final runs = <Map<String, dynamic>>[];
    final c = AlphaController((action, payload) async {
      if (action == 'recovery.run') runs.add({...payload});
      return null;
    });
    c.apply(projection(
        fileName: 'shade-recovery-alice.json',
        packageAccount: 'alice',
        prfAvailable: true));
    await tester.pumpWidget(ShadeAlphaApp(controller: c));
    await tester.pumpAndSettle();
    await tapText(tester, 'Биометрия (PRF)');
    // Аутентификатор отказал: проекция сообщает недоступность.
    c.apply(projection(
        fileName: 'shade-recovery-alice.json',
        packageAccount: 'alice',
        prfAvailable: false,
        error: 'Аутентификатор не поддерживает вывод ключа (PRF). Выберите защиту фразой устройства.'));
    await tester.pumpAndSettle();
    expect(find.text('Биометрия (PRF)'), findsNothing);
    expect(field('Фраза устройства · от 16 символов'), findsOneWidget);
    await tester.enterText(field('Пароль восстановления'), phrase);
    await tester.enterText(
        field('Фраза устройства · от 16 символов'), devicePhrase);
    await tester.enterText(
        field('Повторите фразу устройства'), devicePhrase);
    await tapText(tester, 'Восстановить аккаунт');
    expect(runs.single['protection'], 'phrase');
    expect(runs.single['devicePassphrase'], devicePhrase);
    c.dispose();
  });

  testWidgets('Server and network errors render honestly in Russian',
      (tester) async {
    phone(tester);
    final c = AlphaController((_, __) async => null);
    c.apply(projection());
    await tester.pumpWidget(ShadeAlphaApp(controller: c));
    await tester.pumpAndSettle();
    const texts = [
      'Слишком много попыток, подожди час',
      'Неверная recovery-фраза или повреждённый пакет. Проверьте фразу и файл.',
      'Recovery-пакет не соответствует аккаунту: ключ или отпечаток не совпадают. Возможно, файл повреждён или это чужой пакет.',
      'Genesis аккаунта на сервере не совпадает с пакетом. Восстановление остановлено; ключи не заменены.',
      'Challenge восстановления истёк или уже использован. Повторите попытку.',
      'Нет сети. Подключитесь к интернету и повторите попытку.',
      'Сервер недоступен. Проверьте соединение и повторите попытку.',
    ];
    for (final text in texts) {
      c.apply(projection(error: text));
      await tester.pumpAndSettle();
      expect(find.text(text), findsOneWidget, reason: text);
    }
    // Ошибка исчезает, когда ядро сообщает об успехе шага.
    c.apply(projection());
    await tester.pumpAndSettle();
    expect(find.text(texts.first), findsNothing);
    c.dispose();
  });

  testWidgets('Busy state shows step progress and disables the controls',
      (tester) async {
    phone(tester);
    final c = AlphaController((_, __) async => null);
    c.apply(projection(busy: true, stepId: 'install'));
    await tester.pumpWidget(ShadeAlphaApp(controller: c));
    // Индикатор шага анимируется бесконечно: только одиночный pump.
    await tester.pump();
    expect(find.text('Проверяем recovery-пакет и фразу'), findsOneWidget);
    expect(find.text('Создаём новые ключи устройства'), findsOneWidget);
    expect(find.text('Обновляем список устройств аккаунта'), findsOneWidget);
    expect(find.text('Открываем сессию нового устройства'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsWidgets);
    final submit = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Восстанавливаем…'));
    expect(submit.onPressed, isNull);
    final pick = tester.widget<OutlinedButton>(
        find.widgetWithText(OutlinedButton, 'Выбрать файл пакета (JSON)'));
    expect(pick.onPressed, isNull);
    c.dispose();
  });

  testWidgets('Success keeps the honest banner and opens the app via the bridge',
      (tester) async {
    phone(tester);
    final actions = <String>[];
    final c = AlphaController((action, _) async {
      actions.add(action);
      return null;
    });
    c.apply(projection(step: 'done', packageAccount: 'alice'));
    await tester.pumpWidget(ShadeAlphaApp(controller: c));
    await tester.pumpAndSettle();
    expect(
        find.text(
            'Старая переписка недоступна: она шифровалась под утраченные ключи. Восстановлена личность и доступ к новым сообщениям.'),
        findsOneWidget);
    expect(find.text('Личность восстановлена'), findsOneWidget);
    expect(find.textContaining('@alice'), findsWidgets);
    await tapText(tester, 'Открыть Shade');
    expect(actions, ['recovery.finish']);
    c.dispose();
  });

  testWidgets('File pick dispatches recovery.pick and shows the chosen package',
      (tester) async {
    phone(tester);
    final actions = <String>[];
    final c = AlphaController((action, _) async {
      actions.add(action);
      return null;
    });
    c.apply(projection());
    await tester.pumpWidget(ShadeAlphaApp(controller: c));
    await tester.pumpAndSettle();
    await tapText(tester, 'Выбрать файл пакета (JSON)');
    expect(actions, ['recovery.pick']);
    // Ядро прочитало файл: имя и аккаунт приходят проекцией, не содержимое.
    c.apply(projection(
        fileName: 'shade-recovery-alice.json', packageAccount: 'alice'));
    await tester.pumpAndSettle();
    expect(find.textContaining('shade-recovery-alice.json'), findsOneWidget);
    expect(find.textContaining('@alice'), findsOneWidget);
    expect(find.text('Выбрать другой файл'), findsOneWidget);
    c.dispose();
  });

  testWidgets('Back returns to the unlock screen through the bridge',
      (tester) async {
    phone(tester);
    final actions = <String>[];
    final c = AlphaController((action, _) async {
      actions.add(action);
      return null;
    });
    c.apply(projection());
    await tester.pumpWidget(ShadeAlphaApp(controller: c));
    await tester.pumpAndSettle();
    await tapText(tester, 'Назад к разблокировке');
    expect(actions, ['recovery.back']);
    c.dispose();
  });

  testWidgets('Secret fields are cleared once recovery succeeds',
      (tester) async {
    phone(tester);
    final c = AlphaController((_, __) async => null);
    c.apply(projection(
        fileName: 'shade-recovery-alice.json', packageAccount: 'alice'));
    await tester.pumpWidget(ShadeAlphaApp(controller: c));
    await tester.pumpAndSettle();
    await tester.enterText(field('Пароль восстановления'), phrase);
    await tester.enterText(
        field('Фраза устройства · от 16 символов'), devicePhrase);
    await tester.enterText(
        field('Повторите фразу устройства'), devicePhrase);
    final recoveryController =
        tester.widget<TextField>(field('Пароль восстановления')).controller!;
    final deviceController = tester
        .widget<TextField>(field('Фраза устройства · от 16 символов'))
        .controller!;
    c.apply(projection(step: 'done', packageAccount: 'alice'));
    await tester.pumpAndSettle();
    expect(recoveryController.text, '');
    expect(deviceController.text, '');
    c.dispose();
  });
}