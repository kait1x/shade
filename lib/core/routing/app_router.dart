import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:shade/features/auth/data/repositories/auth_notifier.dart';
import 'package:shade/features/auth/presentation/screens/welcome_screen.dart';
import 'package:shade/features/home/presentation/screens/home_screen.dart';
import 'package:shade/features/home/presentation/screens/user_search_screen.dart';
import 'package:shade/features/chats/presentation/screens/chat_screen.dart';
import 'package:shade/core/widgets/shade_logo.dart';
import 'package:shade/main.dart';

/// Top-level router provider that listens to [AuthState].
///
/// Shows a splash screen while checking auth, then redirects
/// to `/home` or `/welcome` based on state.
final goRouterProvider = Provider<GoRouter>((ref) {
  final authState = ref.watch(authNotifierProvider);

  return GoRouter(
    initialLocation: '/splash',
    debugLogDiagnostics: true,
    redirect: (context, state) {
      final isAuthenticated = authState.status == AuthStatus.authenticated;
      final isInitial = authState.status == AuthStatus.initial ||
          authState.status == AuthStatus.generatingKeys;

      final isOnWelcome = state.uri.path == '/welcome';
      final isOnSplash = state.uri.path == '/splash';

      // Still checking — stay on splash
      if (isInitial && !isOnSplash) return '/splash';

      // Done checking — route to correct screen
      if (!isInitial && isOnSplash) {
        return isAuthenticated ? '/home' : '/welcome';
      }

      if (!isAuthenticated && !isOnWelcome && !isOnSplash) {
        return '/welcome';
      }

      if (isAuthenticated && isOnWelcome) {
        return '/home';
      }

      return null;
    },
    refreshListenable: _GoRouterRefreshNotifier(ref),
    routes: [
      GoRoute(
        path: '/splash',
        builder: (context, state) => const _SplashScreen(),
      ),
      GoRoute(
        path: '/welcome',
        builder: (context, state) => const WelcomeScreen(),
      ),
      GoRoute(
        path: '/home',
        builder: (context, state) => const HomeScreen(),
      ),
      GoRoute(
        path: '/search',
        builder: (context, state) => const UserSearchScreen(),
      ),
      GoRoute(
        path: '/chat/:id',
        builder: (context, state) {
          final conversationId = int.parse(state.pathParameters['id']!);
          final chatArgs = state.extra as ChatScreenArgs;

          return ChatScreen(
            conversationId: conversationId,
            args: chatArgs,
          );
        },
      ),
    ],
  );
});

class _SplashScreen extends ConsumerWidget {
  const _SplashScreen();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final authState = ref.watch(authNotifierProvider);
    final hasError = authState.status == AuthStatus.error;

    return Scaffold(
      backgroundColor: ShadeColors.surfaceDark,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ShadeLogo(size: 100),
            const SizedBox(height: 24),
            const Text(
              'SHADE',
              style: TextStyle(
                color: ShadeColors.textPrimary,
                fontSize: 28,
                fontWeight: FontWeight.w700,
                letterSpacing: 6,
              ),
            ),
            const SizedBox(height: 32),
            if (hasError) ...[
              Text(
                authState.error ?? 'Ошибка загрузки',
                style: const TextStyle(
                  color: Color(0xFFEF4444),
                  fontSize: 14,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              TextButton(
                onPressed: () {
                  ref
                      .read(authNotifierProvider.notifier)
                      .checkExistingProfile();
                },
                child: const Text('Повторить'),
              ),
            ] else ...[
              const SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: ShadeColors.violet,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

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
