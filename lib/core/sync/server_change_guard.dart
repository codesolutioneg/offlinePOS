import '../audit/audit_log.dart';
import '../db/catalogue_store.dart';
import '../db/settings_store.dart';
import '../db/sqlite_outbox_store.dart';
import 'odoo_endpoint.dart';

/// Which Odoo books a sale is rung against: the server, its database, and the
/// company and branch inside it. The login is left out, because a different user
/// on the same books is still the same books.
String odooServerFingerprint(OdooEndpoint endpoint, {int? companyId, int? branchId}) {
  final url = endpoint.baseUrl.trim().toLowerCase().replaceAll(RegExp(r'/+$'), '');
  return '$url|${endpoint.db.trim()}|${companyId ?? ''}|${branchId ?? ''}';
}

/// Run when the server settings are saved, before the sender is pointed at them.
///
/// Sales queued for one set of books carry that server's product ids, so sent to
/// another they would book the wrong dishes. By the owner's decision they are not
/// deleted and not sent: they are held in the queue, show in the refused count,
/// and wait for a manager to revive or clear them. The old menu is dropped for the
/// same reason, and the next pull brings the new one.
///
/// The first save only records the fingerprint. Returns how many sales were held.
int holdSalesOnServerChange({
  required OdooEndpoint endpoint,
  required SettingsStore settings,
  required SqliteOutboxStore outbox,
  required CatalogueStore catalogue,
  required AuditLog audit,
  required String actor,
}) {
  final now = odooServerFingerprint(endpoint,
      companyId: settings.odooCompanyId, branchId: settings.odooBranchId);
  final before = settings.odooServerFingerprint;
  settings.odooServerFingerprint = now;
  if (before == null || !_otherBooks(before, now)) return 0;
  final held = outbox.holdPendingSales('held: server changed from $before');
  catalogue.forgetPulled();
  audit.record(actor, 'odoo.server.changed', detail: '$before -> $now | held $held');
  return held;
}

/// Whether two fingerprints name different books. A company or branch picked for
/// the first time on the same server is the shop being named, not moved: sales
/// rung before it still belong there and must go out with the new ids.
bool _otherBooks(String before, String now) {
  final a = before.split('|');
  final b = now.split('|');
  if (a.length != 4 || b.length != 4) return before != now;
  for (var i = 0; i < 4; i++) {
    final changed = a[i] != b[i];
    final firstPick = i >= 2 && a[i].isEmpty;
    if (changed && !firstPick) return true;
  }
  return false;
}
