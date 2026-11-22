import 'package:flutter/material.dart';

/// The graphite tint and rim establish depth even over pure OLED black.
abstract final class ShadeGlass {
  static const rim = Color(0x28FFFFFF);
  static const focusedRim = Color(0x55FFFFFF);

  static BoxDecoration graphite(BorderRadius radius, {Color border = rim}) =>
      BoxDecoration(
        borderRadius: radius,
        border: Border.all(color: border),
        gradient: const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xED262629), Color(0xE917171B)],
        ),
      );
}
