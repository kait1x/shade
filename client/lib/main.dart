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

/// Monochrome brand palette. Legacy accent names remain for API compatibility.
class ShadeColors {
  static const Color black = Color(0xFF0C0C0C);
  static const Color surfaceDark = Color(0xFF121212);
  static const Color surfaceCard = Color(0xFF1A1A1A);
  static const Color surfaceElevated = Color(0xFF262626);
  static const Color greyBorder = Color(0xFF343434);

  static const Color violet = Color(0xFFDEDEDE);
  static const Color violetLight = Color(0xFFF2F2F2);
  static const Color violetDark = Color(0xFF383838);

  static const Color cyan = Color(0xFFC9C9C9);
  static const Color cyanLight = Color(0xFFE6E6E6);

  static const Color textPrimary = Color(0xFFF3F3F3);
  static const Color textSecondary = Color(0xFFADADAD);
  static const Color textMuted = Color(0xFF929292);

  static const Color greenAccent = Color(0xFFBDBDBD);
}

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

  // Enable security mode (anti-screenshot on Android)
  await SecurityService.enableSecureMode();

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

ThemeData buildShadeTheme() {
  final base = ThemeData(
      brightness: Brightness.dark, useMaterial3: true, fontFamily: 'Roboto');

  final colorScheme = ColorScheme.dark(
    primary: ShadeColors.violet,
    onPrimary: ShadeColors.black,
    primaryContainer: ShadeColors.violetDark,
    onPrimaryContainer: ShadeColors.violetLight,
    secondary: ShadeColors.cyan,
    onSecondary: Colors.white,
    surface: ShadeColors.black,
    onSurface: ShadeColors.textPrimary,
    surfaceContainerHighest: ShadeColors.surfaceElevated,
    onSurfaceVariant: ShadeColors.textSecondary,
    outline: ShadeColors.greyBorder,
    outlineVariant: ShadeColors.greyBorder.withValues(alpha: 0.5),
    error: const Color(0xFFEF4444),
    onError: Colors.white,
  );

  return base.copyWith(
    colorScheme: colorScheme,
    scaffoldBackgroundColor: ShadeColors.black,

    // ── AppBar ──────────────────────────────────────────────
    appBarTheme: const AppBarTheme(
      backgroundColor: ShadeColors.black,
      elevation: 0,
      toolbarHeight: 72,
      scrolledUnderElevation: 0,
      surfaceTintColor: Colors.transparent,
      centerTitle: false,
      titleTextStyle: TextStyle(
        fontFamily: 'Roboto',
        fontSize: 20,
        fontWeight: FontWeight.bold,
        color: ShadeColors.textPrimary,
        letterSpacing: -0.3,
      ),
      iconTheme: IconThemeData(color: ShadeColors.textPrimary),
    ),

    // ── Cards ───────────────────────────────────────────────
    cardTheme: CardThemeData(
      color: ShadeColors.surfaceCard,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: ShadeColors.greyBorder, width: 0.5),
      ),
    ),

    // ── FAB ─────────────────────────────────────────────────
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: ShadeColors.violetDark,
      foregroundColor: Colors.white,
      elevation: 4,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
      ),
    ),

    // ── Text ────────────────────────────────────────────────
    textTheme: base.textTheme.apply(
      fontFamily: 'Roboto',
      bodyColor: ShadeColors.textPrimary,
      displayColor: ShadeColors.textPrimary,
    ),

    // ── Dividers ────────────────────────────────────────────
    dividerTheme: const DividerThemeData(
      color: ShadeColors.greyBorder,
      thickness: 0.5,
    ),

    // ── Dialogs ─────────────────────────────────────────────
    dialogTheme: DialogThemeData(
      backgroundColor: ShadeColors.surfaceCard,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: const BorderSide(color: ShadeColors.greyBorder, width: 0.5),
      ),
    ),

    // ── SnackBar ────────────────────────────────────────────
    snackBarTheme: SnackBarThemeData(
      backgroundColor: ShadeColors.surfaceElevated,
      contentTextStyle: const TextStyle(color: ShadeColors.textPrimary),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
      ),
      behavior: SnackBarBehavior.floating,
    ),

    // ── Input fields ────────────────────────────────────────
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: ShadeColors.surfaceCard,
      hintStyle: const TextStyle(color: ShadeColors.textMuted),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: ShadeColors.greyBorder),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: ShadeColors.greyBorder),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: ShadeColors.violet, width: 1.5),
      ),
      contentPadding: const EdgeInsets.symmetric(
        horizontal: 16,
        vertical: 14,
      ),
    ),

    // ── Buttons ─────────────────────────────────────────────
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: ShadeColors.violetDark,
        foregroundColor: Colors.white,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
        ),
        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 24),
        textStyle: const TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.bold,
          letterSpacing: 0.5,
        ),
      ),
    ),

    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: ShadeColors.violetDark,
        foregroundColor: Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
        ),
      ),
    ),

    outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
            foregroundColor: ShadeColors.violetLight,
            side: const BorderSide(color: ShadeColors.greyBorder),
            textStyle: const TextStyle(
                fontFamily: 'Roboto',
                fontSize: 14,
                fontWeight: FontWeight.w700),
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(15)))),
    // ── Progress indicator ──────────────────────────────────
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: ShadeColors.violet,
    ),

    chipTheme: base.chipTheme.copyWith(
        backgroundColor: ShadeColors.surfaceDark,
        selectedColor: const Color(0xFF303030),
        side: BorderSide.none,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(13)),
        labelStyle: const TextStyle(
            fontFamily: 'Roboto',
            fontSize: 12,
            fontWeight: FontWeight.w700,
            color: ShadeColors.violetLight)),
    bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: ShadeColors.surfaceCard,
        showDragHandle: true,
        dragHandleColor: ShadeColors.textMuted,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(28)))),
    // ── ListTile
    //  ────────────────────────────────────────────
    listTileTheme: const ListTileThemeData(
      textColor: ShadeColors.textPrimary,
      iconColor: ShadeColors.textSecondary,
    ),
  );
}
