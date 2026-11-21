import 'package:flutter/material.dart';

/// Home-specific tokens; other screens retain their existing palette.
abstract final class HomeStyle {
  static const background = Color(0xFF000000);
  static const surface = Color(0xFF111113);
  static const border = Color(0xFF29292D);
  static const ink = Color(0xFFF5F5F7);
  static const searchBorder = OutlineInputBorder(
      borderRadius: BorderRadius.all(Radius.circular(14)),
      borderSide: BorderSide(color: border));
  static Duration duration(BuildContext context) =>
      MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : const Duration(milliseconds: 200);
}
