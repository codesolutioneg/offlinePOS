import 'package:flutter/material.dart';

import '../theme/app_colors.dart';

/// The colour of a toast: green for something that succeeded, red for something
/// that failed or was blocked, and a neutral default for everything else. The
/// point is that a cashier reads the outcome from colour first, text second.
enum ToastKind { success, error, info }

/// The one place every snackbar in the app goes through, so success and error
/// always read the same way instead of every screen inventing its own colours.
///
/// [key] and [duration] are exposed because a handful of call sites are asserted
/// on in tests or intentionally shown longer/shorter than the default; the
/// message text itself is never altered by this helper.
void showToast(
  BuildContext context,
  String message, {
  ToastKind kind = ToastKind.info,
  Key? key,
  Duration duration = const Duration(seconds: 3),
}) {
  final icon = switch (kind) {
    ToastKind.success => Icons.check_circle,
    ToastKind.error => Icons.error_outline,
    ToastKind.info => Icons.info,
  };
  // Info keeps the theme's default snackbar colour; success/error override it
  // so the two states a cashier must never confuse are the two that are coloured.
  final Color? background = switch (kind) {
    ToastKind.success => AppColors.success,
    ToastKind.error => AppColors.error,
    ToastKind.info => null,
  };
  final foreground = background == null ? null : Colors.white;
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
    key: key,
    backgroundColor: background,
    duration: duration,
    content: Row(children: [
      Icon(icon, size: 20, color: foreground),
      const SizedBox(width: 10),
      Expanded(child: Text(message, style: TextStyle(color: foreground))),
    ]),
  ));
}

/// A blank screen with nothing to point at is the state a new cashier or an
/// empty report ends up in most often, so it gets an icon, a plain-English
/// reason, and (when there is one) the action that fixes it, rather than a
/// silent white page. Mirrors the floor screen's own empty state.
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.actionLabel,
    this.onAction,
    this.actionIcon,
    this.iconColor,
    this.textColor,
  });

  final IconData icon;
  final String title;

  /// An optional second line giving more context than the headline alone.
  final String? message;

  final String? actionLabel;
  final VoidCallback? onAction;
  final IconData? actionIcon;

  /// Overrides for a dark surface (e.g. the kitchen board), where the muted
  /// greys that read fine on a light background would be invisible.
  final Color? iconColor;
  final Color? textColor;

  @override
  Widget build(BuildContext context) => Center(
        // A scroll view rather than a bare Column: this is dropped into panels of
        // very different heights (a full report screen, a narrow order sidebar, a
        // small section card), and one that is too short for the icon + two lines
        // of text should scroll rather than overflow and paint the debug banner.
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 56, color: iconColor ?? Colors.black26),
              const SizedBox(height: 12),
              Text(
                title,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: textColor),
              ),
              if (message != null) ...[
                const SizedBox(height: 6),
                Text(
                  message!,
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 13, color: textColor ?? Colors.black54),
                ),
              ],
              if (actionLabel != null && onAction != null) ...[
                const SizedBox(height: 16),
                actionIcon != null
                    ? FilledButton.icon(
                        onPressed: onAction,
                        icon: Icon(actionIcon),
                        label: Text(actionLabel!),
                      )
                    : FilledButton(onPressed: onAction, child: Text(actionLabel!)),
              ],
            ],
          ),
        ),
      );
}

