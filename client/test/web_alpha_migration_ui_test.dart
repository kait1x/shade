// Проводка когортной миграции D1 в веб-UI (alpha-ui.mjs → Flutter-проекция).
// Покрыто: JS-проекция баннеров по состояниям диалога и честные HOLD-тексты
// (реальный alpha-ui.mjs исполняется node-харнесом с браузерными заглушками),
// рендер баннера в шапке чата существующим каналом connection/connected,
// blocked-статус HOLD-сообщения, регрессия обычного чата без миграции.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shade/features/web/presentation/alpha_app.dart';
import 'package:shade/features/web/presentation/alpha_controller.dart';

// Харнес исполняет РЕАЛЬНЫЙ alpha-ui.mjs в node: браузерные глобалы заменяются
// заглушками (boot честно завершается экраном ошибки, ключи не создаются),
// после чего вызываются экспортированные чистые функции проекции D1.
const _harness = r'''
const noop = () => {};
function fake() {
  const fn = function () { return fake(); };
  return new Proxy(fn, {
    get(t, p) {
      if (p === 'querySelectorAll') return () => [];
      if (p === Symbol.toPrimitive) return () => '';
      if (p === 'then') return undefined;
      return fake();
    },
    set() { return true; },
    apply() { return fake(); },
  });
}
globalThis.document = {
  querySelector: () => fake(), createElement: () => fake(), createElementNS: () => fake(),
  body: fake(), head: fake(), documentElement: fake(), addEventListener: noop, hidden: false,
};
globalThis.window = globalThis;
globalThis.window.addEventListener = noop;
globalThis.window.removeEventListener = noop;
globalThis.window.isSecureContext = false;
Object.defineProperty(globalThis, 'navigator', { value: { onLine: false, userAgent: 'node-harness' }, configurable: true });
globalThis.sessionStorage = { getItem: () => null, setItem: noop };
globalThis.location = { hash: '', pathname: '/', search: '', reload: noop, assign: noop };
const { pathToFileURL } = await import('node:url');
const ui = await import(pathToFileURL(process.cwd() + '/alpha-ui.mjs').href);
await new Promise(r => setTimeout(r, 100));
console.log(JSON.stringify({
  banners: {
    pending: ui.migrationBannerText({ state: 'migration_pending' }),
    transferring: ui.migrationBannerText({ state: 'transferring' }),
    v2: ui.migrationBannerText({ state: 'v2_active' }),
    rolledBack: ui.migrationBannerText({ state: 'v1_active', rolledBackAt: 123 }),
    aborted: ui.migrationBannerText({ state: 'v1_active', rolledBackAt: null }),
    none: ui.migrationBannerText(null),
  },
  errors: {
    migration_pending: ui.errors.migration_pending,
    migration_rolled_back: ui.errors.migration_rolled_back,
    peer_upgrade_required: ui.errors.peer_upgrade_required,
  },
  projection: {
    hold: ui.migrationBannerProjection({ peer: 'bob', account: 'alice', routing: { state: 'transferring' }, lastError: '', online: true }),
    offline: ui.migrationBannerProjection({ peer: 'bob', account: 'alice', routing: { state: 'transferring' }, lastError: '', online: false }),
    realError: ui.migrationBannerProjection({ peer: 'bob', account: 'alice', routing: { state: 'transferring' }, lastError: 'google_login_required', online: true }),
    holdError: ui.migrationBannerProjection({ peer: 'bob', account: 'alice', routing: { state: 'v1_active', rolledBackAt: 5 }, lastError: 'migration_rolled_back', online: true }),
    normal: ui.migrationBannerProjection({ peer: 'bob', account: 'alice', routing: { state: null }, lastError: '', online: true }),
    self: ui.migrationBannerProjection({ peer: 'alice', account: 'alice', routing: { state: 'v2_active' }, lastError: '', online: true }),
  },
}));
''';

void main() {
  void phone(WidgetTester tester) {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
  }

  // Проекция, которую alpha-ui.mjs отправляет в Flutter при активном баннере
  // миграции открытого диалога (канал connection/connected, без правок Flutter).
  Map<String, dynamic> projection({
    required String connection,
    required bool connected,
    String? routingState,
    int? rolledBackAt,
    List<Map<String, dynamic>> messages = const [],
  }) =>
      <String, dynamic>{
        'account': 'alice',
        'selected': 'bob',
        'connected': connected,
        'connection': connection,
        'peers': [
          {'account': 'bob', 'pinned': true}
        ],
        'messages': messages,
        if (routingState != null)
          'dialogRouting': {
            'bob': {
              'state': routingState,
              'revision': 3,
              'rolledBackAt': rolledBackAt,
            }
          },
      };

  const received = <String, dynamic>{
    'ref': 'r1',
    'from': 'bob',
    'to': 'alice',
    'text': 'Привет из v1',
    'createdAt': 1700000000000,
    'status': 'received',
    'devices': [],
  };

  test('JS-проекция D1: баннеры по состояниям, честные HOLD-тексты, приоритеты',
      () async {
    final result = await Process.run('node',
        ['--input-type=module', '-e', _harness],
        workingDirectory: 'web', stdoutEncoding: utf8, stderrEncoding: utf8);
    expect(result.exitCode, 0, reason: 'node-харнес alpha-ui.mjs: ${result.stderr}');
    final out = jsonDecode(result.stdout as String) as Map<String, dynamic>;
    final banners = out['banners'] as Map<String, dynamic>;
    expect(banners['pending'], 'Ожидание собеседника/устройств…');
    expect(banners['transferring'], 'Диалог переносится…');
    expect(banners['v2'], 'Диалог в Shade v2');
    expect(banners['rolledBack'], 'Диалог возвращён в v1');
    // Abort/обычный диалог без journal → баннера нет (регрессия обычного чата).
    expect(banners['aborted'], isNull);
    expect(banners['none'], isNull);
    final errors = out['errors'] as Map<String, dynamic>;
    expect(errors['migration_pending'],
        'Миграция диалога в Shade v2 не завершена. Сообщение сохранено в очереди и будет отправлено после переключения.');
    expect(errors['migration_rolled_back'],
        'Диалог возвращён в Shade v1. Сообщение сохранено в очереди; отправка из этого приложения (v2) недоступна — используйте Shade v1.');
    expect(errors['peer_upgrade_required'], contains('сохранено в очереди'));
    final projection = out['projection'] as Map<String, dynamic>;
    // HOLD-состояние: баннер замещает connection, connected=false (канал шапки).
    expect(projection['hold'],
        {'connection': 'Диалог переносится…', 'connected': false});
    // Реальная сеть/сессия честнее баннера; офлайн и обычный чат не меняются.
    expect(projection['offline'], isNull);
    expect(projection['realError'], isNull);
    expect(projection['normal'], isNull);
    expect(projection['self'], isNull);
    // HOLD-код 409 не перекрывает баннер состояния диалога.
    expect((projection['holdError'] as Map)['connection'], 'Диалог возвращён в v1');
  });

  testWidgets('Баннеры миграции в шапке чата по состояниям диалога',
      (tester) async {
    phone(tester);
    const cases = <String, String>{
      'migration_pending': 'Ожидание собеседника/устройств…',
      'transferring': 'Диалог переносится…',
      'v2_active': 'Диалог в Shade v2',
      'v1_active': 'Диалог возвращён в v1',
    };
    for (final entry in cases.entries) {
      final c = AlphaController((_, __) async => null);
      c.apply(projection(
        connection: entry.value,
        connected: false,
        routingState: entry.key,
        rolledBackAt: entry.key == 'v1_active' ? 1700000000000 : null,
        messages: [received],
      ));
      await tester.pumpWidget(ShadeAlphaApp(controller: c));
      await tester.pumpAndSettle();
      // Баннер виден в шапке чата (над лентой сообщений), текст честный.
      expect(find.text(entry.value), findsOneWidget, reason: entry.key);
      final bannerY = tester.getTopLeft(find.text(entry.value)).dy;
      final messageY = tester.getTopLeft(find.text('Привет из v1')).dy;
      expect(bannerY, lessThan(messageY));
      // Аддитивная проекция dialogRouting доходит до контроллера без потерь.
      final routing =
          (c.data['dialogRouting'] as Map)['bob'] as Map<String, dynamic>;
      expect(routing['state'], entry.key);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      c.dispose();
    }
  });

  testWidgets('HOLD: сообщение остаётся blocked с честным текстом ошибки',
      (tester) async {
    phone(tester);
    const holdText =
        'Миграция диалога в Shade v2 не завершена. Сообщение сохранено в очереди и будет отправлено после переключения.';
    final blocked = <String, dynamic>{
      'ref': 'r2',
      'from': 'alice',
      'to': 'bob',
      'text': 'Зависшее сообщение',
      'createdAt': 1700000000001,
      'status': 'blocked',
      'devices': [],
    };
    // Статус и подпись доставки заблокированного сообщения честные.
    expect(AlphaController.status(blocked), 'blocked');
    expect(AlphaController.delivery(blocked),
        'Отправка заблокирована · сохранено для проверки');
    final c = AlphaController((_, __) async => null);
    c.apply(projection(
      connection: holdText,
      connected: false,
      routingState: 'transferring',
      messages: [received, blocked],
    ));
    await tester.pumpWidget(ShadeAlphaApp(controller: c));
    await tester.pumpAndSettle();
    // HOLD-текст ошибки виден в шапке; сообщение не исчезло из ленты.
    expect(find.text(holdText), findsOneWidget);
    expect(find.text('Зависшее сообщение'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });

  testWidgets('Регрессия: обычный чат без миграции не показывает баннеры',
      (tester) async {
    phone(tester);
    final c = AlphaController((_, __) async => null);
    c.apply(projection(
      connection: 'Подключено · E2EE',
      connected: true,
      messages: [received],
    ));
    await tester.pumpWidget(ShadeAlphaApp(controller: c));
    await tester.pumpAndSettle();
    expect(find.text('Привет из v1'), findsOneWidget);
    expect(find.byKey(const Key('message-field')), findsOneWidget);
    for (final text in [
      'Ожидание собеседника/устройств…',
      'Диалог переносится…',
      'Диалог в Shade v2',
      'Диалог возвращён в v1',
    ]) {
      expect(find.text(text), findsNothing);
    }
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });
}