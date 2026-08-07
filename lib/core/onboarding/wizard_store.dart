import '../db/database.dart';
import 'wizard_id.dart';

/// Which coach wizards a cashier has switched off.
///
/// Kept in the database rather than in preferences because it is per cashier: a till
/// is shared, and the closer switching off the sale walkthrough must not take it away
/// from the starter who is on their second shift.
///
/// A wizard is offered whenever there is no row for it, so a wizard added in a later
/// release shows once even to a cashier who dismissed everything that existed before
/// it. That is the reason this is stored per wizard key and not as a single
/// "onboarding done" flag.
class WizardStore {
  WizardStore(this._db, {DateTime Function()? now}) : _now = now ?? DateTime.now;

  final Db _db;
  final DateTime Function() _now;

  bool shouldShow(WizardId id, String cashierId) => _db.raw
      .select(
        'SELECT 1 FROM wizard_dismissals WHERE wizard_id = ? AND cashier_id = ? LIMIT 1',
        [id.key, cashierId],
      )
      .isEmpty;

  /// Records "don't show this again". Dismissing twice is the same as once, because
  /// the control stays on screen for as long as the wizard is open.
  void dismiss(WizardId id, String cashierId) => _db.raw.execute(
        'INSERT INTO wizard_dismissals (wizard_id, cashier_id, dismissed_at) VALUES (?,?,?) '
        'ON CONFLICT(wizard_id, cashier_id) DO UPDATE SET dismissed_at = excluded.dismissed_at',
        [id.key, cashierId, _now().toUtc().toIso8601String()],
      );

  /// Switches off every wizard this build knows about, for an experienced cashier who
  /// does not want to meet them one at a time. Wizards shipped later are not covered,
  /// by design.
  void dismissAll(String cashierId) {
    for (final id in WizardId.values) {
      dismiss(id, cashierId);
    }
  }

  /// Offers the help again. With [cashierId] only that cashier is affected, which is
  /// what a manager wants when a new starter takes over a till whose help was turned
  /// off years ago.
  void reset({String? cashierId}) {
    if (cashierId == null) {
      _db.raw.execute('DELETE FROM wizard_dismissals');
      return;
    }
    _db.raw.execute('DELETE FROM wizard_dismissals WHERE cashier_id = ?', [cashierId]);
  }
}
