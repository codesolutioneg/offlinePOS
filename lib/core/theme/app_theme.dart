import 'package:flutter/material.dart';

/// The two themes the till runs in, built from one description so the dark one is
/// the light one with the lights off rather than a second design nobody maintains.
///
/// Tuned for a touch screen either way: comfortable spacing, and buttons and inputs
/// tall enough to hit reliably with a finger in a rush.
abstract final class AppTheme {
  static ThemeData light() => _base(Brightness.light);

  static ThemeData dark() => _base(Brightness.dark);

  static ThemeData _base(Brightness brightness) => ThemeData(
        // The seed the till has always been built from, so the light theme is exactly
        // the one the shop is used to and the dark one is its own reading of it.
        colorSchemeSeed: Colors.teal,
        brightness: brightness,
        useMaterial3: true,
        visualDensity: VisualDensity.comfortable,
        filledButtonTheme: FilledButtonThemeData(
            style: FilledButton.styleFrom(minimumSize: const Size(0, 48))),
        outlinedButtonTheme: OutlinedButtonThemeData(
            style: OutlinedButton.styleFrom(minimumSize: const Size(0, 48))),
        chipTheme: const ChipThemeData(
            padding: EdgeInsets.symmetric(horizontal: 10, vertical: 8)),
        listTileTheme: const ListTileThemeData(minVerticalPadding: 10),
      );

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
