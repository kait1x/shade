import 'package:flutter/material.dart';

/// Monochrome brand palette. Legacy accent names remain for API compatibility.
class ShadeColors {
  static const Color black = Color(0xFF000000);
  static const Color surfaceDark = Color(0xFF0B0B0D);
  static const Color surfaceCard = Color(0xFF111113);
  static const Color surfaceElevated = Color(0xFF1C1C1F);
  static const Color greyBorder = Color(0xFF29292D);

  static const Color violet = Color(0xFFDEDEDE);
  static const Color violetLight = Color(0xFFF2F2F2);
  static const Color violetDark = Color(0xFF383838);

  static const Color cyan = Color(0xFFC9C9C9);
  static const Color cyanLight = Color(0xFFE6E6E6);

  static const Color textPrimary = Color(0xFFF5F5F7);
  static const Color textSecondary = Color(0xFF9C9CA3);
  static const Color textMuted = Color(0xFF8E8E93);

  static const Color greenAccent = Color(0xFFBDBDBD);
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
        backgroundColor: ShadeColors.textPrimary,
        foregroundColor: Colors.black,
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
