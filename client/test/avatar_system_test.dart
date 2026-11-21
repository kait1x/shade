import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:shade/core/database/database_service.dart';
import 'package:shade/core/services/connection_service.dart';
import 'package:shade/core/services/crypto_service.dart';
import 'package:shade/core/widgets/avatar_view.dart';
import 'package:shade/core/widgets/shade_ui.dart';
import 'package:shade/features/auth/data/repositories/auth_notifier.dart';
import 'package:shade/features/profile/data/avatar_repository.dart';
import 'package:shade/features/profile/presentation/avatar_crop.dart';
import 'package:shade/features/profile/presentation/screens/avatar_editor.dart';
import 'package:shade/features/profile/presentation/screens/profile_screen.dart';
import 'package:shade/main.dart';

class _Connection extends ConnectionService {
  _Connection()
      : super(
            serverUrl: 'https://localhost',
            cryptoService: CryptoService(),
            databaseService: DatabaseService());
  Map<String, dynamic> profile = {
    'displayName': 'Александр',
    'frame': 'none',
    'revision': 0,
    'image': null,
    'imageUrl': null
  };
  int writes = 0;
  Completer<Map<String, dynamic>>? nextGet;
  final updates = StreamController<String>.broadcast();
  @override
  Stream<String> get avatarUpdates => updates.stream;
  @override
  void dispose() {
    updates.close();
    super.dispose();
  }

  Completer<void>? gate;
  bool fail = false;
  @override
  Future<Map<String, dynamic>> profileRequest(String method, String path,
      [Map<String, dynamic>? data]) async {
    if (method == 'GET') {
      final pending = nextGet;
      nextGet = null;
      return pending == null ? Map.of(profile) : await pending.future;
    }
    writes++;
    await gate?.future;
    if (fail) throw StateError('Нет соединения');
    profile = {
      ...profile,
      ...data!,
      'revision': (profile['revision'] as int) + 1
    };
    return Map.of(profile);
  }
}

class _Auth extends AuthNotifier {
  _Auth(ConnectionService conn)
      : super(CryptoService(), DatabaseService(), conn) {
    state =
        const AuthState(status: AuthStatus.authenticated, nickname: 'alice');
  }
  @override
  Future<bool> checkExistingProfile() async => true;
}

Uint8List _photo() {
  final source = img.Image(width: 600, height: 400);
  img.fillRect(source,
      x1: 0, y1: 0, x2: 299, y2: 399, color: img.ColorRgb8(180, 60, 40));
  img.fillRect(source,
      x1: 300, y1: 0, x2: 599, y2: 399, color: img.ColorRgb8(30, 80, 150));
  return Uint8List.fromList(img.encodePng(source));
}

Future<void> _capture(WidgetTester tester, String name) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const ValueKey('capture')));
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 2);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    await Directory('../artifacts/avatars').create(recursive: true);
    await File('../artifacts/avatars/$name.png')
        .writeAsBytes(data!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  setUpAll(() async {
    await (FontLoader('Roboto')
          ..addFont(rootBundle.load('fonts/Roboto/Roboto-Regular.ttf'))
          ..addFont(rootBundle.load('fonts/Roboto/Roboto-Bold.ttf')))
        .load();
    await (FontLoader('MaterialIcons')
          ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf')))
        .load();
  });

  test(
      'crop clamps pan/zoom without empty edges and exports the selected pixels',
      () async {
    final crop = AvatarCrop(const Size(600, 400));
    expect(crop.rect, const Rect.fromLTWH(100, 0, 400, 400));
    crop.setZoom(2);
    crop.pan(const Offset(-10000, 10000), 240);
    expect(crop.rect, const Rect.fromLTWH(400, 0, 200, 200));
    crop.setZoom(100);
    expect(crop.zoom, 4);
    crop.setZoom(0);
    expect(crop.zoom, 1);
    final source = await decodeAvatarSource(_photo());
    final bytes =
        await exportAvatarCrop(source, const Rect.fromLTWH(400, 0, 200, 200));
    final result = img.decodeJpg(bytes)!;
    expect(result.width, 512);
    expect(result.height, 512);
    expect(result.getPixel(256, 256).b, greaterThan(140));
    expect(result.getPixel(256, 256).r, lessThan(40));
    expect(result.exif.isEmpty, isTrue);
    source.dispose();
    await expectLater(decodeAvatarSource(Uint8List(10 * 1024 * 1024 + 1)),
        throwsFormatException);
    await expectLater(
        decodeAvatarSource(Uint8List.fromList(utf8.encode('<svg/>'))),
        throwsFormatException);
  });

  test(
      'avatar cache migrates v7 without changing history and isolates owner/server',
      () async {
    sqfliteFfiInit();
    final dir = Directory('../artifacts/avatars/test-data');
    await dir.create(recursive: true);
    final file =
        '${dir.path}/migration-${DateTime.now().microsecondsSinceEpoch}.db';
    var db = await DatabaseService.openForTest(databaseFactoryFfi, file,
        schemaVersion: 7);
    addTearDown(() async {
      await db.close();
      if (await File(file).exists()) await File(file).delete();
    });
    await db.saveUserProfile('alice', 'unchanged-key');
    final chat = await db.createConversation('bob');
    await db.insertMessage(
        conversationId: chat,
        senderId: 2,
        encryptedContent: 'unchanged-ciphertext');
    await db.close();
    db = await DatabaseService.openForTest(databaseFactoryFfi, file);
    await db.cacheAvatarProfile('alice', 'https://one', 'bob',
        {'image': null, 'frame': 'silver', 'revision': 2});
    expect(
        (await db.readAvatarProfile('alice', 'https://one', 'bob'))!['frame'],
        'silver');
    expect(await db.readAvatarProfile('carol', 'https://one', 'bob'), isNull);
    expect(await db.readAvatarProfile('alice', 'https://two', 'bob'), isNull);
    expect((await db.getUserProfile('alice'))!['public_key'], 'unchanged-key');
    expect((await db.getMessages(chat)).single['encrypted_content'],
        'unchanged-ciphertext');
    await db.close();
  });

  test(
      'a slower pre-save response cannot restore an old avatar; failed save keeps committed data',
      () async {
    final conn = _Connection();
    final controller = AvatarController(conn, 'alice',
        readCache: (_) async => null, writeCache: (_, __) async {});
    await controller.load();
    final old = Map<String, dynamic>.of(conn.profile);
    final pending = Completer<Map<String, dynamic>>();
    conn.nextGet = pending;
    final slowLoad = controller.load();
    await controller.save(revision: 0, frame: AvatarFrame.silver);
    pending.complete(old);
    await slowLoad;
    expect(controller.state.valueOrNull!.frame, AvatarFrame.silver);
    conn.fail = true;
    await expectLater(controller.save(revision: 1, frame: AvatarFrame.graphite),
        throwsStateError);
    expect(controller.state.valueOrNull!.frame, AvatarFrame.silver);
    controller.dispose();
    conn.dispose();
  });

  Future<ProviderContainer> showEditor(WidgetTester tester, _Connection conn,
      {Size size = const Size(390, 844),
      double textScale = 1,
      Future<XFile?> Function()? picker}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    final container = ProviderContainer(overrides: [
      connectionServiceProvider.overrideWithValue(conn),
      authNotifierProvider.overrideWith((_) => _Auth(conn))
    ]);
    addTearDown(() {
      container.dispose();
      conn.dispose();
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: RepaintBoundary(
            key: const ValueKey('capture'),
            child: MaterialApp(
                debugShowCheckedModeBanner: false,
                theme: buildShadeTheme(),
                builder: (context, child) => MediaQuery(
                    data: MediaQuery.of(context)
                        .copyWith(textScaler: TextScaler.linear(textScale)),
                    child: child!),
                home: Scaffold(
                    body: Builder(
                        builder: (context) => TextButton(
                            onPressed: () => Navigator.push(
                                context,
                                MaterialPageRoute(
                                    builder: (_) => AvatarEditor(
                                        username: 'alice',
                                        initial: AvatarProfile.fromJson(
                                            conn.profile),
                                        pickImage: picker))),
                            child: const Text('Открыть'))))))));
    await tester.tap(find.text('Открыть'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 80));
    });
    await tester.pumpAndSettle();
    return container;
  }

  testWidgets(
      'frames cancel without writes and editor fits narrow screens with large text',
      (tester) async {
    final conn = _Connection();
    await showEditor(tester, conn, size: const Size(320, 640), textScale: 1.8);
    await tester.ensureVisible(find.text('Graphite'));
    await tester.tap(find.text('Graphite'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(find.byTooltip('Закрыть'));
    await tester.pumpAndSettle();
    expect(find.text('Отменить изменения?'), findsOneWidget);
    await tester.tap(find.text('Не сохранять'));
    await tester.pumpAndSettle();
    expect(find.text('Открыть'), findsOneWidget);
    expect(conn.writes, 0);
    await tester.pumpWidget(const SizedBox());
  });

  for (final reducedMotion in [false, true]) {
    testWidgets(
        'profile avatar opens and returns safely; reduced motion $reducedMotion',
        (tester) async {
      final conn = _Connection();
      final container = ProviderContainer(overrides: [
        connectionServiceProvider.overrideWithValue(conn),
        authNotifierProvider.overrideWith((ref) => _Auth(conn)),
      ]);
      addTearDown(() {
        container.dispose();
        conn.dispose();
      });
      await tester.pumpWidget(UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
              theme: buildShadeTheme(),
              builder: (_, child) => MediaQuery(
                  data: MediaQueryData(disableAnimations: reducedMotion),
                  child: child!),
              home: const ProfileScreen(username: 'alice', isSelf: true))));
      await tester.pumpAndSettle();
      expect(find.text('Имя'), findsOneWidget);
      // The avatar itself is the single entry point to its editor.
      expect(find.text('Аватар'), findsNothing);
      await tester.tap(find.byTooltip('Изменить аватар'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.takeException(), isNull);
      await tester.pumpAndSettle();
      expect(find.byType(AvatarEditor), findsOneWidget);
      final hero = find.byWidgetPredicate(
          (w) => w is Hero && w.tag == 'profile-avatar-alice');
      expect(hero, findsOneWidget);
      final mode = tester.widget<HeroMode>(
          find.ancestor(of: hero, matching: find.byType(HeroMode)).first);
      expect(mode.enabled, !reducedMotion);
      await tester.tap(find.byTooltip('Закрыть'));
      await tester.pumpAndSettle();
      expect(find.byType(AvatarEditor), findsNothing);
      expect(find.byType(ProfileScreen), findsOneWidget);
      expect(conn.writes, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets(
      'saving disables duplicate actions, preserves draft after failure and updates shared avatars',
      (tester) async {
    final conn = _Connection();
    final container = await showEditor(tester, conn);
    await tester.ensureVisible(find.text('Silver'));
    await tester.tap(find.text('Silver'));
    await tester.pumpAndSettle();
    conn.fail = true;
    conn.gate = Completer<void>();
    await tester.tap(find.text('Сохранить'));
    await tester.pump();
    expect(find.text('Сохраняем…'), findsOneWidget);
    expect(
        tester
            .widget<IconButton>(find
                .ancestor(
                    of: find.byTooltip('Закрыть'),
                    matching: find.byType(IconButton))
                .first)
            .onPressed,
        isNull);
    conn.gate!.complete();
    await tester.pumpAndSettle();
    expect(conn.writes, 1);
    expect(find.textContaining('Не удалось сохранить.'), findsOneWidget);
    conn.fail = false;
    conn.gate = null;
    await tester.tap(find.text('Сохранить'));
    await tester.pumpAndSettle();
    expect(conn.writes, 2);
    expect(find.text('Открыть'), findsOneWidget);
    expect(conn.profile['frame'], 'silver');
    await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
            home: Scaffold(
                body: Row(children: [
          ShadeAvatar(name: 'alice', username: 'alice', size: 40),
          ShadeAvatar(name: 'alice', username: 'alice', size: 96)
        ])))));
    await tester.pumpAndSettle();
    expect(
        tester
            .widgetList<AvatarView>(find.byType(AvatarView))
            .every((a) => a.frame == AvatarFrame.silver),
        isTrue);
    expect(tester.takeException(), isNull);
    conn.profile = {...conn.profile, 'frame': 'graphite'};
    conn.updates.add('alice');
    await tester.pumpAndSettle();
    expect(
        tester
            .widgetList<AvatarView>(find.byType(AvatarView))
            .every((a) => a.frame == AvatarFrame.graphite),
        isTrue);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('gallery cancel and unsupported file keep the current avatar',
      (tester) async {
    final conn = _Connection();
    int picks = 0;
    await showEditor(tester, conn,
        picker: () async => picks++ == 0
            ? null
            : XFile.fromData(Uint8List.fromList([1, 2, 3]), name: 'bad.jpg'));
    await tester.tap(find.text('Выбрать фото'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('avatar-crop')), findsNothing);
    expect(conn.writes, 0);
    await tester.tap(find.text('Выбрать фото'));
    await tester.pumpAndSettle();
    expect(find.text('Поддерживаются JPEG, PNG и WebP'), findsOneWidget);
    expect(conn.writes, 0);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'photo deletion saves explicit null and preserves independent frame',
      (tester) async {
    final conn = _Connection();
    conn.profile = {
      ...conn.profile,
      'image': base64Encode(_photo()),
      'frame': 'graphite'
    };
    await showEditor(tester, conn);
    await tester.ensureVisible(find.text('Удалить фото'));
    await tester.tap(find.text('Удалить фото'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Сохранить'));
    await tester.pumpAndSettle();
    expect(conn.profile['image'], isNull);
    expect(conn.profile['frame'], 'graphite');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'renders editor and live crop at phone/tablet sizes; gallery crop is uploaded',
      (tester) async {
    final conn = _Connection();
    await showEditor(tester, conn,
        picker: () async => XFile.fromData(_photo(), name: 'crop-fixture.png'));
    await _capture(tester, 'editor-phone');
    await tester.runAsync(() async {
      await tester.tap(find.text('Выбрать фото'));
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('avatar-crop')), findsOneWidget);
    await tester.drag(
        find.byKey(const ValueKey('avatar-crop')), const Offset(-40, 0));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Предпросмотр'));
    await tester.tap(find.text('Предпросмотр'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Ваш образ в Shade'), -300,
        scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
    await _capture(tester, 'crop-phone');
    tester.view.physicalSize = const Size(900, 700);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await _capture(tester, 'editor-tablet');
    await tester.runAsync(() async {
      await tester.tap(find.text('Сохранить'));
      await Future<void>.delayed(const Duration(milliseconds: 700));
    });
    await tester.pumpAndSettle();
    expect(conn.writes, 1);
    expect(conn.profile['image'], isA<String>());
    final image = img.decodeJpg(base64Decode(conn.profile['image']))!;
    expect(image.width, 512);
    expect(image.height, 512);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'unicode initials, remote failure and corrupt local bytes fall back cleanly',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: Row(children: [
      const AvatarView(
          name: ' 👩🏽‍💻 Designer',
          size: 24,
          frame: AvatarFrame.silver,
          online: true),
      AvatarView(name: 'Борис', image: Uint8List.fromList([0, 1, 2]), size: 52),
      const AvatarView(
          name: 'Clara', imageUrl: 'https://example.invalid/missing', size: 96),
    ]))));
    await tester.pumpAndSettle();
    expect(find.text('👩🏽‍💻'), findsOneWidget);
    expect(find.text('Б'), findsOneWidget);
    expect(find.text('C'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
