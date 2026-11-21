/// Riverpod-состояние native v2 поверх device-v2 стека.
///
/// Сессия восстанавливается из долговечных ключей: prefs origin/account +
/// Keystore cookie и зафиксированное v2-состояние (v2_accounts/v2_device_keys).
/// v2-only устройство (pairing/recovery) поднимается без v1-профиля; primary
/// использует якорь rotation либо исходный v1-ключ. Подключение и enrollment
/// переиспользуют проверенный AlphaV2Screen, чат/профиль/устройства работают
/// через V2SyncService. v1-поток (main_native.dart) не затрагивается.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:shade/core/services/crypto_service.dart';
import 'package:shade/core/services/device_v2/crypto.dart';
import 'package:shade/core/services/device_v2/protocol.dart';
import 'package:shade/core/services/device_v2/repository.dart';
import 'package:shade/core/services/device_v2/store.dart';
import 'package:shade/core/services/device_v2/sync.dart';
import 'package:shade/core/services/device_v2/transport.dart';
import 'package:shade/core/widgets/shade_motion.dart';
import 'package:shade/features/auth/data/repositories/auth_notifier.dart'
    show cryptoServiceProvider, databaseServiceProvider;

import 'v2_chat_screen.dart';
import 'v2_chats_screen.dart';
import 'v2_connect_screen.dart';
import 'v2_devices_screen.dart';
import 'v2_enrollment_route.dart';
import 'v2_profile_screen.dart';

/// Модели проекций sync-слоя доступны экранам через единый импорт провайдеров.
export 'package:shade/core/services/device_v2/sync.dart';

// ── Сессия ────────────────────────────────────────────────────────────────

enum V2SessionStatus { loading, disconnected, needsEnrollment, ready, error }

class V2SessionState {
  final V2SessionStatus status;
  final String? account;
  final String? error;

  const V2SessionState({
    this.status = V2SessionStatus.loading,
    this.account,
    this.error,
  });

  V2SessionState copyWith({
    V2SessionStatus? status,
    String? account,
    String? error,
    bool clearError = false,
  }) =>
      V2SessionState(
        status: status ?? this.status,
        account: account ?? this.account,
        error: clearError ? null : (error ?? this.error),
      );
}

/// Владелец транспорта/репозитория/sync: один стек на всё v2-приложение.
class V2SessionNotifier extends StateNotifier<V2SessionState> {
  final Ref _ref;
  AlphaTransport? _transport;
  V2ChatRepository? _repository;
  V2SyncService? _sync;

  V2SessionNotifier(this._ref) : super(const V2SessionState()) {
    unawaited(restore());
  }

  V2SyncService? get sync => _sync;
  V2ChatRepository? get repository => _repository;

  /// Восстановление сессии из долговечного хранилища. Источник ключей —
  /// зафиксированное v2-состояние, а не обязательный v1-профиль:
  ///  - вторичное/recovery-устройство (sessionId != 'primary'): сессия из
  ///    долговечных ключей v2_device_keys, как их фиксируют completePairing/
  ///    recoverWithBackup; v1-профиль не требуется (v2-only устройство);
  ///  - primary после rotation: приватный якорь из v2_accounts.anchor_key;
  ///  - primary без rotation: исходный v1-ключ (SecureStorage/Keystore);
  ///  - v2-состояния нет: enrollment требует v1-профиля, без него — честный
  ///    disconnected.
  /// Повторный вызов пересоздаёт стек.
  Future<void> restore() async {
    _teardown();
    state = const V2SessionState();
    AlphaTransport? transport;
    try {
      final prefs = await SharedPreferences.getInstance();
      final origin = prefs.getString('alpha_v2_origin');
      final account = prefs.getString('alpha_v2_account');
      const secure = FlutterSecureStorage(
          aOptions: AndroidOptions(encryptedSharedPreferences: true));
      final cookie = await secure.read(key: 'alpha_v2_cookie');
      if (origin == null || account == null || cookie == null) {
        state = const V2SessionState(status: V2SessionStatus.disconnected);
        return;
      }
      final crypto = _ref.read(cryptoServiceProvider);
      final database = _ref.read(databaseServiceProvider);
      final store = V2Store(database);
      final acc = await store.loadAccount(account);
      transport = _ref.read(v2TransportFactoryProvider)(origin, crypto);
      transport.sessionCookie = cookie;
      final String root;
      final String privateKey;
      if (acc != null && acc['sessionId'] != 'primary') {
        // v2-only устройство: идентичность — долговечные ключи устройства.
        final keys = await store.loadDeviceKeys(account);
        if (keys == null) {
          transport.dispose();
          transport = null;
          state = const V2SessionState(
              status: V2SessionStatus.error,
              error: 'Ключи устройства v2 не найдены. '
                  'Подключите устройство заново.');
          return;
        }
        root = acc['root'] as String;
        // Приватная часть якоря вторичному устройству не нужна: все операции
        // подписываются ключом сессии (load() поднимет её из v2_device_keys).
        privateKey = (acc['anchorKey'] as String?) ?? '';
      } else if (acc != null) {
        // Primary: якорь rotation из зашифрованного хранилища, иначе v1-ключ.
        root = acc['root'] as String;
        final anchor = acc['anchorKey'] as String?;
        final v1Private = await crypto.getPrivateKey();
        final effective =
            (anchor != null && anchor.isNotEmpty) ? anchor : v1Private;
        if (effective == null || effective.isEmpty) {
          transport.dispose();
          transport = null;
          state = const V2SessionState(
              status: V2SessionStatus.disconnected,
              error: 'Сначала создайте профиль Shade на этом устройстве.');
          return;
        }
        privateKey = effective;
      } else {
        // Нет v2-состояния: enrollment возможен только с v1-профилем.
        final publicKey = await crypto.getPublicKey();
        final v1Private = await crypto.getPrivateKey();
        if (publicKey == null || v1Private == null) {
          transport.dispose();
          transport = null;
          state = const V2SessionState(
              status: V2SessionStatus.disconnected,
              error: 'Сначала создайте профиль Shade на этом устройстве.');
          return;
        }
        root = await publicSpki(publicKey);
        privateKey = v1Private;
      }
      final repository = V2ChatRepository(
          transport: transport,
          crypto: crypto,
          store: store,
          account: account,
          root: root,
          privateKey: privateKey);
      await repository.load();
      _transport = transport;
      _repository = repository;
      if (!repository.enrolled) {
        state = V2SessionState(
            status: V2SessionStatus.needsEnrollment, account: account);
        return;
      }
      final sync = V2SyncService(repository: repository, database: database);
      _sync = sync;
      sync.start();
      state = V2SessionState(status: V2SessionStatus.ready, account: account);
    } catch (error) {
      // Транспорт, не переданный в стек, освобождается здесь; переданный —
      // в _teardown (повторный dispose не допускается).
      if (!identical(transport, _transport)) transport?.dispose();
      _teardown();
      state = V2SessionState(
          status: V2SessionStatus.error,
          error: 'Не удалось восстановить сессию v2: $error');
    }
  }

  Future<void> logout() async {
    final transport = _transport;
    if (transport == null) return;
    await transport.logout();
    const secure = FlutterSecureStorage(
        aOptions: AndroidOptions(encryptedSharedPreferences: true));
    await secure.delete(key: 'alpha_v2_cookie');
    _teardown();
    state = const V2SessionState(status: V2SessionStatus.disconnected);
  }

  Future<void> refresh() => restore();

  void _teardown() {
    _sync?.dispose();
    _sync = null;
    _transport?.dispose();
    _transport = null;
    _repository = null;
  }

  @override
  void dispose() {
    _teardown();
    super.dispose();
  }
}

final v2SessionProvider =
    StateNotifierProvider<V2SessionNotifier, V2SessionState>(
        (ref) => V2SessionNotifier(ref));

/// Фабрика транспорта сессии: production создаёт реальный AlphaTransport;
/// тесты подменяют scripted-транспортом через override провайдера.
final v2TransportFactoryProvider =
    Provider<AlphaTransport Function(String origin, CryptoService crypto)>(
        (ref) => AlphaTransport.new);

/// Активный sync-сервис (null, пока сессия не готова).
final v2SyncProvider = Provider<V2SyncService?>((ref) {
  final session = ref.watch(v2SessionProvider);
  if (session.status != V2SessionStatus.ready) return null;
  return ref.read(v2SessionProvider.notifier).sync;
});

/// Тик инвалидации проекций после каждого sync-цикла.
final _v2TickProvider = StreamProvider.autoDispose<void>((ref) {
  final sync = ref.watch(v2SyncProvider);
  return sync == null ? const Stream<void>.empty() : sync.changes;
});

// ── Список чатов ──────────────────────────────────────────────────────────

class V2ChatListState {
  final bool loading;
  final String? error;
  final List<V2ChatSummary> chats;
  final String query;
  final String selfAccount;
  final bool savedOnly;

  const V2ChatListState({
    this.loading = true,
    this.error,
    this.chats = const [],
    this.query = '',
    this.selfAccount = '',
    this.savedOnly = false,
  });

  V2ChatListState copyWith({
    bool? loading,
    String? error,
    List<V2ChatSummary>? chats,
    String? query,
    String? selfAccount,
    bool? savedOnly,
    bool clearError = false,
  }) =>
      V2ChatListState(
        loading: loading ?? this.loading,
        error: clearError ? null : (error ?? this.error),
        chats: chats ?? this.chats,
        query: query ?? this.query,
        selfAccount: selfAccount ?? this.selfAccount,
        savedOnly: savedOnly ?? this.savedOnly,
      );

  /// Локальный поиск: по аккаунту и по «Избранному».
  List<V2ChatSummary> get filtered {
    final q = query.trim().toLowerCase();
    final visible =
        savedOnly ? chats.where((c) => c.peer == selfAccount) : chats;
    return visible
        .where((c) =>
            c.peer.toLowerCase().contains(q) ||
            (c.lastText ?? '').toLowerCase().contains(q) ||
            (c.peer == selfAccount && 'избранное'.contains(q)))
        .toList();
  }
}

class V2ChatListNotifier extends StateNotifier<V2ChatListState> {
  final V2SyncService _sync;
  StreamSubscription<void>? _sub;
  bool _disposed = false;
  int _loadVersion = 0;

  V2ChatListNotifier(this._sync) : super(const V2ChatListState()) {
    _sub = _sync.changes.listen((_) => _load());
    _load();
  }

  Future<void> _load() async {
    if (_disposed) return;
    final version = ++_loadVersion;
    try {
      final chats = await _sync.chats();
      if (_disposed || version != _loadVersion) return;
      state = state.copyWith(
          chats: chats,
          loading: false,
          clearError: true,
          selfAccount: _sync.account);
    } catch (error) {
      if (_disposed || version != _loadVersion) return;
      state = state.copyWith(loading: false, error: '$error');
    }
  }

  void filterSaved(bool value) => state = state.copyWith(savedOnly: value);
  void setQuery(String query) => state = state.copyWith(query: query);
  Future<void> refresh() async {
    await _sync.syncNow();
    await _load();
  }

  /// Сверка genesis digest вне relay — только после явного подтверждения.
  Future<void> addContact(String peer, String? genesisDigest) async {
    await _sync.confirmContact(peer, genesisDigest);
    await _load();
  }

  @override
  void dispose() {
    _disposed = true;
    _sub?.cancel();
    super.dispose();
  }
}

final v2ChatListProvider =
    StateNotifierProvider.autoDispose<V2ChatListNotifier, V2ChatListState>(
        (ref) => V2ChatListNotifier(ref.watch(v2SyncProvider)!));

// ── Диалог ────────────────────────────────────────────────────────────────

class V2ConversationState {
  final bool loading;
  final String? error;
  final List<V2MessageView> messages;
  final V2MessageView? replyTo;
  final bool peerTyping;
  final bool? peerOnline;
  final bool blocked;

  const V2ConversationState({
    this.loading = true,
    this.error,
    this.messages = const [],
    this.replyTo,
    this.peerTyping = false,
    this.peerOnline,
    this.blocked = false,
  });

  V2ConversationState copyWith({
    bool? loading,
    String? error,
    List<V2MessageView>? messages,
    V2MessageView? replyTo,
    bool? peerTyping,
    bool? peerOnline,
    bool? blocked,
    bool clearReply = false,
    bool clearError = false,
  }) =>
      V2ConversationState(
        loading: loading ?? this.loading,
        error: clearError ? null : (error ?? this.error),
        messages: messages ?? this.messages,
        replyTo: clearReply ? null : (replyTo ?? this.replyTo),
        peerTyping: peerTyping ?? this.peerTyping,
        peerOnline: peerOnline ?? this.peerOnline,
        blocked: blocked ?? this.blocked,
      );
}

class V2ConversationNotifier extends StateNotifier<V2ConversationState> {
  final V2SyncService _sync;
  final String peer;
  StreamSubscription<void>? _changesSub;
  StreamSubscription<V2TypingEvent>? _typingSub;
  StreamSubscription<V2PresenceEvent>? _presenceSub;
  Timer? _typingTimer;
  final _readSent = <String>{};
  bool _disposed = false;
  int _loadVersion = 0;

  V2ConversationNotifier(this._sync, this.peer)
      : super(const V2ConversationState()) {
    _changesSub = _sync.changes.listen((_) => _load());
    _typingSub = _sync.typing.listen((event) {
      if (event.account != peer || _disposed) return;
      _typingTimer?.cancel();
      state = state.copyWith(peerTyping: true);
      final left = event.until - DateTime.now().millisecondsSinceEpoch;
      _typingTimer = Timer(Duration(milliseconds: left.clamp(0, 10000)), () {
        if (!_disposed) state = state.copyWith(peerTyping: false);
      });
    });
    _presenceSub = _sync.presence.listen((event) {
      if (event.account != peer || _disposed) return;
      state = state.copyWith(peerOnline: event.online);
    });
    if (peer != _sync.account) _sync.watch(peer);
    _load();
  }

  bool get isSelf => peer == _sync.account;

  Future<void> _load() async {
    if (_disposed) return;
    final version = ++_loadVersion;
    try {
      final messages = await _sync.conversation(peer);
      final blocked = await _sync.peerUpgradeBlocked(peer);
      if (_disposed || version != _loadVersion) return;
      state = state.copyWith(
          messages: messages,
          loading: false,
          blocked: blocked,
          clearError: true);
      _markRead(messages);
    } catch (error) {
      if (_disposed || version != _loadVersion) return;
      state = state.copyWith(loading: false, error: '$error');
    }
  }

  /// Read-ACK только для ещё не отмеченных входящих (идемпотентно на сервере).
  void _markRead(List<V2MessageView> messages) {
    final refs = [
      for (final m in messages)
        if (!m.mine && m.status != 'retracted')
          for (final ref in m.refs)
            if (!_readSent.contains(ref) && !ref.startsWith('v1:')) ref
    ];
    if (refs.isEmpty) return;
    _readSent.addAll(refs);
    unawaited(_sync.markRead(refs).catchError((Object _) {
      _readSent.removeAll(refs);
    }));
  }

  Future<void> send(String text) async {
    final reply = state.replyTo;
    await _sync.send(peer, text,
        reply: reply == null
            ? null
            : {
                'ref': reply.ref,
                'from': reply.mine ? _sync.account : peer,
                'text': reply.isImage ? 'Фото' : reply.text,
              });
    if (_disposed) return;
    state = state.copyWith(clearReply: true);
  }

  Future<void> sendImage(List<int> bytes) => _sync.sendImage(peer, bytes);

  void setReply(V2MessageView message) =>
      state = state.copyWith(replyTo: message);
  void clearReply() => state = state.copyWith(clearReply: true);

  Future<void> deleteLocal(String ref) async {
    final message = state.messages.where((m) => m.ref == ref).firstOrNull;
    for (final part in message?.refs ?? [ref]) {
      await _sync.deleteLocal(part);
    }
  }

  Future<void> retract(String ref) async {
    final message = state.messages.where((m) => m.ref == ref).firstOrNull;
    for (final part in message?.refs ?? [ref]) {
      await _sync.retract(part);
    }
  }

  void notifyTyping() {
    if (!isSelf) _sync.sendTyping(peer);
  }

  Future<void> refresh() async {
    await _sync.syncNow();
    await _load();
  }

  @override
  void dispose() {
    _disposed = true;
    _changesSub?.cancel();
    _typingSub?.cancel();
    _presenceSub?.cancel();
    _typingTimer?.cancel();
    if (!isSelf) _sync.unwatch(peer);
    super.dispose();
  }
}

final v2ConversationProvider = StateNotifierProvider.autoDispose
    .family<V2ConversationNotifier, V2ConversationState, String>((ref, peer) =>
        V2ConversationNotifier(ref.watch(v2SyncProvider)!, peer));

// ── Профиль и устройства ──────────────────────────────────────────────────

final v2ProfileProvider = FutureProvider.autoDispose<V2ProfileView?>((ref) {
  ref.watch(_v2TickProvider);
  final sync = ref.watch(v2SyncProvider);
  return sync == null ? Future.value(null) : sync.profile();
});

/// [refresh] = true сверяет ростер с сервером (read-only verifyHistory).
final v2DevicesProvider = FutureProvider.autoDispose
    .family<List<V2DeviceView>, bool>(
        (ref, refresh) => ref.watch(v2SyncProvider)!.devices(refresh: refresh));

// ── Роутер ────────────────────────────────────────────────────────────────

final v2RouterProvider = Provider<GoRouter>((ref) {
  final refresh = _V2RouterRefresh(ref);
  ref.onDispose(refresh.dispose);
  return GoRouter(
    initialLocation: '/',
    refreshListenable: refresh,
    redirect: (context, state) {
      final session = ref.read(v2SessionProvider);
      final path = state.uri.path;
      switch (session.status) {
        case V2SessionStatus.loading:
          return path == '/loading' ? null : '/loading';
        case V2SessionStatus.disconnected:
        case V2SessionStatus.needsEnrollment:
        case V2SessionStatus.error:
          return (path == '/connect' || path == '/enrollment')
              ? null
              : '/connect';
        case V2SessionStatus.ready:
          return (path == '/loading' || path == '/connect') ? '/' : null;
      }
    },
    routes: [
      GoRoute(
          path: '/loading',
          builder: (context, state) =>
              const Scaffold(body: Center(child: ShadeLoadingIndicator()))),
      GoRoute(
          path: '/connect',
          builder: (context, state) => const V2ConnectScreen()),
      GoRoute(path: '/', builder: (context, state) => const V2ChatsScreen()),
      GoRoute(
          path: '/chat/:peer',
          pageBuilder: (context, state) {
            final peer = state.pathParameters['peer'] ?? '';
            if (!accountPattern.hasMatch(peer)) {
              return _v2Page(
                  context,
                  state,
                  const Scaffold(
                      body: Center(child: Text('Неверный адрес чата'))));
            }
            return _v2Page(context, state, V2ChatScreen(peer: peer));
          }),
      GoRoute(
          path: '/profile',
          pageBuilder: (context, state) =>
              _v2Page(context, state, const V2ProfileScreen())),
      GoRoute(
          path: '/devices',
          pageBuilder: (context, state) =>
              _v2Page(context, state, const V2DevicesScreen())),
      GoRoute(
          path: '/enrollment',
          pageBuilder: (context, state) =>
              _v2Page(context, state, const V2EnrollmentRoute())),
    ],
  );
});

/// Переходы в конвенции v1: короткий fade+slide, уважая reduced-motion.
CustomTransitionPage<void> _v2Page(
        BuildContext context, GoRouterState state, Widget child) =>
    CustomTransitionPage<void>(
        key: state.pageKey,
        child: child,
        transitionDuration: ShadeMotion.duration(context, 220),
        reverseTransitionDuration: ShadeMotion.duration(context, 180),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          if (MediaQuery.disableAnimationsOf(context)) return child;
          final curve = animation.drive(CurveTween(curve: Curves.easeOutCubic));
          return FadeTransition(
              opacity: curve,
              child: SlideTransition(
                  position:
                      Tween(begin: const Offset(.035, 0), end: Offset.zero)
                          .animate(curve),
                  child: child));
        });

class _V2RouterRefresh extends ChangeNotifier {
  _V2RouterRefresh(Ref ref) {
    ref.listen<V2SessionState>(v2SessionProvider, (previous, next) {
      if (previous?.status != next.status) notifyListeners();
    });
  }
}
