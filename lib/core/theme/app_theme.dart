import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_colors.dart';

/// Dishflow look on the till: fixed sky/navy ColorScheme, Cairo everywhere, and
/// the same soft radii — while keeping touch-sized controls and the floating
/// snackbar that offline POS needs over the sell panel.
abstract final class AppTheme {
  static ThemeData light() => _base(Brightness.light);

  static ThemeData dark() => _base(Brightness.dark);

  /// One corner radius language for the whole till.
  static const double radiusSmall = 14;
  static const double radiusMedium = 16;
  static const double radiusLarge = 20;

  static const String _fontFamily = 'Cairo';

  static ThemeData _base(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    final scheme = dark
        ? const ColorScheme.dark(
            primary: AppColors.primary,
            secondary: AppColors.secondary,
            secondaryContainer: AppColors.secondary,
            onSecondaryContainer: Colors.white,
            surface: AppColors.surfaceDark,
            error: AppColors.error,
            onPrimary: Colors.white,
            onSecondary: Colors.white,
            onSurface: AppColors.textPrimaryDark,
            onError: Colors.white,
          )
        : const ColorScheme.light(
            primary: AppColors.primary,
            secondary: AppColors.secondary,
            secondaryContainer: AppColors.secondary,
            onSecondaryContainer: Colors.white,
            surface: AppColors.surfaceLight,
            error: AppColors.error,
            onPrimary: Colors.white,
            onSecondary: Colors.white,
            onSurface: AppColors.textPrimaryLight,
            onError: Colors.white,
          );

    final onSurface =
        dark ? AppColors.textPrimaryDark : AppColors.textPrimaryLight;
    final cardColor =
        dark ? AppColors.backgroundLightDark : AppColors.backgroundLightLight;
    final scaffold =
        dark ? AppColors.backgroundDark : AppColors.backgroundLight;

    return ThemeData(
      colorScheme: scheme,
      brightness: brightness,
      useMaterial3: true,
      visualDensity: VisualDensity.comfortable,
      fontFamily: _fontFamily,
      primaryColor: AppColors.primary,
      scaffoldBackgroundColor: scaffold,
      textTheme: _textTheme(dark),
      appBarTheme: AppBarTheme(
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: true,
        backgroundColor: Colors.transparent,
        systemOverlayStyle:
            dark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark,
        titleTextStyle: TextStyle(
          fontFamily: _fontFamily,
          fontSize: 20,
          fontWeight: FontWeight.w600,
          color: onSurface,
        ),
        iconTheme: IconThemeData(color: onSurface),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: AppColors.primary,
          foregroundColor: Colors.white,
          minimumSize: const Size(0, 48),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(radiusSmall)),
          textStyle: const TextStyle(
            fontFamily: _fontFamily,
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: AppColors.primary,
          foregroundColor: Colors.white,
          elevation: 0,
          minimumSize: const Size(0, 48),
          padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 18),
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(radiusSmall)),
          textStyle: const TextStyle(
            fontFamily: _fontFamily,
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: AppColors.primary,
          minimumSize: const Size(0, 48),
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(radiusSmall)),
          side: const BorderSide(color: AppColors.primary),
          textStyle: const TextStyle(
            fontFamily: _fontFamily,
            fontSize: 15,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: AppColors.primary,
          minimumSize: const Size(0, 44),
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(radiusSmall)),
          textStyle: const TextStyle(
            fontFamily: _fontFamily,
            fontSize: 14,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
      chipTheme: ChipThemeData(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radiusSmall)),
        // Selected ChoiceChips use secondaryContainer (navy) — label must be white.
        selectedColor: AppColors.secondary,
        checkmarkColor: Colors.white,
        secondarySelectedColor: AppColors.secondary,
        labelStyle: TextStyle(
          fontFamily: _fontFamily,
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: onSurface,
        ),
        secondaryLabelStyle: const TextStyle(
          fontFamily: _fontFamily,
          fontSize: 13,
          fontWeight: FontWeight.w700,
          color: Colors.white,
        ),
        side: BorderSide(
          color: dark ? AppColors.surfaceLightDark : AppColors.secondary.withValues(alpha: 0.35),
        ),
        backgroundColor: dark ? AppColors.backgroundLightDark : AppColors.backgroundLightLight,
      ),
      listTileTheme: const ListTileThemeData(minVerticalPadding: 10),
      cardTheme: CardThemeData(
        elevation: 0,
        color: cardColor,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radiusMedium)),
      ),
      dialogTheme: DialogThemeData(
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radiusLarge)),
        backgroundColor: cardColor,
      ),
      bottomSheetTheme: BottomSheetThemeData(
        shape: const RoundedRectangleBorder(
            borderRadius:
                BorderRadius.vertical(top: Radius.circular(radiusLarge))),
        backgroundColor: cardColor,
        surfaceTintColor: Colors.transparent,
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        width: 400,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radiusSmall)),
      ),
      dividerTheme: DividerThemeData(
        color: dark ? AppColors.surfaceLightDark : AppColors.surfaceLightLight,
      ),
      drawerTheme: DrawerThemeData(
        backgroundColor: cardColor,
        shape: const RoundedRectangleBorder(
            borderRadius: BorderRadiusDirectional.horizontal(
                end: Radius.circular(radiusLarge))),
      ),
      inputDecorationTheme: _inputDecorationTheme(dark),
      checkboxTheme: CheckboxThemeData(
        fillColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) return AppColors.primary;
          return dark ? AppColors.surfaceDark : AppColors.surfaceLight;
        }),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
      ),
    );
  }

  static TextTheme _textTheme(bool isDark) {
    final textColor =
        isDark ? AppColors.textPrimaryDark : AppColors.textPrimaryLight;
    final secondaryColor =
        isDark ? AppColors.textSecondaryDark : AppColors.textSecondaryLight;
    TextStyle base(double size, FontWeight weight, Color color) => TextStyle(
          fontFamily: _fontFamily,
          fontSize: size,
          fontWeight: weight,
          color: color,
        );
    return TextTheme(
      displayLarge: base(32, FontWeight.bold, textColor),
      displayMedium: base(28, FontWeight.bold, textColor),
      displaySmall: base(24, FontWeight.bold, textColor),
      headlineMedium: base(20, FontWeight.w600, textColor),
      titleLarge: base(18, FontWeight.w600, textColor),
      titleMedium: base(16, FontWeight.w500, textColor),
      bodyLarge: base(16, FontWeight.w400, textColor),
      bodyMedium: base(14, FontWeight.w400, secondaryColor),
      labelLarge: base(14, FontWeight.w500, textColor),
    );
  }

  static InputDecorationTheme _inputDecorationTheme(bool isDark) {
    final fillColor =
        isDark ? AppColors.backgroundLightDark : AppColors.backgroundLightLight;
    final borderColor =
        isDark ? AppColors.surfaceDark : AppColors.surfaceLight;
    final labelColor =
        isDark ? AppColors.textSecondaryDark : AppColors.textSecondaryLight;
    final hintColor =
        isDark ? AppColors.textMutedDark : AppColors.textMutedLight;
    return InputDecorationTheme(
      filled: true,
      fillColor: fillColor,
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(radiusSmall),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(radiusSmall),
        borderSide: BorderSide(color: borderColor, width: 1),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(radiusSmall),
        borderSide: const BorderSide(color: AppColors.primary, width: 2),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(radiusSmall),
        borderSide: const BorderSide(color: AppColors.error, width: 1),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(radiusSmall),
        borderSide: const BorderSide(color: AppColors.error, width: 2),
      ),
      labelStyle: TextStyle(
        fontFamily: _fontFamily,
        color: labelColor,
        fontSize: 14,
      ),
      hintStyle: TextStyle(
        fontFamily: _fontFamily,
        color: hintColor,
        fontSize: 14,
      ),
      prefixIconColor: labelColor,
      suffixIconColor: labelColor,
    );
  }

  /// The stored choice as Flutter's own enum. Unset / unrecognised → dark
  /// (Dishflow default), not the device theme.
  static ThemeMode modeOf(String key) => switch (key) {
        'light' => ThemeMode.light,
        'system' => ThemeMode.system,
        _ => ThemeMode.dark,
      };

  /// The keys a manager can choose between, in offer order.
  static const List<String> modeKeys = ['system', 'light', 'dark'];
}
