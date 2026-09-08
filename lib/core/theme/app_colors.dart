import 'package:flutter/material.dart';

/// The shared colour language of the till — Dishflow navy + sky brand, plus the
/// status colours the sell screen, floor, and kitchen board already speak.
abstract final class AppColors {
  // Brand — Dishflow navy + sky accent.
  static const brandNavy = Color(0xFF1B2838);
  static const brandNavyLight = Color(0xFF243447);
  static const primary = Color(0xFF0EA5E9); // sky
  static const primaryLight = Color(0xFF38BDF8);
  static const primaryDark = Color(0xFF0284C7);

  // Secondary — deep navy (matches Dishflow).
  static const secondary = Color(0xFF1B2838);
  static const secondaryLight = Color(0xFF334155);
  static const secondaryDark = Color(0xFF0F1419);

  static const accent = Color(0xFF3B82F6);

  // Legacy aliases used across screens (Dishflow light surfaces).
  static const background = Color(0xFFF8FAFC);
  static const surface = Color(0xFFE2E8F0);

  // ===== DARK THEME (Dishflow) =====
  static const backgroundDark = Color(0xFF0F1419);
  static const backgroundLightDark = Color(0xFF1B2838); // cards on dark
  static const surfaceDark = Color(0xFF243447);
  static const surfaceLightDark = Color(0xFF334155);

  static const textPrimaryDark = Color(0xFFF8FAFC);
  static const textSecondaryDark = Color(0xFF94A3B8);
  static const textMutedDark = Color(0xFF64748B);

  // ===== LIGHT THEME (Dishflow) =====
  static const backgroundLight = Color(0xFFF8FAFC);
  static const backgroundLightLight = Color(0xFFFFFFFF); // cards on light
  static const surfaceLight = Color(0xFFE2E8F0);
  static const surfaceLightLight = Color(0xFFCBD5E1);

  static const textPrimaryLight = Color(0xFF1B2838);
  static const textSecondaryLight = Color(0xFF475569);
  static const textMutedLight = Color(0xFF94A3B8);

  // Status.
  static const success = Color(0xFF22C55E); // green  — done / ready / paid
  static const warning = Color(0xFFF59E0B); // amber  — held / attention
  static const error = Color(0xFFEF4444); // red    — refund / void / danger
  static const info = Color(0xFF3B82F6); // blue   — in progress / preparing
  static const pending = Color(0xFFF97316); // orange — queued to sync

  // Order line / order states.
  static const sent = success; // fired to the kitchen
  static const held = warning; // parked on a table
  static const draft = info; // being rung, not sent

  // Modifiers on a line (matches the Odoo/jouma convention).
  static const modifierFree = Color(0xFF16A34A);
  static const modifierPaid = Color(0xFF2563EB);

  // Table occupancy on the floor picker.
  static const tableFree = success;
  static const tableOccupied = error;
  static const tableThis = primary; // the table this order is on

  /// A stable, readable colour for a category tile when the manager has not picked
  /// one, so the grid is never a wall of one colour. Indexed by category id.
  static const categoryPalette = <Color>[
    Color(0xFF0EA5E9),
    Color(0xFF22C55E),
    Color(0xFF3B82F6),
    Color(0xFFEF4444),
    Color(0xFFF59E0B),
    Color(0xFFA855F7),
    Color(0xFF06B6D4),
    Color(0xFFEC4899),
    Color(0xFF84CC16),
    Color(0xFFF97316),
  ];

  static Color categoryColor(int categoryId) =>
      categoryPalette[categoryId.abs() % categoryPalette.length];
}

/// A small pill used across screens to label a status in its colour.
class StatusChip extends StatelessWidget {
  const StatusChip(this.label, this.color, {super.key, this.icon, this.compact = true});

  final String label;
  final Color color;
  final IconData? icon;
  final bool compact;

  @override
  Widget build(BuildContext context) => Container(
        padding: EdgeInsets.symmetric(horizontal: compact ? 7 : 10, vertical: compact ? 2 : 4),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: color.withValues(alpha: 0.5)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (icon != null) ...[
            Icon(icon, size: compact ? 11 : 14, color: color),
            const SizedBox(width: 3),
          ],
          Text(label,
              style: TextStyle(
                  fontSize: compact ? 11 : 13, fontWeight: FontWeight.w700, color: color)),
        ]),
      );
}
