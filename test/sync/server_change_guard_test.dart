import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/audit/audit_log.dart';
import 'package:offline_pos/core/db/catalogue_store.dart';
import 'package:offline_pos/core/db/database.dart';
import 'package:offline_pos/core/db/settings_store.dart';
import 'package:offline_pos/core/db/sqlite_outbox_store.dart';
import 'package:offline_pos/core/sync/odoo_endpoint.dart';
import 'package:offline_pos/core/sync/server_change_guard.dart';
import 'package:offline_pos/domain/catalogue.dart';

import '../db/sqlite_loader.dart';

/// H5: sales queued for one set of Odoo books are held, not sent, when the till
/// is pointed at another. The owner decides what happens to them.
void main() {
  late Db db;
  late SettingsStore settings;
  late SqliteOutboxStore outbox;
  late CatalogueStore catalogue;
  late AuditLog audit;

  setUpAll(useSystemSqlite);
  setUp(() {
    db = Db.open(':memory:');
    settings = SettingsStore(db);
    outbox = SqliteOutboxStore(db);
    catalogue = CatalogueStore(db);
    audit = AuditLog(db);
    catalogue.replaceAll(
      categories: const [Category(id: 1, name: 'Food')],
      products: const [Product(id: 11, name: 'Burger', price: 50, categoryId: 1)],
      groups: const [],
      productGroupIds: const {},
      refreshedAt: DateTime.now().toUtc(),
    );
  });
  tearDown(() => db.close());

  OdooEndpoint at(String url, String dbName) =>
      OdooEndpoint(baseUrl: url, db: dbName, login: 'pos');

  int save(OdooEndpoint e) => holdSalesOnServerChange(
        endpoint: e,
        settings: settings,
        outbox: outbox,
        catalogue: catalogue,
        audit: audit,
        actor: 'manager',
      );

  test('the first save only records which books these are', () async {
    await outbox.append('order.push', 's-1', {'uuid': 's-1'});

    expect(save(at('https://odoo.shop', 'cairo')), 0);
    expect(outbox.pendingSalesCount, 1);
  });

  test('saving the same server again holds nothing', () async {
    save(at('https://odoo.shop', 'cairo'));
    await outbox.append('order.push', 's-1', {'uuid': 's-1'});

    expect(save(at('https://ODOO.shop/', 'cairo')), 0);
    expect(outbox.pendingSalesCount, 1);
    expect(catalogue.products(), isNotEmpty);
  });

  test('another server holds the queued sales and drops the old menu', () async {
    save(at('https://odoo.shop', 'cairo'));
    await outbox.append('order.push', 's-1', {'uuid': 's-1'});
    await outbox.append('dishflow.sale.push', 's-1', {'uuid': 's-1'});

    final held = save(at('https://odoo.shop', 'balkans'));

    expect(held, 1);
    expect(outbox.pendingSalesCount, 0, reason: 'nothing may go to the new books');
    expect(outbox.refusedCount, 1, reason: 'held sales must stay visible');
    expect(outbox.pendingDishflowCount, 1, reason: 'the owner mirror is not Odoo');
    expect(outbox.dead().single.lastError, contains('server changed'));
    expect(catalogue.products(), isEmpty);
    expect(audit.events(), contains('odoo.server.changed'));
  });

  test('a different branch on the same server is other books too', () async {
    settings.odooBranchId = 7;
    save(at('https://odoo.shop', 'cairo'));
    await outbox.append('order.push', 's-1', {'uuid': 's-1'});
    settings.odooBranchId = 9;

    expect(save(at('https://odoo.shop', 'cairo')), 1);
  });

  test('naming the branch for the first time holds nothing', () async {
    save(at('https://odoo.shop', 'cairo'));
    await outbox.append('order.push', 's-1', {'uuid': 's-1'});
    settings.odooCompanyId = 3;
    settings.odooBranchId = 7;

    expect(save(at('https://odoo.shop', 'cairo')), 0);
    expect(outbox.pendingSalesCount, 1);
  });
}
