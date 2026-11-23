/// Shade v2 for Android. The default APK entry point dispatches here.
library;

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:shade/core/theme/shade_theme.dart';
import 'package:shade/features/v2/presentation/v2_providers.dart';
import 'package:shade/services/security_service.dart';
import 'package:shade/features/v2/presentation/v2_push.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  try {
    await Firebase.initializeApp();
  } catch (_) {
    debugPrint('Firebase is not configured on this platform');
  }

  // Скриншоты/запись экрана разрешены на всех экранах, как в v1.
  await SecurityService.disableSecureMode();
  await loadShadeAppearance();

  runApp(const ProviderScope(child: ShadeV2App()));
}

class ShadeV2App extends ConsumerWidget {
  const ShadeV2App({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(androidPushProvider);
    final router = ref.watch(v2RouterProvider);
    return ValueListenableBuilder<bool>(
      valueListenable: shadeLightTheme,
      builder: (_, light, __) => MaterialApp.router(
        title: 'Shade',
        debugShowCheckedModeBanner: false,
        routerConfig: router,
        theme: buildShadeLightTheme(),
        darkTheme: buildShadeTheme(),
        themeMode: light ? ThemeMode.light : ThemeMode.dark,
      ),
    );
  }
}
