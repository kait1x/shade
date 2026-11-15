import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shade/core/database/database_service.dart';
import 'package:shade/core/services/connection_service.dart';
import 'package:shade/core/services/crypto_service.dart';
import 'package:shade/features/profile/presentation/screens/profile_screen.dart';
import 'package:shade/main.dart';

import 'package:shade/features/auth/data/repositories/auth_notifier.dart';

class _TestTrust extends DatabaseService {
  final keys = <String, String>{};
  @override
  Future<bool> checkFingerprint(
      String owner, String peer, String fingerprint, String? legacy) async {
    final k = '$owner:$peer';
    if (keys[k] != fingerprint) keys.remove(k);
    return keys[k] == fingerprint;
  }

  @override
  Future<void> confirmFingerprint(
      String owner, String peer, String fingerprint) async {
    keys['$owner:$peer'] = fingerprint;
  }
}

late _TestTrust _trust;

// Real widgets with presentation fixtures; not live profiles or key verification.
class _PreviewConnection extends ConnectionService {
  _PreviewConnection()
      : super(
            serverUrl: 'https://localhost:3443',
            cryptoService: CryptoService(),
            databaseService: DatabaseService());
  @override
  Future<Map<String, dynamic>> profileRequest(String method, String path,
          [Map<String, dynamic>? data]) async =>
      {'revision': 0, 'inventory': [], 'wall': []};
  @override
  Future<UserStatus?> getUserStatus(String username) async =>
      const UserStatus(online: true, lastSeen: 0);
}

class _CollectionPreview extends _PreviewConnection {
  @override
  Future<Map<String, dynamic>> profileRequest(String method, String path,
          [Map<String, dynamic>? data]) async =>
      {
        'revision': 1,
        'inventory': [
          for (final (i, id)
              in ['flowers', 'moth', 'flowers', 'comet', 'ghost'].indexed)
            {'giftId': 'g$i', 'stickerId': id}
        ],
        'wall': [
          for (var i = 0; i < 5; i++)
            {
              'giftId': 'g$i',
              'xNorm': [.13, .5, .84, .3, .72][i],
              'yNorm': [.16, .12, .32, .76, .78][i],
              'rotation': [-.15, .09, .2, -.12, .13][i],
              'scale': 1.2,
              'zIndex': i
            }
        ]
      };
}

const _peer = ProfileScreen(
    username: 'alex',
    viewerUsername: 'kait1x',
    publicKey: 'preview-peer-public-key');
ProfileScreen _self() => ProfileScreen(
    username: 'kait1x',
    displayName: 'Kait1x',
    email: 'demo@shade.example',
    publicKey: 'preview-owner-public-key',
    isSelf: true,
    onSignOut: () {});

Widget _phone(String label, Widget screen, GlobalKey<NavigatorState> key) =>
    Column(mainAxisSize: MainAxisSize.min, children: [
      Text(label,
          style: const TextStyle(
              color: Color(0xFF373737),
              fontSize: 15,
              fontWeight: FontWeight.w600)),
      const SizedBox(height: 12),
      Container(
          width: 390,
          height: 844,
          padding: const EdgeInsets.all(9),
          decoration: BoxDecoration(
              color: Colors.black,
              borderRadius: BorderRadius.circular(46),
              boxShadow: [
                BoxShadow(
                    color: Colors.black.withValues(alpha: .25),
                    blurRadius: 26,
                    offset: const Offset(0, 18))
              ]),
          child: ClipRRect(
              borderRadius: BorderRadius.circular(37),
              child: ColoredBox(
                  color: ShadeColors.black,
                  child: Column(children: [
                    const SizedBox(
                        height: 30,
                        child: Padding(
                            padding: EdgeInsets.symmetric(horizontal: 25),
                            child: Row(children: [
                              Text('18:04',
                                  style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600)),
                              Spacer(),
                              Icon(Icons.signal_cellular_alt, size: 17),
                              SizedBox(width: 5),
                              Icon(Icons.battery_full_rounded, size: 18)
                            ]))),
                    Expanded(
                        child: MediaQuery(
                            data: const MediaQueryData(size: Size(372, 796)),
                            child: ScaffoldMessenger(
                                child: Navigator(
                                    key: key,
                                    onGenerateRoute: (_) =>
                                        MaterialPageRoute<void>(
                                            builder: (_) => screen))))),
                  ])))),
    ]);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => _trust = _TestTrust());
  setUpAll(() async {
    final fonts = FontLoader('Roboto')
      ..addFont(rootBundle.load('fonts/Roboto/Roboto-Regular.ttf'))
      ..addFont(rootBundle.load('fonts/Roboto/Roboto-Bold.ttf'));
    await fonts.load();
    await (FontLoader('MaterialIcons')
          ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf')))
        .load();
  });
  setUp(() => SharedPreferences.setMockInitialValues(
      {'contact_note_alex': 'Сокомандник по хакатону, отвечает за сервер'}));

  Future<void> withShadows(
      WidgetTester tester, Future<void> Function(WidgetTester) body) async {
    final previous = debugDisableShadows;
    debugDisableShadows = false;
    try {
      await body(tester);
    } finally {
      debugDisableShadows = previous;
    }
  }

  Future<void> capture(WidgetTester tester, Key key, String name,
      {double ratio = 1}) async {
    expect(tester.takeException(), isNull);
    final render = tester.renderObject<RenderRepaintBoundary>(find.byKey(key));
    await tester.runAsync(() async {
      final image = await render.toImage(pixelRatio: ratio);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      await File('../artifacts/ui/$name.png')
          .writeAsBytes(data!.buffer.asUint8List());
      image.dispose();
    });
  }

  testWidgets('full profiles with populated sticker walls', (tester) async {
    tester.view.physicalSize = const Size(390, 1320);
    tester.view.devicePixelRatio = 1;
    final conn = _CollectionPreview();
    final mono = File('C:/Windows/Fonts/consola.ttf');
    if (mono.existsSync()) {
      await (FontLoader('monospace')
            ..addFont(
                Future.value(ByteData.sublistView(mono.readAsBytesSync()))))
          .load();
    }
    for (final self in [true, false]) {
      final key = ValueKey(self);
      await tester.pumpWidget(ProviderScope(
          overrides: [
            databaseServiceProvider.overrideWithValue(_trust),
            connectionServiceProvider.overrideWithValue(conn)
          ],
          child: RepaintBoundary(
              key: key,
              child: MaterialApp(
                  debugShowCheckedModeBanner: false,
                  theme: buildShadeTheme(),
                  home: self ? _self() : _peer))));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pumpAndSettle();
      await capture(
          tester, key, self ? 'full-self-stickers' : 'full-peer-stickers',
          ratio: 2);
      await tester.pumpWidget(const SizedBox.shrink());
    }
    conn.dispose();
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  testWidgets(
      'profile showcase renders actual self, contact and key sheet',
      (tester) => withShadows(tester, (tester) async {
            tester.view.physicalSize = const Size(1380, 980);
            tester.view.devicePixelRatio = 1;
            final connection = _PreviewConnection();
            final ownNav = GlobalKey<NavigatorState>(),
                peerNav = GlobalKey<NavigatorState>(),
                keyNav = GlobalKey<NavigatorState>();
            const boundary = Key('profile-showcase');
            await tester.pumpWidget(ProviderScope(
                overrides: [
                  databaseServiceProvider.overrideWithValue(_trust),
                  connectionServiceProvider.overrideWithValue(connection)
                ],
                child: RepaintBoundary(
                    key: boundary,
                    child: MaterialApp(
                        debugShowCheckedModeBanner: false,
                        theme: buildShadeTheme(),
                        home: Scaffold(
                            backgroundColor: const Color(0xFFEAEAEA),
                            body: Center(
                                child: Row(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                  _phone('Мой профиль', _self(), ownNav),
                                  const SizedBox(width: 36),
                                  _phone('Профиль собеседника', _peer, peerNav),
                                  const SizedBox(width: 36),
                                  _phone('Сверка ключа', _peer, keyNav),
                                ])))))));
            await tester.pumpAndSettle();
            final keyButton = find.descendant(
                of: find.byKey(keyNav), matching: find.text('Ключ'));
            await tester.tap(keyButton);
            await tester.pumpAndSettle();
            await capture(tester, boundary, 'profile-showcase');
            await tester.pumpWidget(const SizedBox.shrink());
            connection.dispose();
            tester.view.resetPhysicalSize();
            tester.view.resetDevicePixelRatio();
          }),
      variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets(
      'capture self profile and confirm a contact only for the current key',
      (tester) => withShadows(tester, (tester) async {
            tester.view.physicalSize = const Size(390, 844);
            tester.view.devicePixelRatio = 1;
            final connection = _PreviewConnection();
            const boundary = Key('profile-single');
            Future<void> show(Widget screen) async {
              await tester.pumpWidget(ProviderScope(
                  overrides: [
                    databaseServiceProvider.overrideWithValue(_trust),
                    connectionServiceProvider.overrideWithValue(connection)
                  ],
                  child: RepaintBoundary(
                      key: boundary,
                      child: MaterialApp(
                          debugShowCheckedModeBanner: false,
                          theme: buildShadeTheme(),
                          home: screen))));
              await tester.pumpAndSettle();
            }

            await show(_self());
            await capture(tester, boundary, 'profile', ratio: 2);
            await show(_peer);
            expect(find.text('Не сверен'), findsOneWidget);
            await capture(tester, boundary, 'sticker-peer');
            await tester.tap(find.text('Ключ'));
            await tester.pumpAndSettle();
            await capture(tester, boundary, 'sticker-verification');
            expect(find.text('Ключ совпадает'), findsOneWidget);
            await tester.tap(find.text('Ключ совпадает'));
            await tester.pumpAndSettle();
            expect(find.text('Сверен'), findsOneWidget);
            final prefs = await SharedPreferences.getInstance();
            expect(prefs.getString('verified_key:kait1x:alex'), isNull);
            expect(_trust.keys['kait1x:alex'], isNotEmpty);
            await show(const ProfileScreen(
                username: 'alex',
                viewerUsername: 'kait1x',
                publicKey: 'changed-peer-key'));
            expect(find.text('Не сверен'), findsOneWidget);
            await show(_peer);
            expect(find.text('Не сверен'), findsOneWidget);
            await show(const ProfileScreen(
                username: 'alex',
                viewerUsername: 'another_user',
                publicKey: 'preview-peer-public-key'));
            expect(find.text('Не сверен'), findsOneWidget);
            expect(tester.takeException(), isNull);
            await tester.pumpWidget(const SizedBox.shrink());
            connection.dispose();
            tester.view.resetPhysicalSize();
            tester.view.resetDevicePixelRatio();
          }),
      variant: TargetPlatformVariant.only(TargetPlatform.android));
  testWidgets(
      'profile and key sheet fit narrow screens with large text',
      (tester) => withShadows(tester, (tester) async {
            tester.view.physicalSize = const Size(320, 640);
            tester.view.devicePixelRatio = 1;
            final connection = _PreviewConnection();
            await tester.pumpWidget(ProviderScope(
                overrides: [
                  databaseServiceProvider.overrideWithValue(_trust),
                  connectionServiceProvider.overrideWithValue(connection)
                ],
                child: MaterialApp(
                    theme: buildShadeTheme(),
                    builder: (context, child) => MediaQuery(
                        data: MediaQuery.of(context)
                            .copyWith(textScaler: const TextScaler.linear(1.4)),
                        child: child!),
                    home: _peer)));
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
            await tester.tap(find.text('Ключ'));
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
            await tester.ensureVisible(find.text('Ключ совпадает'));
            await tester.pumpAndSettle();
            await tester.tap(find.text('Ключ совпадает'));
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
            await tester.pumpWidget(const SizedBox.shrink());
            connection.dispose();
            tester.view.resetPhysicalSize();
            tester.view.resetDevicePixelRatio();
          }),
      variant: TargetPlatformVariant.only(TargetPlatform.android));
  testWidgets(
      'a key changed while its sheet is open cannot be confirmed accidentally',
      (tester) => withShadows(tester, (tester) async {
            tester.view.physicalSize = const Size(390, 844);
            tester.view.devicePixelRatio = 1;
            final connection = _PreviewConnection();
            final key = ValueNotifier('original-peer-key');
            await tester.pumpWidget(ProviderScope(
                overrides: [
                  databaseServiceProvider.overrideWithValue(_trust),
                  connectionServiceProvider.overrideWithValue(connection)
                ],
                child: MaterialApp(
                    theme: buildShadeTheme(),
                    home: ValueListenableBuilder<String>(
                        valueListenable: key,
                        builder: (_, value, __) => ProfileScreen(
                            username: 'alex',
                            viewerUsername: 'kait1x',
                            publicKey: value)))));
            await tester.pumpAndSettle();
            await tester.tap(find.text('Ключ'));
            await tester.pumpAndSettle();
            key.value = 'replacement-peer-key';
            await tester.pumpAndSettle();
            await tester.tap(find.text('Ключ совпадает'));
            await tester.pumpAndSettle();
            expect(find.text('Не сверен'), findsOneWidget);
            expect(
                (await SharedPreferences.getInstance())
                    .getString('verified_key:kait1x:alex'),
                isNull);
            expect(tester.takeException(), isNull);
            await tester.pumpWidget(const SizedBox.shrink());
            key.dispose();
            connection.dispose();
            tester.view.resetPhysicalSize();
            tester.view.resetDevicePixelRatio();
          }),
      variant: TargetPlatformVariant.only(TargetPlatform.android));
}
