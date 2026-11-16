import 'package:shade/core/theme/shade_theme.dart';
export 'package:shade/core/theme/shade_theme.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:shade/features/auth/data/repositories/auth_notifier.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:shade/core/routing/app_router.dart';
import 'package:shade/core/services/notification_service.dart';
import 'package:shade/core/widgets/notification_overlay.dart';
import 'package:shade/services/security_service.dart';

/// Global flag: true if user has a profile (checked before first frame)
bool hasProfile = false;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Synchronous-like check: read SharedPreferences before building UI
  final prefs = await SharedPreferences.getInstance();
  hasProfile = (prefs.getBool('has_profile') ?? false) &&
      prefs.getBool('signed_out') != true;

  try {
    await Firebase.initializeApp();
    FirebaseMessaging.onBackgroundMessage(handleBackgroundMessage);
  } catch (_) {
    debugPrint('Firebase is not configured on this platform');
  }

  // Ensure screenshot and screen recording restrictions are removed across all screens.
  await SecurityService.disableSecureMode();

  runApp(
    const ProviderScope(
      child: ShadeApp(),
    ),
  );
}

class ShadeApp extends ConsumerWidget {
  const ShadeApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(goRouterProvider);

    final authenticated =
        ref.watch(authNotifierProvider).status == AuthStatus.authenticated;
    NotificationService.setTapHandler(authenticated
        ? (target) async {
            final user = ref.read(authNotifierProvider);
            if (user.status != AuthStatus.authenticated) return;
            try {
              int id;
              if (target.startsWith('user:')) {
                final name = target.substring(5);
                if (!RegExp(r'^[a-z0-9_]{3,32}$').hasMatch(name)) return;
                final db = ref.read(databaseServiceProvider);
                id = await db.createConversation(name);
              } else {
                final parsed = int.tryParse(target);
                if (parsed == null || parsed <= 0) return;
                id = parsed;
              }
              if (ref.read(authNotifierProvider).status !=
                  AuthStatus.authenticated) {
                return;
              }
              router.go('/home');
              router.push('/chat/$id');
            } catch (_) {
              debugPrint('Unable to open notification conversation');
            }
          }
        : null);

    return MaterialApp.router(
      title: 'Shade',
      debugShowCheckedModeBanner: false,
      routerConfig: router,
      theme: buildShadeTheme(),
      builder: (context, child) =>
          NotificationOverlay(child: child ?? const SizedBox.shrink()),
    );
  }
}
