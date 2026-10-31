/// What a web account may be given on top of reading its branches' sales. Kept
/// the same as the server's list (`cloud/src/permissions.ts`), which is what
/// decides the data a session can fetch; this only decides what it is shown.
const reportCapabilities = [
  'costs',
  'audit',
  'staff',
  'expenses',
  'backoffice',
  'flash',
];

/// Mobile owner-app screens a non-owner may be given (`report_keys`).
const ownerReportKeys = [
  'sales_summary',
  'sales_detail',
  'costs',
  'order_detail',
  // Session + sales hub (same keys as the till reports tree).
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

Set<String> defaultOwnerReportKeys(String role) => switch (role) {
      'owner' => {...ownerReportKeys},
      'accountant' => {
          'sales_summary',
          'sales_detail',
          'costs',
          'order_detail',
          'rep-session-summary',
          'rep-summary',
          'rep-item-sales',
          'rep-payment',
          'rep-daily-sales',
          'rep-tax',
        },
      _ => {
          'sales_summary',
          'sales_detail',
          'costs',
          'order_detail',
          'rep-session-summary',
          'rep-summary',
          'rep-item-sales',
          'rep-payment',
        },
    };

/// The capability a report needs, by its key, or null for a report every
/// account that can see the branch may open.
String? capabilityForReport(String reportKey) {
  if (reportKey.startsWith('rm-')) return 'backoffice';
  return switch (reportKey) {
    'rep-cost-sales' || 'rep-menu-eng' => 'costs',
    'rep-activity' || 'rep-refunds' => 'audit',
    'rep-hours' => 'staff',
    'rep-expenses' => 'expenses',
    'rep-flash' => 'flash',
    _ => null,
  };
}

bool canOpenReport(String reportKey, Set<String> capabilities) {
  final needed = capabilityForReport(reportKey);
  return needed == null || capabilities.contains(needed);
}
