import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../theme.dart';

/// Which Flash the manager picked — same five as the till.
enum FlashKind {
  collector,
  summary,
  delivery,
  today,
  paymentMethod,
}

Future<FlashKind?> showFlashTypeDialog(BuildContext context,
    {required bool arabic}) {
  return showModalBottomSheet<FlashKind>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: AppColors.navy.withValues(alpha: 0.45),
    builder: (ctx) => _FlashTypeSheet(arabic: arabic),
  );
}

class _FlashTypeSheet extends StatelessWidget {
  const _FlashTypeSheet({required this.arabic});
  final bool arabic;

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.paddingOf(context).bottom;
    final items = <_FlashOption>[
      _FlashOption(
        kind: FlashKind.collector,
        icon: Icons.grid_view_rounded,
        title: 'Flash Collector',
        subtitle:
            arabic ? 'كل الطلبات — كل الأجهزة' : 'All orders — every till',
        accent: AppColors.skyDark,
      ),
      _FlashOption(
        kind: FlashKind.summary,
        icon: Icons.description_outlined,
        title: 'Flash Summary',
        subtitle: arabic ? 'ملخص الفلاش' : 'Flash summary',
        accent: AppColors.navy,
      ),
      _FlashOption(
        kind: FlashKind.delivery,
        icon: Icons.local_shipping_outlined,
        title: 'Delivery Flash',
        subtitle: arabic ? 'توصيل فقط' : 'Delivery flash only',
        accent: const Color(0xFF0284C7),
      ),
      _FlashOption(
        kind: FlashKind.today,
        icon: Icons.payments_outlined,
        title: arabic ? 'فلاش اليوم' : "Today's Flash",
        subtitle: arabic
            ? 'فلاش المحل لليوم — كل الأجهزة'
            : 'Shop flash for today — all tills',
        accent: const Color(0xFFD97706),
      ),
      _FlashOption(
        kind: FlashKind.paymentMethod,
        icon: Icons.account_balance_wallet_outlined,
        title: arabic ? 'فلاش طريقة الدفع' : 'Payment Method Flash',
        subtitle: arabic
            ? 'اختر طريقة دفع وشوف مبيعاتها'
            : 'Pick a payment method and see its sales',
        accent: AppColors.success,
      ),
    ];

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: Container(
        margin: const EdgeInsets.fromLTRB(10, 0, 10, 10),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(28),
          boxShadow: [
            BoxShadow(
              color: AppColors.navy.withValues(alpha: 0.16),
              blurRadius: 28,
              offset: const Offset(0, 10),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 10),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: const Color(0xFFD8E0EA),
                borderRadius: BorderRadius.circular(99),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 14, 10, 4),
              child: Row(
                children: [
                  Container(
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      color: const Color(0xFFFFF7ED),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: const Icon(Icons.bolt_rounded,
                        color: Color(0xFFD97706), size: 22),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          arabic
                              ? 'أنهى فلاش تحتاج؟'
                              : 'Which Flash do you need?',
                          style: GoogleFonts.cairo(
                            fontWeight: FontWeight.w800,
                            fontSize: 16,
                            color: AppColors.navy,
                            height: 1.15,
                          ),
                        ),
                        Text(
                          arabic ? 'اختَر نوع التقرير' : 'Pick the report type',
                          style: GoogleFonts.cairo(
                            fontWeight: FontWeight.w600,
                            fontSize: 12,
                            color: AppColors.muted,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close_rounded),
                    color: AppColors.muted,
                  ),
                ],
              ),
            ),
            Padding(
              padding: EdgeInsets.fromLTRB(14, 8, 14, 12 + bottom),
              child: Column(
                children: [
                  for (final item in items) ...[
                    _FlashTile(option: item),
                    if (item != items.last) const SizedBox(height: 8),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FlashOption {
  const _FlashOption({
    required this.kind,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.accent,
  });

  final FlashKind kind;
  final IconData icon;
  final String title;
  final String subtitle;
  final Color accent;
}

class _FlashTile extends StatelessWidget {
  const _FlashTile({required this.option});
  final _FlashOption option;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFFF5F8FC),
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => Navigator.pop(context, option.kind),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0xFFE2E8F0)),
          ),
          child: Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: option.accent.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(option.icon, color: option.accent, size: 22),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      option.title,
                      style: GoogleFonts.cairo(
                        fontWeight: FontWeight.w800,
                        fontSize: 14.5,
                        color: AppColors.navy,
                        height: 1.15,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      option.subtitle,
                      style: GoogleFonts.cairo(
                        fontWeight: FontWeight.w600,
                        fontSize: 12,
                        color: AppColors.muted,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Icon(
                Icons.chevron_right_rounded,
                color: AppColors.muted.withValues(alpha: 0.7),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
