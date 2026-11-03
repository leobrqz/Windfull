import 'package:flutter/material.dart';

abstract final class WindfullTheme {
  static const canvas = Color(0xFF101416);
  static const surface = Color(0xFF1A2023);
  static const surfaceRaised = Color(0xFF222A2D);
  static const rail = Color(0xFF343E41);
  static const border = Color(0x20FFFFFF);
  static const text = Color(0xFFF0F5F4);
  static const muted = Color(0xFF9BA8AA);
  static const mutedInk = muted;
  static const disabled = Color(0xFF566266);
  static const accent = Color(0xFF9FE3D9);
  static const warning = Color(0xFFF0BC70);
  static const danger = Color(0xFFE7978C);

  static ThemeData build() => ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    scaffoldBackgroundColor: Colors.transparent,
    colorScheme: const ColorScheme.dark(
      primary: accent,
      onPrimary: canvas,
      secondary: accent,
      onSecondary: canvas,
      surface: surface,
      onSurface: text,
      error: danger,
      onError: canvas,
    ),
    textTheme: const TextTheme(
      bodyLarge: TextStyle(color: text),
      bodyMedium: TextStyle(color: muted, fontSize: 12),
      bodySmall: TextStyle(color: muted, fontSize: 10),
      titleLarge: TextStyle(
        color: text,
        fontSize: 16,
        fontWeight: FontWeight.w700,
      ),
      titleMedium: TextStyle(
        color: text,
        fontSize: 13,
        fontWeight: FontWeight.w600,
      ),
      labelLarge: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
    ),
    iconTheme: const IconThemeData(color: muted),
    dividerTheme: const DividerThemeData(color: border, thickness: 1),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: surfaceRaised,
      hintStyle: const TextStyle(color: muted, fontSize: 11),
      prefixIconColor: muted,
      contentPadding: const EdgeInsets.symmetric(horizontal: 11, vertical: 10),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: accent, width: 1.2),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: accent,
        foregroundColor: canvas,
        disabledBackgroundColor: rail,
        disabledForegroundColor: disabled,
        minimumSize: const Size(0, 34),
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 8),
        textStyle: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(13)),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: accent,
        minimumSize: const Size(0, 32),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        textStyle: const TextStyle(fontSize: 10, fontWeight: FontWeight.w600),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
      ),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected) ? canvas : muted,
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected) ? accent : rail,
      ),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: surface,
      textStyle: const TextStyle(color: text, fontSize: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: surface,
      contentTextStyle: const TextStyle(color: text, fontSize: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      behavior: SnackBarBehavior.floating,
    ),
  );
}
