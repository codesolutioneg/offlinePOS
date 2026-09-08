import 'package:flutter/material.dart';

import '../theme/app_colors.dart';

/// A selectable order-type / seat pill with guaranteed contrast.
///
/// Material [ChoiceChip] merges theme label colours in a way that can leave
/// dark text on the navy selected fill — this widget paints the label colour
/// explicitly so selected = white, unselected = navy.
class SelectPill extends StatelessWidget {
  const SelectPill({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.compact = false,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final bg = selected
        ? AppColors.secondary
        : (dark ? AppColors.backgroundLightDark : Colors.white);
    final fg = selected ? Colors.white : AppColors.brandNavy;

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
            border: Border.all(
              color: selected
                  ? AppColors.secondary
                  : AppColors.secondary.withValues(alpha: 0.35),
              width: 1.2,
            ),
            boxShadow: selected && !dark
                ? [
                    BoxShadow(
                      color: AppColors.brandNavy.withValues(alpha: 0.18),
                      blurRadius: 6,
                      offset: const Offset(0, 2),
                    ),
                  ]
                : null,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (selected) ...[
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
