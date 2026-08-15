import 'package:flutter/painting.dart';

import 'app_colors.dart';

/// What free and occupied look like on the floor.
///
/// A shop that reads its floor across a room at a glance is entitled to pick the two
/// colours it reads by: green/red is a convention, not a rule, and it is the wrong
/// one for a manager who cannot tell them apart. Published by [SettingsStore] the way
/// the print profile is, because the floor is drawn deep inside a screen that has no
/// business holding a database handle.
class TablePalette {
  const TablePalette(
      {this.free = AppColors.tableFree, this.occupied = AppColors.tableOccupied});

  /// From what a device stored: a null side keeps the default, so a shop that
  /// changed only "occupied" still reads free as green.
  factory TablePalette.fromArgb({int? free, int? occupied}) => TablePalette(
        free: free == null ? AppColors.tableFree : Color(free),
        occupied: occupied == null ? AppColors.tableOccupied : Color(occupied),
      );

  /// Replaced whole rather than mutated, so a repaint sees one pair or the other.
  static TablePalette shared = const TablePalette();

  final Color free;
  final Color occupied;
}
