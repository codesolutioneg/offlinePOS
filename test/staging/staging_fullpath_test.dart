// ignore_for_file: avoid_print
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/db/catalogue_store.dart';
import 'package:offline_pos/core/db/database.dart';
import 'package:offline_pos/core/db/sqlite_outbox_store.dart';
import 'package:offline_pos/core/sync/odoo_endpoint.dart';
import 'package:offline_pos/core/sync/odoo_puller.dart';
import 'package:offline_pos/core/sync/odoo_wiring.dart';
import 'package:offline_pos/core/sync/outbox.dart';
import '../db/sqlite_loader.dart';

void main() {
  const url = String.fromEnvironment('STAGING_URL');
  const dbn = String.fromEnvironment('STAGING_DB');
  const login = String.fromEnvironment('STAGING_LOGIN');
  const pw = String.fromEnvironment('STAGING_PASSWORD');
  setUpAll(useSystemSqlite);

  test('configure -> catalogueCall -> pull -> store -> read gives products', () async {
    if (url.isEmpty) { print('SKIPPED: no STAGING_URL'); return; }
    final db = Db.open(':memory:');
    final cat = CatalogueStore(db);
    final wiring = OdooWiring(outbox: Outbox(store: SqliteOutboxStore(db), senders: <String, OutboxSender>{}));
    wiring.configure(OdooEndpoint(baseUrl: url, db: dbn, login: login, password: pw));
    final pull = await OdooPuller(call: wiring.catalogueCall).pull();
    print('PULLED products=${pull.products.length} usable=${pull.isUsable}');
    cat.replaceAll(
      categories: pull.categories, products: pull.products,
      groups: pull.groups, productGroupIds: pull.productGroupIds,
      refreshedAt: DateTime.now().toUtc());
    final stored = cat.products();
    print('STORED-AND-READ products=${stored.length} first=${stored.isNotEmpty ? stored.first.name : "-"}');
    expect(stored.length, greaterThan(0));
    db.close();
  }, timeout: const Timeout(Duration(minutes: 3)));
}
