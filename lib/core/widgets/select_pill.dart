import 'package:flutter/material.dart';

import '../theme/app_colors.dart';

/// A selectable order-type / seat pill with guaranteed contrast.
///
/// Selected fill defaults to sky ([AppColors.primary]) to match the Dishflow
/// sell mock; pass [selectedColor] to override (e.g. navy on the floor).
class SelectPill extends StatelessWidget {
  const SelectPill({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.compact = false,
    this.selectedColor = AppColors.primary,
    this.showCheckmark = false,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final bool compact;
  final Color selectedColor;
  final bool showCheckmark;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final bg = selected
        ? selectedColor
        : (dark ? AppColors.backgroundLightDark : Colors.white);
    final fg = selected ? Colors.white : AppColors.brandNavy;
    final border = selected
        ? selectedColor
        : (dark
            ? AppColors.surfaceLightDark
            : const Color(0xFFE2E8F0));

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          curve: Curves.easeOut,
          padding: EdgeInsets.symmetric(
            horizontal: compact ? 10 : 12,
            vertical: compact ? 5 : 7,
          ),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: border, width: 1.2),
            boxShadow: selected && !dark
                ? [
                    BoxShadow(
                      color: selectedColor.withValues(alpha: 0.28),
                      blurRadius: 6,
                      offset: const Offset(0, 2),
                    ),
                  ]
                : null,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (selected && showCheckmark) ...[
                Icon(Icons.check, size: compact ? 14 : 16, color: fg),
                SizedBox(width: compact ? 4 : 5),
              ],
              Text(
                label,
                style: TextStyle(
                  fontSize: compact ? 12.5 : 13,
                  fontWeight: FontWeight.w700,
                  color: fg,
                  height: 1.1,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
