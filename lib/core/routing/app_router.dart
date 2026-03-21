import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:shade/features/auth/data/repositories/auth_notifier.dart';
import 'package:shade/features/auth/presentation/screens/welcome_screen.dart';
import 'package:shade/features/home/presentation/screens/home_screen.dart';
import 'package:shade/features/chats/presentation/screens/chat_screen.dart';

/// Top-level router provider that listens to [AuthState].
///
/// When the user is authenticated the router redirects to `/home`,
/// otherwise to `/welcome`.
final goRouterProvider = Provider<GoRouter>((ref) {
  final authState = ref.watch(authNotifierProvider);

  return GoRouter(
    initialLocation: '/welcome',
    debugLogDiagnostics: true,
    redirect: (context, state) {
      final isAuthenticated =
          authState.status == AuthStatus.authenticated;

      final isOnWelcome = state.uri.path == '/welcome';

      if (!isAuthenticated && !isOnWelcome) {
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
        path: '/welcome',
        builder: (context, state) => const WelcomeScreen(),
      ),
      GoRoute(
        path: '/home',
        builder: (context, state) => const HomeScreen(),
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
