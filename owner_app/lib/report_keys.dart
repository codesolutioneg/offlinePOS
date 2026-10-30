import 'report_catalog.dart';

/// Mobile owner-app report keys stored on each user (`report_keys`).
const kOwnerReportKeys = <String>[
  // Legacy mobile screens
  'sales_summary',
  'sales_detail',
  'costs',
  'order_detail',
  // Till / website hub reports (session + sales)
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
  'rep-flash',
];

const kOwnerReportLabels = <String, String>{
  'sales_summary': 'Sales summary',
  'sales_detail': 'Sales detail',
  'costs': 'Costs & margins',
  'order_detail': 'Order detail',
};

const kOwnerReportLabelsAr = <String, String>{
  'sales_summary': 'ملخص المبيعات',
  'sales_detail': 'تفاصيل المبيعات',
  'costs': 'التكلفة والهامش',
  'order_detail': 'تفاصيل الطلب',
};

String reportLabel(String key, {required bool arabic}) {
  final hub = ownerReportDef(key);
  if (hub != null) return hub.label(arabic: arabic);
  return (arabic ? kOwnerReportLabelsAr : kOwnerReportLabels)[key] ?? key;
}
