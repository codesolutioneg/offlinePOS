import 'package:flutter/material.dart';

import '../i18n/l10n.dart';
import '../theme/app_colors.dart';

/// A big touch-first number pad, because a restaurant till is a touch screen and
/// the OS soft keyboard is slow, small and unreliable on POS hardware. Used for
/// every numeric entry: amounts, weights, cash movements and PINs.
class NumericKeypad extends StatelessWidget {
  const NumericKeypad({
    super.key,
    required this.onKey,
    required this.onBackspace,
    this.onClear,
    this.decimal = true,
  });

  /// Called with the digit ('0'-'9') or '.' the cashier pressed.
  final void Function(String key) onKey;
  final VoidCallback onBackspace;

  /// Clears the whole field. Absent hides the C key.
  final VoidCallback? onClear;

  /// Whether to offer the decimal point (off for whole-number entry like PIN/qty).
  final bool decimal;

  @override
  Widget build(BuildContext context) {
    final rows = <List<String>>[
      ['1', '2', '3'],
      ['4', '5', '6'],
      ['7', '8', '9'],
      [decimal ? '.' : 'C', '0', '⌫'],
    ];
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final row in rows)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                for (final k in row)
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: _Key(
                        label: k,
                        onTap: () {
                          if (k == '⌫') {
                            onBackspace();
                          } else if (k == 'C') {
                            onClear?.call();
                          } else {
                            onKey(k);
                          }
                        },
                      ),
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

class _Key extends StatelessWidget {
  const _Key({required this.label, required this.onTap});
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final isAction = label == '⌫' || label == 'C';
    return SizedBox(
      height: 60,
      child: Material(
        color: isAction ? AppColors.error.withValues(alpha: 0.10) : Colors.grey.shade100,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          key: Key('key-$label'),
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Center(
            child: label == '⌫'
                ? const Icon(Icons.backspace_outlined, color: AppColors.error)
                : Text(label,
                    style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w600,
                        color: isAction ? AppColors.error : null)),
          ),
        ),
      ),
    );
  }
}

/// Open a full touch number-pad dialog for one value, with a live display, and
/// return the parsed number (or null on cancel). [title] labels it; [initial]
/// pre-fills; [decimal] allows a fractional entry.
Future<double?> promptNumber(
  BuildContext context, {
  required String title,
  String? initial,
  bool decimal = true,
  String? confirmLabel,
}) {
  var text = initial ?? '';
  return showDialog<double>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setLocal) {
        void key(String k) {
          if (k == '.' && text.contains('.')) return;
          if (k == '.' && text.isEmpty) {
            setLocal(() => text = '0.');
            return;
          }
          setLocal(() => text += k);
        }

        return AlertDialog(
          title: Text(title),
          content: SizedBox(
            width: 320,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                decoration: BoxDecoration(
                  color: Colors.grey.shade50,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.grey.shade300),
                ),
                child: Text(
                  text.isEmpty ? '0' : text,
                  key: const Key('keypad-display'),
                  textAlign: TextAlign.right,
                  style: const TextStyle(fontSize: 30, fontWeight: FontWeight.bold),
                ),
              ),
              const SizedBox(height: 12),
              NumericKeypad(
                decimal: decimal,
                onKey: key,
                onBackspace: () => setLocal(
                    () => text = text.isEmpty ? text : text.substring(0, text.length - 1)),
                onClear: () => setLocal(() => text = ''),
              ),
            ]),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx), child: Text(tr(ctx, 'Cancel'))),
            FilledButton(
              key: const Key('keypad-ok'),
              onPressed: () => Navigator.pop(ctx, double.tryParse(text)),
              child: Text(confirmLabel ?? tr(ctx, 'OK')),
            ),
          ],
        );
      },
    ),
  );
}
