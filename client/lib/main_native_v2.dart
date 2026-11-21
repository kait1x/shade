/// Native v2 entry point (решение D2, вариант A): полноценный Flutter/Dart UI
/// поверх существующего device-v2 стека без дублирования архитектуры.
///
/// Собирается через `flutter build/run --target lib/main_native_v2.dart`.
/// v1 entry (main_native.dart) остаётся default до cutover и не изменяется.
/// Firebase инициализируется как в v1; push-уведомления подключаются позже.
library;

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:shade/core/theme/shade_theme.dart';
import 'package:shade/features/v2/presentation/v2_providers.dart';
import 'package:shade/services/security_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  try {
    await Firebase.initializeApp();
  } catch (_) {
    debugPrint('Firebase is not configured on this platform');
  }

  // Скриншоты/запись экрана разрешены на всех экранах, как в v1.
  await SecurityService.disableSecureMode();

  runApp(const ProviderScope(child: ShadeV2App()));
}

class ShadeV2App extends ConsumerWidget {
  const ShadeV2App({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp.router(
      title: 'Shade',
      debugShowCheckedModeBanner: false,
      routerConfig: ref.watch(v2RouterProvider),
      theme: buildShadeTheme(),
    );
  }
}