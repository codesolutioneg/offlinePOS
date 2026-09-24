import 'package:flutter/material.dart';

import '../../../core/i18n/l10n.dart';
import '../../../core/theme/app_colors.dart';

/// Which Flash the manager picked from the Dishflow-style chooser.
enum FlashKind {
  collector,
  summary,
  delivery,
  today,
  paymentMethod,
}

/// «انهي فلاش تحتاج؟» — pick a Flash type, then the caller builds it from
/// shop-wide LAN orders.
Future<FlashKind?> showFlashTypeDialog(BuildContext context) {
  return showDialog<FlashKind>(
    context: context,
    builder: (ctx) => const _FlashTypeDialog(),
  );
}

class _FlashTypeDialog extends StatelessWidget {
  const _FlashTypeDialog();

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = isDark ? AppColors.backgroundLightDark : const Color(0xFF1B2838);
    final card = isDark ? AppColors.surfaceDark : const Color(0xFF243447);
    final muted = Colors.white70;

    return Dialog(
      backgroundColor: bg,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      insetPadding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420, maxHeight: 560),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
              child: Row(
                children: [
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close, color: Colors.white70),
                  ),
                  const Spacer(),
                  const Icon(Icons.bolt, color: Color(0xFFFBBF24), size: 22),
                  const SizedBox(width: 6),
                  Text(
                    tr(context, 'Which Flash do you need?'),
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w800,
                      fontSize: 17,
                    ),
                  ),
                  const SizedBox(width: 12),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
              child: Align(
                alignment: AlignmentDirectional.centerEnd,
                child: Text(
                  tr(context, 'Pick the report type'),
                  style: TextStyle(color: muted, fontSize: 13),
                ),
              ),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.fromLTRB(14, 0, 14, 16),
                children: [
                  _row(
                    context,
                    card: card,
                    kind: FlashKind.collector,
                    icon: Icons.grid_view_rounded,
                    title: 'Flash Collector',
                    subtitle: tr(context, 'All orders — every till on the network'),
                    accent: AppColors.primaryLight,
                  ),
                  _row(
                    context,
                    card: card,
                    kind: FlashKind.summary,
                    icon: Icons.description_outlined,
                    title: 'Flash Summary',
                    subtitle: tr(context, 'Flash summary'),
                    accent: Colors.white,
                  ),
                  _row(
                    context,
                    card: card,
                    kind: FlashKind.delivery,
                    icon: Icons.local_shipping_outlined,
                    title: 'Delivery Flash',
                    subtitle: tr(context, 'Delivery flash only'),
                    accent: AppColors.primaryLight,
                  ),
                  _row(
                    context,
                    card: card,
                    kind: FlashKind.today,
                    icon: Icons.payments_outlined,
                    title: tr(context, "Today's Flash"),
                    subtitle: tr(context,
                        'Shop flash for today — all tills, prints now'),
                    accent: const Color(0xFFFBBF24),
                    border: const Color(0xFFFBBF24),
                  ),
                  _row(
                    context,
                    card: card,
                    kind: FlashKind.paymentMethod,
                    icon: Icons.account_balance_wallet_outlined,
                    title: tr(context, 'Payment Method Flash'),
                    subtitle: tr(context,
                        'Pick a payment method and see its sales today'),
                    accent: const Color(0xFF4ADE80),
                    border: const Color(0xFF4ADE80),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _row(
    BuildContext context, {
    required Color card,
    required FlashKind kind,
    required IconData icon,
    required String title,
    required String subtitle,
    required Color accent,
    Color? border,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: card,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          key: Key('flash-kind-${kind.name}'),
          borderRadius: BorderRadius.circular(12),
          onTap: () => Navigator.pop(context, kind),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: border == null
                  ? null
                  : Border.all(color: border.withValues(alpha: 0.55)),
            ),
            child: Row(
              children: [
                Icon(Icons.chevron_left, color: accent.withValues(alpha: 0.7)),
                const SizedBox(width: 4),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        title,
                        textAlign: TextAlign.end,
                        style: TextStyle(
                          color: accent,
                          fontWeight: FontWeight.w800,
                          fontSize: 14.5,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        textAlign: TextAlign.end,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.65),
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(icon, color: accent, size: 22),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
