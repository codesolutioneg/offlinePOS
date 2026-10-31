import 'package:flutter/material.dart';

import 'theme.dart';

/// One report entry in the owner hub (same keys as the till reports hub).
class OwnerReportDef {
  const OwnerReportDef({
    required this.key,
    required this.labelEn,
    required this.labelAr,
    required this.icon,
    required this.color,
  });

  final String key;
  final String labelEn;
  final String labelAr;
  final IconData icon;
  final Color color;

  String label({required bool arabic}) => arabic ? labelAr : labelEn;
}

class OwnerReportGroup {
  const OwnerReportGroup({
    required this.titleEn,
    required this.titleAr,
    required this.keys,
  });

  final String titleEn;
  final String titleAr;
  final List<String> keys;

  String title({required bool arabic}) => arabic ? titleAr : titleEn;
}

/// Session + Sales reports matching the website / till hub.
const kOwnerReportDefs = <OwnerReportDef>[
  // Session
  OwnerReportDef(
    key: 'rep-session-summary',
    labelEn: 'Session summary',
    labelAr: 'ملخص السيشن',
    icon: Icons.summarize_outlined,
    color: Color(0xFF9333EA),
  ),
  OwnerReportDef(
    key: 'rep-session-detail',
    labelEn: 'Session detail',
    labelAr: 'تفاصيل السيشن',
    icon: Icons.receipt_long,
    color: Color(0xFF2563EB),
  ),
  OwnerReportDef(
    key: 'rep-item-sales',
    labelEn: 'Item sales',
    labelAr: 'مبيعات الأصناف',
    icon: Icons.grid_on_rounded,
    color: Color(0xFF06B6D4),
  ),
  OwnerReportDef(
    key: 'rep-detailed-discounts',
    labelEn: 'Detailed discounts',
    labelAr: 'تفاصيل الخصومات',
    icon: Icons.discount,
    color: Color(0xFFF59E0B),
  ),
  OwnerReportDef(
    key: 'rep-time',
    labelEn: 'Sales by hour',
    labelAr: 'المبيعات بالساعة',
    icon: Icons.schedule,
    color: Color(0xFF64748B),
  ),
  OwnerReportDef(
    key: 'rep-expenses',
    labelEn: 'Expenses',
    labelAr: 'المصروفات',
    icon: Icons.bolt,
    color: Color(0xFFDC2626),
  ),
  OwnerReportDef(
    key: 'rep-refunds',
    labelEn: 'Refunds & voids',
    labelAr: 'المرتجعات والإلغاء',
    icon: Icons.undo,
    color: AppColors.danger,
  ),
  OwnerReportDef(
    key: 'rep-activity',
    labelEn: 'Cancelled, voided & refunded',
    labelAr: 'ملغي ومرتجع',
    icon: Icons.gpp_bad,
    color: AppColors.danger,
  ),
  OwnerReportDef(
    key: 'rep-driver',
    labelEn: 'Driver sales analysis',
    labelAr: 'تحليل مبيعات الطيارين',
    icon: Icons.delivery_dining,
    color: Color(0xFF10B981),
  ),
  OwnerReportDef(
    key: 'rep-driver-account',
    labelEn: 'Driver account',
    labelAr: 'حساب الطيار',
    icon: Icons.person_pin_circle_outlined,
    color: Color(0xFF059669),
  ),
  OwnerReportDef(
    key: 'rep-payment',
    labelEn: 'Payment analysis',
    labelAr: 'تحليل المدفوعات',
    icon: Icons.account_balance_wallet_outlined,
    color: Color(0xFF0D9488),
  ),
  // Sales
  OwnerReportDef(
    key: 'rep-summary',
    labelEn: 'Sales summary',
    labelAr: 'ملخص المبيعات',
    icon: Icons.summarize,
    color: Color(0xFF2563EB),
  ),
  OwnerReportDef(
    key: 'rep-tax',
    labelEn: 'Tax',
    labelAr: 'الضريبة',
    icon: Icons.receipt,
    color: Color(0xFF3B82F6),
  ),
  OwnerReportDef(
    key: 'rep-group-sales',
    labelEn: 'Group sales',
    labelAr: 'مبيعات المجموعات',
    icon: Icons.grid_view_rounded,
    color: Color(0xFF9333EA),
  ),
  OwnerReportDef(
    key: 'rep-revenue-center',
    labelEn: 'Sales by revenue center',
    labelAr: 'المبيعات حسب مركز الإيراد',
    icon: Icons.storefront,
    color: Color(0xFF06B6D4),
  ),
  OwnerReportDef(
    key: 'rep-daily-sales',
    labelEn: 'Daily sales',
    labelAr: 'المبيعات اليومية',
    icon: Icons.calendar_month,
    color: Color(0xFF14B8A6),
  ),
  OwnerReportDef(
    key: 'rep-top',
    labelEn: 'Top products',
    labelAr: 'أفضل الأصناف',
    icon: Icons.star,
    color: Color(0xFF0EA5E9),
  ),
  OwnerReportDef(
    key: 'rep-category',
    labelEn: 'Category performance',
    labelAr: 'أداء الفئات',
    icon: Icons.category,
    color: Color(0xFF6366F1),
  ),
  OwnerReportDef(
    key: 'rep-discounts',
    labelEn: 'Discounts',
    labelAr: 'الخصومات',
    icon: Icons.percent,
    color: Color(0xFFF59E0B),
  ),
  OwnerReportDef(
    key: 'rep-refunds-summary',
    labelEn: 'Refunds summary',
    labelAr: 'ملخص المرتجعات',
    icon: Icons.assignment_return,
    color: AppColors.danger,
  ),
  OwnerReportDef(
    key: 'rep-modifiers',
    labelEn: 'Modifiers',
    labelAr: 'الإضافات',
    icon: Icons.tune,
    color: Color(0xFFA855F7),
  ),
  OwnerReportDef(
    key: 'rep-period-compare',
    labelEn: 'Period comparison',
    labelAr: 'مقارنة الفترة',
    icon: Icons.compare_arrows,
    color: Color(0xFF475569),
  ),
  OwnerReportDef(
    key: 'rep-flash',
    labelEn: 'Flash reports',
    labelAr: 'تقارير الفلاش',
    icon: Icons.bolt,
    color: Color(0xFFF59E0B),
  ),
];

const kOwnerReportGroups = <OwnerReportGroup>[
  OwnerReportGroup(
    titleEn: 'Session Reports',
    titleAr: 'تقارير السيشن',
    keys: [
      'rep-session-summary',
      'rep-session-detail',
      'rep-item-sales',
      'rep-detailed-discounts',
      'rep-time',
      'rep-expenses',
      'rep-refunds',
      'rep-activity',
      'rep-driver',
      'rep-driver-account',
      'rep-payment',
    ],
  ),
  OwnerReportGroup(
    titleEn: 'Sales Reports',
    titleAr: 'تقارير المبيعات',
    keys: [
      'rep-summary',
      'rep-tax',
      'rep-group-sales',
      'rep-revenue-center',
      'rep-daily-sales',
      'rep-top',
      'rep-category',
      'rep-discounts',
      'rep-refunds-summary',
      'rep-modifiers',
      'rep-period-compare',
    ],
  ),
  OwnerReportGroup(
    titleEn: 'POS Reports',
    titleAr: 'تقارير نقطة البيع',
    keys: ['rep-flash'],
  ),
];

OwnerReportDef? ownerReportDef(String key) {
  for (final d in kOwnerReportDefs) {
    if (d.key == key) return d;
  }
  return null;
}

/// Reports that must keep refund / cancel rows (not stripped).
const kRefundReportKeys = {
  'rep-refunds',
  'rep-activity',
  'rep-refunds-summary',
};
