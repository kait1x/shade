import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:shade/core/routing/app_router.dart';
import 'package:shade/core/services/notification_service.dart';
import 'package:shade/core/widgets/notification_overlay.dart';

/// Shade brand colors.
class ShadeColors {
  static const Color black = Color(0xFF000000);
  static const Color surfaceDark = Color(0xFF0A0A0A);
  static const Color surfaceCard = Color(0xFF111111);
  static const Color surfaceElevated = Color(0xFF1A1A1A);
  static const Color greyBorder = Color(0xFF1E1E1E);

  static const Color violet = Color(0xFF8B5CF6);
  static const Color violetLight = Color(0xFFA78BFA);
  static const Color violetDark = Color(0xFF6D28D9);

  static const Color cyan = Color(0xFF06B6D4);
  static const Color cyanLight = Color(0xFF22D3EE);

  static const Color textPrimary = Color(0xFFF5F5F5);
  static const Color textSecondary = Color(0xFF9CA3AF);
  static const Color textMuted = Color(0xFF6B7280);

  static const Color greenAccent = Color(0xFF34D399);
}

void main() {
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

    // Set up notification tap handler
    NotificationService.setTapHandler((conversationId) {
      router.go('/home');
      router.push('/chat/$conversationId');
    });

    return NotificationOverlay(
      child: MaterialApp.router(
        title: 'Shade',
        debugShowCheckedModeBanner: false,
        routerConfig: router,
        theme: _buildDarkTheme(),
      ),
    );
  }

  ThemeData _buildDarkTheme() {
    final base = ThemeData(brightness: Brightness.dark, useMaterial3: true);

    final colorScheme = ColorScheme.dark(
      primary: ShadeColors.violet,
      onPrimary: Colors.white,
      primaryContainer: ShadeColors.violetDark,
      onPrimaryContainer: ShadeColors.violetLight,
      secondary: ShadeColors.cyan,
      onSecondary: Colors.white,
      surface: ShadeColors.black,
      onSurface: ShadeColors.textPrimary,
      surfaceContainerHighest: ShadeColors.surfaceElevated,
      onSurfaceVariant: ShadeColors.textSecondary,
      outline: ShadeColors.greyBorder,
      outlineVariant: ShadeColors.greyBorder.withOpacity(0.5),
      error: const Color(0xFFEF4444),
      onError: Colors.white,
    );

    return base.copyWith(
      colorScheme: colorScheme,
      scaffoldBackgroundColor: ShadeColors.black,

      // ── AppBar ──────────────────────────────────────────────
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        centerTitle: true,
        titleTextStyle: TextStyle(
          fontFamily: 'Roboto',
          fontSize: 20,
          fontWeight: FontWeight.bold,
          color: ShadeColors.textPrimary,
          letterSpacing: 1,
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
        backgroundColor: ShadeColors.violet,
        foregroundColor: Colors.white,
        elevation: 4,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
      ),

      // ── Text ────────────────────────────────────────────────
      textTheme: base.textTheme.apply(
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
          backgroundColor: ShadeColors.violet,
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
          backgroundColor: ShadeColors.violet,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      ),

      // ── Progress indicator ──────────────────────────────────
      progressIndicatorTheme: const ProgressIndicatorThemeData(
        color: ShadeColors.violet,
      ),

      // ── ListTile ────────────────────────────────────────────
      listTileTheme: const ListTileThemeData(
        textColor: ShadeColors.textPrimary,
        iconColor: ShadeColors.textSecondary,
      ),
    );
  }
}
