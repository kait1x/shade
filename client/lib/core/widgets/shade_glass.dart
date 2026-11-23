import 'package:flutter/material.dart';

/// The graphite tint and rim establish depth even over pure OLED black.
abstract final class ShadeGlass {
  static const rim = Color(0x28FFFFFF);
  static const focusedRim = Color(0x55FFFFFF);

  static BoxDecoration graphite(BorderRadius radius,
          {Color border = rim, bool light = false}) =>
      BoxDecoration(
        borderRadius: radius,
        border: Border.all(
          color: light
              ? (border == focusedRim
                  ? const Color(0xFF858E9B)
                  : const Color(0xFFD7DBE0))
              : border,
        ),
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: light
              ? const [Color(0xFFFFFFFF), Color(0xFFF0F2F4)]
              : const [Color(0xED262629), Color(0xE917171B)],
        ),
      );
}
