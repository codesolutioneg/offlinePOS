import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Dishflow brand colours for the owner mobile app.
abstract final class AppColors {
  static const navy = Color(0xFF1B2838);
  static const navyLight = Color(0xFF243447);
  static const sky = Color(0xFF0EA5E9);
  static const skyLight = Color(0xFF38BDF8);
  static const skyDark = Color(0xFF0284C7);
  static const background = Color(0xFFF3F6FA);
  static const surface = Color(0xFFFFFFFF);
  static const border = Color(0xFFE2E8F0);
  static const text = Color(0xFF1B2838);
  static const muted = Color(0xFF64748B);
  static const danger = Color(0xFFDC2626);
  static const success = Color(0xFF059669);
}

ThemeData ownerTheme() {
  final textTheme = GoogleFonts.cairoTextTheme();
  final base = ThemeData(
    useMaterial3: true,
    colorScheme: ColorScheme.fromSeed(
      seedColor: AppColors.sky,
      primary: AppColors.skyDark,
      secondary: AppColors.navy,
      surface: AppColors.surface,
    ).copyWith(
      // Seed schemes often pick an amber tertiary that shows as a yellow
      // focus/autofill wash on text fields.
      tertiary: AppColors.sky,
      onTertiary: Colors.white,
      tertiaryContainer: const Color(0xFFE0F2FE),
      surfaceTint: Colors.transparent,
    ),
    scaffoldBackgroundColor: AppColors.background,
    focusColor: AppColors.sky.withValues(alpha: 0.12),
    hoverColor: Colors.transparent,
    splashColor: AppColors.sky.withValues(alpha: 0.08),
    highlightColor: Colors.transparent,
    textTheme: textTheme.apply(
      bodyColor: AppColors.text,
      displayColor: AppColors.navy,
    ),
  );
  return base.copyWith(
    appBarTheme: AppBarTheme(
      backgroundColor: AppColors.background,
      foregroundColor: AppColors.navy,
      elevation: 0,
      scrolledUnderElevation: 0,
      surfaceTintColor: Colors.transparent,
      centerTitle: false,
      titleTextStyle: GoogleFonts.cairo(
        color: AppColors.navy,
        fontWeight: FontWeight.w800,
        fontSize: 18,
      ),
      iconTheme: const IconThemeData(color: AppColors.navy),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: AppColors.skyDark,
        foregroundColor: Colors.white,
        textStyle: GoogleFonts.cairo(fontWeight: FontWeight.w700, fontSize: 16),
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 20),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Colors.white,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      labelStyle: GoogleFonts.cairo(color: AppColors.muted),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: AppColors.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: AppColors.skyDark, width: 1.5),
      ),
    ),
    cardTheme: CardThemeData(
      color: AppColors.surface,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: AppColors.border),
      ),
    ),
  );
}
