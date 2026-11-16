import 'package:shade/core/services/connection_service.dart';
import 'package:shade/core/routing/navigation_keys.dart';
import 'package:flutter/material.dart';
import 'package:shade/core/widgets/shade_motion.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:shade/features/auth/data/repositories/auth_notifier.dart';
import 'package:shade/features/auth/presentation/screens/welcome_screen.dart';
import 'package:shade/features/home/presentation/screens/home_screen.dart';
import 'package:shade/features/home/presentation/screens/user_search_screen.dart';
import 'package:shade/features/chats/presentation/screens/chat_screen.dart';
import 'package:shade/main.dart';
import 'package:shade/features/profile/presentation/screens/profile_screen.dart';
import 'package:shade/features/chats/data/repositories/chat_repository.dart';

final _peerKey = FutureProvider.autoDispose.family<String?, String>((ref,
        name) async =>
    (await ref.read(connectionServiceProvider).getPublicKey(name))?.publicKey);

/// Top-level router provider that listens to [AuthState].
///
/// Uses global [hasProfile] flag to set initial route synchronously.
final goRouterProvider = Provider<GoRouter>((ref) {
  final refresh = _GoRouterRefreshNotifier(ref);
  ref.onDispose(refresh.dispose);

  return GoRouter(
    navigatorKey: shadeNavigatorKey,
    initialLocation: hasProfile ? '/home' : '/welcome',
    debugLogDiagnostics: true,
    redirect: (context, state) {
      final authState = ref.read(authNotifierProvider);
      final isAuthenticated = authState.status == AuthStatus.authenticated;
      final isChecking = authState.status == AuthStatus.initial ||
          authState.status == AuthStatus.generatingKeys;
      final isOnWelcome = state.uri.path == '/welcome';

      // Don't redirect while checking auth
      if (isChecking) return null;

      if (isAuthenticated && isOnWelcome) {
        return '/home';
      }

      if (!isAuthenticated && !isOnWelcome) {
        return '/welcome';
      }

      return null;
    },
    refreshListenable: refresh,
    routes: [
      GoRoute(
        path: '/welcome',
        builder: (context, state) => const WelcomeScreen(),
      ),
      GoRoute(
        path: '/home',
        builder: (context, state) => const HomeScreen(),
      ),
      GoRoute(
          path: '/profile',
          pageBuilder: (ctx, state) {
            final auth = ref.read(authNotifierProvider);
            return _homeTransition(
                ctx,
                state,
                ProfileScreen(
                    username: auth.nickname ?? '',
                    publicKey: auth.publicKey,
                    displayName: auth.displayName,
                    email: auth.email,
                    avatarUrl: auth.avatarUrl,
                    isSelf: true));
          }),
      GoRoute(
          path: '/peer/:username',
          pageBuilder: (ctx, state) {
            final name = state.pathParameters['username']!,
                owner = ref.read(authNotifierProvider).nickname;
            final cached = state.extra as String?;
            return _homeTransition(
                ctx,
                state,
                Consumer(
                    builder: (ctx, ref, _) => ProfileScreen(
                        key: ValueKey(name),
                        username: name,
                        viewerUsername: owner,
                        publicKey:
                            ref.watch(_peerKey(name)).valueOrNull ?? cached,
                        onWrite: () async {
                          if (cached != null && ctx.canPop()) {
                            ctx.pop();
                            return;
                          }
                          final id = await ref
                              .read(connectionServiceProvider)
                              .ensureConversation(name);
                          if (ctx.mounted && id > 0) {
                            ctx.pushReplacement('/chat/$id');
                          }
                        })));
          }),
      GoRoute(
        path: '/search',
        pageBuilder: (context, state) =>
            _homeTransition(context, state, const UserSearchScreen()),
      ),
      GoRoute(
        path: '/chat/:id',
        pageBuilder: (context, state) {
          final conversationId = int.tryParse(state.pathParameters['id'] ?? '');
          if (conversationId == null || conversationId <= 0) {
            return _homeTransition(
                context,
                state,
                const Scaffold(
                    body: Center(child: Text('Неверный адрес чата'))));
          }
          final chatArgs = state.extra;
          if (chatArgs is! ChatScreenArgs) {
            return _homeTransition(
                context, state, _RestoredChat(conversationId: conversationId));
          }

          return _homeTransition(
              context,
              state,
              ChatScreen(
                conversationId: conversationId,
                args: chatArgs,
              ));
        },
      ),
    ],
  );
});

/// Shared transitions preserve the stack and disable Hero flights with motion.
CustomTransitionPage<void> _homeTransition(
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

/// Converts a Riverpod [Ref] into a [Listenable] so GoRouter can refresh
/// when [AuthState] changes.
class _GoRouterRefreshNotifier extends ChangeNotifier {
  _GoRouterRefreshNotifier(Ref ref) {
    ref.listen<AuthState>(
      authNotifierProvider,
      (previous, next) {
        if (previous?.status != next.status) {
          notifyListeners();
        }
      },
    );
  }
}

class _RestoredChat extends ConsumerStatefulWidget {
  final int conversationId;
  const _RestoredChat({required this.conversationId});
  @override
  ConsumerState<_RestoredChat> createState() => _RestoredChatState();
}

class _RestoredChatState extends ConsumerState<_RestoredChat> {
  late Future<ChatScreenArgs?> _args;
  @override
  void initState() {
    super.initState();
    _args = _load();
  }

  Future<ChatScreenArgs?> _load() async {
    final chats = await ref.read(chatRepositoryProvider).getConversations();
    if (!mounted) return null;
    final chat = chats.where((c) => c.id == widget.conversationId).firstOrNull;
    if (chat == null) return null;
    final auth = ref.read(authNotifierProvider);
    final self = chat.name == 'Избранное' || chat.name == auth.nickname;
    var key = self ? auth.publicKey : chat.publicKey;
    if (!self && (key == null || key.isEmpty)) {
      final connection = ref.read(connectionServiceProvider);
      final bundle = await connection.getPublicKey(chat.name);
      if (!mounted) return null;
      key = bundle?.publicKey;
      if (key != null) {
        final db = await ref.read(databaseServiceProvider).database;
        await db.update('conversations', {'public_key': key},
            where: 'id = ?', whereArgs: [chat.id]);
      }
    }
    if (key == null || key.isEmpty) {
      throw StateError(
          'Не удалось получить подтверждённый ключ собеседника. Проверьте подключение и доверие к серверу.');
    }
    return ChatScreenArgs(
        conversationName: chat.name,
        recipientPublicKey: key,
        recipientUsername: self ? (auth.nickname ?? '') : chat.name);
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<ChatScreenArgs?>(
      future: _args,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Scaffold(body: Center(child: ShadeLoadingIndicator()));
        }
        final args = snapshot.data;
        if (args == null) {
          return Scaffold(
              appBar: AppBar(title: const Text('Переписка')),
              body: Center(
                  child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        Text(snapshot.hasError
                            ? 'Не удалось открыть чат. Проверьте сеть и ключ сервера.'
                            : 'Чат недоступен.'),
                        const SizedBox(height: 16),
                        OutlinedButton(
                            onPressed: () => setState(() {
                                  _args = _load();
                                }),
                            child: const Text('Повторить')),
                      ]))));
        }
        return ChatScreen(conversationId: widget.conversationId, args: args);
      });
}
