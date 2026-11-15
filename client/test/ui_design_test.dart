import 'dart:async';
import 'package:go_router/go_router.dart';
import 'package:shade/features/profile/presentation/screens/profile_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications_platform_interface/flutter_local_notifications_platform_interface.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shade/main.dart';
import 'package:shade/core/database/database_service.dart';
import 'package:shade/core/services/crypto_service.dart';
import 'package:shade/core/services/connection_service.dart';
import 'package:shade/features/auth/data/repositories/auth_notifier.dart';
import 'package:shade/features/auth/presentation/screens/welcome_screen.dart';
import 'package:shade/features/home/presentation/screens/home_screen.dart';
import 'package:shade/features/home/presentation/screens/user_search_screen.dart';
import 'package:shade/features/home/presentation/widgets/chat_list_view.dart';
import 'package:shade/features/chats/data/repositories/chat_repository.dart';
import 'package:shade/features/chats/presentation/screens/chat_screen.dart';
import 'package:shade/features/chats/presentation/widgets/message_input.dart';

// Presentation fixtures only. These images are not evidence of a live chat or
// Google login; network/crypto behavior has its own integration tests.
class _UiNotifications extends FlutterLocalNotificationsPlatform {
  @override
  Future<void> cancelAll() async {}
  @override
  Future<void> cancel(int id) async {}
}

final _db = DatabaseService();
final _crypto = CryptoService();

class _UiConnection extends ConnectionService {
  final fixtureNotifications = StreamController<IncomingMessage>.broadcast();
  @override
  Stream<IncomingMessage> get notifications => fixtureNotifications.stream;
  @override
  void dispose() {
    fixtureNotifications.close();
    super.dispose();
  }

  _UiConnection()
      : super(
            serverUrl: 'https://localhost:3443',
            cryptoService: _crypto,
            databaseService: _db);
  @override
  Future<PublicKeyBundle?> getPublicKey(String name) async => null;
  @override
  void watchUser(String username) {}
  @override
  void unwatchUser(String username) {}
  @override
  Future<UserStatus?> getUserStatus(String username) async => null;
}

class _UiAuth extends AuthNotifier {
  _UiAuth(ConnectionService connection, {bool welcome = false})
      : super(_crypto, _db, connection) {
    state = welcome
        ? const AuthState(status: AuthStatus.error)
        : const AuthState(
            status: AuthStatus.authenticated,
            nickname: 'kait1x',
            displayName: 'Kait1x',
            publicKey: 'fixture-key');
  }
  @override
  Future<bool> checkExistingProfile() async => true;
}

List<Conversation> _chats() {
  final now = DateTime.now();
  const names = ['anya', 'danya', 'masha', 'Избранное'];
  const previews = [
    'Тогда до встречи у входа',
    'Фото получились отличные!',
    'Презентация почти готова',
    'Идеи для следующей встречи'
  ];
  return List.generate(
      names.length,
      (i) => Conversation(
          id: i + 1,
          name: names[i],
          publicKey: 'fixture-key',
          createdAt: now,
          lastMessage: Message(
              id: i + 1,
              conversationId: i + 1,
              senderId: 1,
              encryptedContent: previews[i],
              timestamp: now.subtract(Duration(minutes: i * 23 + 2)))));
}

class _UiRepository extends ChatRepository {
  _UiRepository() : super(_db, _crypto);
  @override
  Future<List<Message>> getMessages(int conversationId,
          {int limit = 20, int offset = 0}) async =>
      [];
  @override
  Future<List<DecryptedMessage>> decryptMessages(List<Message> messages,
      {required int mySenderId}) async {
    final now = DateTime.now();
    const texts = [
      'Привет! Как там наш проект?',
      'Уже можно показывать. Осталось выбрать фото для презентации.',
      'Класс! Давай встретимся завтра и прогоним всё вместе?',
      'Давай в 16:00? Я принесу ноутбук.',
      'Отлично. Тогда до встречи у входа'
    ];
    return List.generate(
        texts.length,
        (i) => DecryptedMessage(
            id: i + 1,
            text: texts[i],
            timestamp: now.subtract(Duration(minutes: 12 - i * 2)),
            isMine: i == 1 || i == 3,
            status: 'read'));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    FlutterLocalNotificationsPlatform.instance = _UiNotifications();
    final fonts = FontLoader('Roboto')
      ..addFont(rootBundle.load('fonts/Roboto/Roboto-Regular.ttf'))
      ..addFont(rootBundle.load('fonts/Roboto/Roboto-Bold.ttf'));
    await fonts.load();
    await (FontLoader('MaterialIcons')
          ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf')))
        .load();
  });
  const boundary = Key('ui-capture');
  Future<void> pump(WidgetTester tester, Widget screen,
      {bool welcome = false,
      double width = 390,
      double height = 844,
      double scale = 1}) async {
    tester.view.physicalSize = Size(width, height);
    tester.view.devicePixelRatio = 1;
    final connection = _UiConnection();
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('dexterous.com/flutter/local_notifications'),
        (_) async => null);
    await tester.pumpWidget(ProviderScope(
        overrides: [
          authNotifierProvider
              .overrideWith((ref) => _UiAuth(connection, welcome: welcome)),
          connectionServiceProvider.overrideWithValue(connection),
          chatRepositoryProvider.overrideWithValue(_UiRepository()),
          conversationsProvider.overrideWith((ref) async => _chats()),
        ],
        child: RepaintBoundary(
            key: boundary,
            child: MaterialApp(
                debugShowCheckedModeBanner: false,
                theme: buildShadeTheme(),
                builder: (context, child) => MediaQuery(
                    data: MediaQuery.of(context)
                        .copyWith(textScaler: TextScaler.linear(scale)),
                    child: child!),
                home: screen))));
    await tester.pumpAndSettle();
    addTearDown(() {
      connection.dispose();
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
  }

  Future<void> capture(WidgetTester tester, String name) async {
    final render =
        tester.renderObject<RenderRepaintBoundary>(find.byKey(boundary));
    await tester.runAsync(() async {
      final image = await render.toImage(pixelRatio: 2);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final folder = Directory('../artifacts/ui');
      await folder.create(recursive: true);
      await File('${folder.path}/$name.png')
          .writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }

  test('bundled fonts are real TrueType files', () async {
    for (final name in ['Regular', 'Bold', 'Light']) {
      final bytes = await rootBundle.load('fonts/Roboto/Roboto-$name.ttf');
      expect(bytes.getUint32(0), 0x00010000,
          reason: 'Reject HTML downloads saved as font files');
    }
  });

  testWidgets('real profile routes preserve back stack and authenticated owner',
      (t) async {
    SharedPreferences.setMockInitialValues({});
    final conn = _UiConnection();
    hasProfile = true;
    await t.pumpWidget(ProviderScope(overrides: [
      authNotifierProvider.overrideWith((ref) => _UiAuth(conn)),
      connectionServiceProvider.overrideWithValue(conn),
      chatRepositoryProvider.overrideWithValue(_UiRepository()),
      conversationsProvider.overrideWith((ref) async => _chats())
    ], child: const ShadeApp()));
    await t.pumpAndSettle();
    await t.tap(find.byTooltip('Мой профиль'));
    await t.pumpAndSettle();
    final mine = t.widget<ProfileScreen>(find.byType(ProfileScreen));
    expect(mine.username, 'kait1x');
    expect(mine.isSelf, true);
    final router = GoRouter.of(t.element(find.byType(ProfileScreen)));
    unawaited(router.push<void>('/peer/alex', extra: 'fixture-key'));
    await t.pumpAndSettle();
    final peer = t.widget<ProfileScreen>(find.byType(ProfileScreen));
    expect(peer.username, 'alex');
    expect(peer.viewerUsername, 'kait1x');
    router.pop();
    await t.pumpAndSettle();
    expect(t.widget<ProfileScreen>(find.byType(ProfileScreen)).isSelf, true);
    router.pop();
    await t.pumpAndSettle();
    expect(find.byType(HomeScreen), findsOneWidget);
    await t.pumpWidget(const SizedBox.shrink());
    conn.dispose();
    hasProfile = false;
  });
  testWidgets(
      'real app exposes in-app notifications and server trust confirmation',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    final connection = _UiConnection();
    hasProfile = true;
    await tester.pumpWidget(ProviderScope(overrides: [
      authNotifierProvider.overrideWith((ref) => _UiAuth(connection)),
      connectionServiceProvider.overrideWithValue(connection),
      chatRepositoryProvider.overrideWithValue(_UiRepository()),
      conversationsProvider.overrideWith((ref) async => _chats()),
    ], child: const ShadeApp()));
    await tester.pumpAndSettle();
    connection.fixtureNotifications.add(IncomingMessage(
        id: 'fixture-notification-id',
        from: 'anya',
        data: 'fixture',
        timestamp: DateTime.now()));
    await tester.pumpAndSettle();
    expect(find.text('Новое сообщение от anya'), findsOneWidget);
    final answer = connection.onServerKeyConfirmation!(
        ServerKeyFingerprintResult(
            status: ServerKeyTrustStatus.newKeyRequiresConfirmation,
            fingerprint: 'aa:bb:cc'));
    await tester.pumpAndSettle();
    expect(find.text('Первое подключение к серверу'), findsOneWidget);
    await tester.tap(find.text('Доверять серверу'));
    await tester.pumpAndSettle();
    expect(await answer, isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    connection.dispose();
    hasProfile = false;
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('welcome renders and captures actual Flutter layout',
      (tester) async {
    await pump(tester, const WelcomeScreen(), welcome: true);
    expect(tester.takeException(), isNull);
    await capture(tester, 'welcome');
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));
  testWidgets('chat list filters by name, preview and saved items',
      (tester) async {
    await pump(tester, const HomeScreen());
    await capture(tester, 'chats');
    await tester.enterText(
        find.byKey(const Key('conversation-search')), 'masha');
    await tester.pumpAndSettle();
    expect(
        find.descendant(
            of: find.byType(ListTile), matching: find.text('masha')),
        findsOneWidget);
    expect(find.text('anya'), findsNothing);
    await tester.enterText(
        find.byKey(const Key('conversation-search')), 'Фото');
    await tester.pumpAndSettle();
    expect(find.text('danya'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('conversation-search')), '');
    await tester.tap(find.widgetWithText(ChoiceChip, 'Избранное'));
    await tester.pumpAndSettle();
    expect(find.text('anya'), findsNothing);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));
  testWidgets('conversation renders real bubbles and date separator',
      (tester) async {
    await pump(
        tester,
        const ChatScreen(
            conversationId: 2,
            args: ChatScreenArgs(
                conversationName: 'anya',
                recipientPublicKey: 'fixture-key',
                recipientUsername: 'anya')));
    expect(find.text('Сегодня'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await capture(tester, 'conversation');
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));
  testWidgets('new conversation screen has a usable empty state',
      (tester) async {
    await pump(tester, const UserSearchScreen());
    expect(tester.takeException(), isNull);
    await capture(tester, 'find-person');
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));
  testWidgets(
      'composer disables empty sends, submits once and opens attachments',
      (tester) async {
    final sent = <String>[];
    await pump(
        tester,
        Scaffold(
            body: Align(
                alignment: Alignment.bottomCenter,
                child:
                    MessageInput(onSend: sent.add, onImageSelected: (_) {}))));
    await tester.tap(find.byKey(const Key('send-message')));
    expect(sent, isEmpty);
    await tester.enterText(
        find.byKey(const Key('message-field')), '  Привет!  ');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('send-message')));
    await tester.pumpAndSettle();
    expect(sent, ['Привет!']);
    expect(find.text('Привет!'), findsNothing);
    await tester.tap(find.byTooltip('Прикрепить фото'));
    await tester.pumpAndSettle();
    expect(find.text('Камера'), findsOneWidget);
    expect(find.text('Галерея'), findsOneWidget);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));
  testWidgets('narrow phone and large text do not overflow', (tester) async {
    await pump(tester, const WelcomeScreen(),
        welcome: true, width: 320, height: 640, scale: 1.4);
    await tester.ensureVisible(find.byKey(const Key('google-sign-in')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await capture(tester, 'welcome-large-text');
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));
}
