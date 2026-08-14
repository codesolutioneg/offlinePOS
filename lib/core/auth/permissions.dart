/// The privileged actions a role can be allowed to perform without stopping to ask
/// a manager.
///
/// A role's permission set says what it may do on its own; anything outside that set
/// still works, but falls back to the manager-PIN elevation dialog. Each value
/// carries a stable string [key] (what is stored on disk and audited) plus a short
/// human [label] and one-line [description] for the config screen. The label and
/// description are English source strings, translated at the call site through
/// `tr(...)`.
enum Permission {
  applyDiscount('apply_discount', 'Apply discount', 'Take a percentage off an order or a line'),
  voidLine('void_line', 'Void a line', 'Remove an item from an open order'),
  cancelOrder('cancel_order', 'Cancel order', 'Discard a whole parked or open order'),
  amendOrder('amend_order', 'Edit a paid order', 'Put a paid sale back on the counter before it syncs'),
  refund('refund', 'Refund', 'Return money against a past sale'),
  reprint('reprint', 'Reprint receipt', 'Print another copy of a receipt'),
  openDrawer('open_drawer', 'Open cash drawer', 'Kick the drawer open without a sale'),
  priceOverride('price_override', 'Price override', 'Change a price or an item\'s availability at the till'),
  closeShift('close_shift', 'Close shift', 'Cash up and end the shift'),
  manageStaff('manage_staff', 'Manage staff', 'Add, edit or remove cashiers'),
  managePrinters('manage_printers', 'Manage printers', 'Configure printers and kitchen routing'),
  openSettings('open_settings', 'Open settings', 'Change shop, receipt and server settings'),
  viewReports('view_reports', 'View reports', 'See sales and activity reports');

  const Permission(this.key, this.label, this.description);

  /// The stable identifier stored on disk and written to the audit log. Never
  /// derived from [name], so renaming an enum value cannot silently drop a saved
  /// permission.
  final String key;

  /// A short human name for the config screen.
  final String label;

  /// A one-line explanation of what the permission covers.
  final String description;

  /// The permission with this [key], or null if none matches. The inverse of [key],
  /// used to decode a stored set back into permissions.
  static Permission? fromKey(String key) {
    for (final p in Permission.values) {
      if (p.key == key) return p;
    }
    return null;
  }
}
