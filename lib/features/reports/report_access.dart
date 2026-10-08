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
