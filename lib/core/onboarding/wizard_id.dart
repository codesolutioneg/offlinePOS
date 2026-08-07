/// The coach wizards this build can offer.
///
/// [key] is what gets written to disk when a cashier switches a wizard off, so it is
/// part of the on-disk contract and not a label. Renaming one resurrects help a
/// cashier already turned off; reusing one hides help they have never seen. Once a
/// key has shipped it is frozen: add a value, never repurpose a key.
enum WizardId {
  /// Signing in for the first time on this till.
  firstSignIn('first_sign_in'),

  /// Ringing up and paying for the first order.
  firstSale('first_sale'),

  /// Choosing options on a product that has modifier groups.
  modifiers('modifiers'),

  /// Reading the diagnostics screen out to support.
  diagnostics('diagnostics'),

  /// Pointing the till at a receipt or kitchen printer.
  printerSetup('printer_setup');

  const WizardId(this.key);

  final String key;
}
