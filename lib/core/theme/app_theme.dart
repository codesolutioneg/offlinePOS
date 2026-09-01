import 'package:flutter/material.dart';

import 'app_colors.dart';

/// The two themes the till runs in, built from one description so the dark one is
/// the light one with the lights off rather than a second design nobody maintains.
///
/// Tuned for a touch screen either way: comfortable spacing, buttons and inputs
/// tall enough to hit reliably with a finger in a rush, and one shape language
/// (soft 12-14px corners) so every screen reads as the same till.
abstract final class AppTheme {
  static ThemeData light() => _base(Brightness.light);

  static ThemeData dark() => _base(Brightness.dark);

  /// One corner radius language for the whole till. Buttons and inputs share the
  /// small one; cards and tiles the middle one; dialogs and sheets the large one.
  static const double radiusSmall = 12;
  static const double radiusMedium = 14;
  static const double radiusLarge = 20;

  static ThemeData _base(Brightness brightness) {
    // The seed the till has always been built from, so the light theme is exactly
    // the palette the shop is used to and the dark one is its own reading of it.
    final scheme = ColorScheme.fromSeed(
      seedColor: AppColors.primary,
      brightness: brightness,
    );
    final dark = brightness == Brightness.dark;
    return ThemeData(
      colorScheme: scheme,
      brightness: brightness,
      useMaterial3: true,
      visualDensity: VisualDensity.comfortable,
      scaffoldBackgroundColor: dark ? scheme.surface : scheme.surfaceContainerLowest,
      appBarTheme: AppBarTheme(
        elevation: 0,
        scrolledUnderElevation: 1,
        backgroundColor: dark ? scheme.surfaceContainer : scheme.surface,
        titleTextStyle: TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.w700,
          color: scheme.onSurface,
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(0, 48),
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(radiusSmall)),
          textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(0, 48),
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(radiusSmall)),
          textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          minimumSize: const Size(0, 44),
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(radiusSmall)),
          textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
      ),
      chipTheme: ChipThemeData(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radiusSmall)),
        labelStyle: TextStyle(
            fontSize: 13, fontWeight: FontWeight.w600, color: scheme.onSurface),
      ),
      listTileTheme: const ListTileThemeData(minVerticalPadding: 10),
      cardTheme: CardThemeData(
        elevation: dark ? 0 : 1,
        shadowColor: Colors.black26,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radiusMedium)),
        // Cards sit on the slightly darker scaffold, so they read as raised
        // surfaces without heavy shadows.
        color: dark ? scheme.surfaceContainerHigh : scheme.surface,
      ),
      dialogTheme: DialogThemeData(
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radiusLarge)),
        backgroundColor: dark ? scheme.surfaceContainerHigh : scheme.surface,
      ),
      bottomSheetTheme: BottomSheetThemeData(
        shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(radiusLarge))),
        backgroundColor: dark ? scheme.surfaceContainerHigh : scheme.surface,
        surfaceTintColor: Colors.transparent,
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        // A fixed width, centred: a toast that spans the whole bottom edge sits
        // on the Pay button now that the order panel reaches the true bottom.
        // Centred at 400 it hovers over the product grid instead.
        width: 400,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radiusSmall)),
      ),
      dividerTheme: DividerThemeData(color: scheme.outlineVariant),
      drawerTheme: const DrawerThemeData(
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadiusDirectional.horizontal(
                end: Radius.circular(radiusLarge))),
      ),
    );
  }

  /// The stored choice as Flutter's own enum. Anything unrecognised follows the
  /// device, which is what a till with no preference should do.
  static ThemeMode modeOf(String key) => switch (key) {
        'light' => ThemeMode.light,
        'dark' => ThemeMode.dark,
        _ => ThemeMode.system,
      };

  /// The keys a manager can choose between, in offer order.
  static const List<String> modeKeys = ['system', 'light', 'dark'];
}
