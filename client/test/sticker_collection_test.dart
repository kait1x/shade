import 'dart:io';
import 'package:flutter/services.dart';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shade/core/database/database_service.dart';
import 'package:shade/core/services/connection_service.dart';
import 'package:shade/core/services/crypto_service.dart';
import 'package:shade/features/stickers/collection.dart';
import 'package:shade/features/stickers/connection_stickers.dart';
import 'package:shade/features/stickers/vinyl.dart';
import 'package:shade/main.dart';

class _Fixture extends ConnectionService {
  _Fixture()
      : super(
            serverUrl: 'https://localhost',
            cryptoService: CryptoService(),
            databaseService: DatabaseService());
  List<dynamic> wall = [];
  bool fail = false;
  int revision = 0;
  String? sent;
  @override
  Future<Map<String, dynamic>> profileRequest(String method, String path,
      [Map<String, dynamic>? data]) async {
    if (fail) throw StateError('Тестовая ошибка записи');
    if (method == 'PUT') {
      wall = data!['wall'];
      revision++;
    }
    if (method == 'POST') sent = data!['stickerId'];
    return {
      'revision': revision,
      'wall': wall,
      'inventory': [
        for (final (i, id)
            in ['flowers', 'moth', 'flowers', 'comet', 'ghost'].indexed)
          {
            'giftId': 'g$i',
            'stickerId': id,
            'fromUsername': 'alex',
            'note': 'До звёзд!'
          }
      ]
    };
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await (FontLoader('Roboto')
          ..addFont(rootBundle.load('fonts/Roboto/Roboto-Regular.ttf'))
          ..addFont(rootBundle.load('fonts/Roboto/Roboto-Bold.ttf')))
        .load();
    await (FontLoader('MaterialIcons')
          ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf')))
        .load();
  });
  testWidgets(
      'wall draft survives error, owner gestures, duplicate book pages, private peel and gift dialog',
      (t) async {
    t.view.physicalSize = const Size(390, 780);
    t.view.devicePixelRatio = 1;
    final service = _Fixture();
    addTearDown(() {
      t.view.resetPhysicalSize();
      t.view.resetDevicePixelRatio();
      service.dispose();
    });
    const boundary = ValueKey('stage');
    Future<void> show(bool owner) async {
      await t.pumpWidget(RepaintBoundary(
          key: boundary,
          child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: buildShadeTheme(),
              home: Scaffold(
                  body: SafeArea(
                      child: SingleChildScrollView(
                          padding: const EdgeInsets.all(16),
                          child: StickerCollection(
                              key: ValueKey(owner),
                              username: owner ? 'owner' : 'alex',
                              owner: owner,
                              backend: StickerRepository(service),
                              reloadStream: service.connectionChanges)))))));
      await t.pumpAndSettle();
    }

    Future<void> capture(String name) async {
      final render =
          t.renderObject<RenderRepaintBoundary>(find.byKey(boundary));
      await t.runAsync(() async {
        final image = await render.toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final f = File('../artifacts/stickers/$name.png');
        await f.parent.create(recursive: true);
        await f.writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
      expect(t.takeException(), isNull);
    }

    int frame = 0;
    Future<void> record() async {
      await t.pump(const Duration(milliseconds: 70));
      await capture('frames/frame${(frame++).toString().padLeft(3, '0')}');
    }

    await show(true);
    await capture('empty');
    await t.tap(find.text('Оформить'));
    await t.pumpAndSettle();
    final tray = find.byType(SingleChildScrollView).last;
    await t
        .tap(find.descendant(of: tray, matching: find.byType(InkWell)).first);
    await t.pumpAndSettle();
    final placed = find.byKey(const ValueKey('g0'));
    expect(placed, findsOneWidget);
    final drag = await t.startGesture(t.getCenter(placed));
    for (var i = 0; i < 12; i++) {
      await drag.moveBy(const Offset(5, -2));
      await record();
    }
    await drag.up();
    await t.pumpAndSettle();
    await capture('edit');
    service.fail = true;
    await t.tap(find.text('Готово'));
    await t.pumpAndSettle();
    expect(find.textContaining('Тестовая ошибка'), findsOneWidget);
    expect(placed, findsOneWidget);
    service.fail = false;
    await t.tap(find.text('Готово'));
    await t.pumpAndSettle();
    expect(service.wall.single['xNorm'], greaterThan(.5));
    await capture('wall');
    await t.tap(find.text('Книжка'));
    await t.pumpAndSettle();
    expect(find.text('×2'), findsOneWidget);
    await capture('book');
    await t.drag(find.byType(PageView), const Offset(-300, 0));
    await t.pumpAndSettle();
    expect(find.text('2 / 2'), findsOneWidget);
    await t.tap(find.text('Стена'));
    await t.pumpAndSettle();
    await t.tapAt(t.getCenter(placed));
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
    expect(find.byType(VinylViewer), findsOneWidget);
    final viewer = find.descendant(
        of: find.byType(VinylViewer),
        matching: find.byWidgetPredicate(
            (w) => w is GestureDetector && w.onPanDown != null));
    final box = t.getRect(viewer);
    final tilt = await t.startGesture(box.center);
    for (var i = 0; i < 10; i++) {
      await tilt.moveBy(const Offset(5, 2));
      await record();
    }
    await capture('holo');
    await tilt.up();
    await t.pump();
    await t.pump(const Duration(seconds: 1));
    final peel = await t.startGesture(Offset(box.left + 3, box.center.dy));
    for (var i = 0; i < 20; i++) {
      await peel.moveBy(const Offset(9, 0));
      await record();
    }
    final painter = t
        .widgetList<CustomPaint>(
            find.descendant(of: viewer, matching: find.byType(CustomPaint)))
        .firstWhere((w) => w.foregroundPainter != null)
        .foregroundPainter as dynamic;
    expect(painter.peel, greaterThan(.45));
    expect(painter.back, isNotNull);
    await capture('peel');
    await peel.up();
    for (var i = 0; i < 12; i++) {
      await record();
    }
    expect(find.text('Лицевая сторона'), findsOneWidget);
    await capture('detached-front');
    await t.tap(find.text('Перевернуть'));
    for (var i = 0; i < 12; i++) {
      await record();
    }
    expect(find.text('Обратная сторона'), findsOneWidget);
    await capture('detached-back');
    final heldDrag = await t.startGesture(box.center);
    for (var i = 0; i < 8; i++) {
      await heldDrag.moveBy(const Offset(3, 2));
      await record();
    }
    await heldDrag.up();
    await t.tap(find.text('Приклеить обратно'));
    for (var i = 0; i < 20; i++) {
      await record();
    }
    await t.pumpAndSettle();
    expect(find.text('Отклеить'), findsOneWidget);
    expect(service.wall.single['giftId'], 'g0');
    expect(service.revision, 1,
        reason: 'Inspection must not save or modify the wall');
    await capture('reattached');
    await t.tap(find.byType(CloseButton));
    await t.pumpAndSettle();
    await show(false);
    expect(find.text('Оформить'), findsNothing);
    await t.tap(find.text('Подарить'));
    await t.pumpAndSettle();
    await t.tap(find.text('Лунный мотылёк'));
    await t.enterText(find.byType(TextField), 'До звёзд!');
    await t.pumpAndSettle();
    await capture('gift');
    await t.tap(find.widgetWithText(FilledButton, 'Подарить'));
    await t.pumpAndSettle();
    expect(service.sent, 'moth');
    service.wall = [
      for (var i = 0; i < 5; i++)
        {
          'giftId': 'g$i',
          'xNorm': [.13, .5, .84, .3, .72][i],
          'yNorm': [.16, .12, .32, .76, .78][i],
          'rotation': [-.15, .09, .2, -.12, .13][i],
          'scale': [1.25, 1.15, 1.1, 1.2, 1.15][i],
          'zIndex': i
        }
    ];
    await show(true);
    await t.pump(const Duration(seconds: 5));
    await t.pumpAndSettle();
    await capture('wall-collection');
    await t.tap(find.text('Оформить'));
    await t.pumpAndSettle();
    await capture('edit-collection');
  });
}
