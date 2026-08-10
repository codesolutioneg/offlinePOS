// ignore_for_file: avoid_print
// Drives the app's REAL OdooWiring/OdooSender against real staging: enqueue a
// paid order, drain the outbox, and confirm a sale.order was booked in Odoo.
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/db/database.dart';
import 'package:offline_pos/core/db/sqlite_outbox_store.dart';
import 'package:offline_pos/core/sync/odoo_endpoint.dart';
import 'package:offline_pos/core/sync/odoo_wiring.dart';
import 'package:offline_pos/core/sync/outbox.dart';
import 'package:offline_pos/domain/order.dart';
import '../db/sqlite_loader.dart';

void main() {
  const url = String.fromEnvironment('STAGING_URL');
  const dbn = String.fromEnvironment('STAGING_DB');
  const login = String.fromEnvironment('STAGING_LOGIN');
  const pw = String.fromEnvironment('STAGING_PASSWORD');
  setUpAll(useSystemSqlite);

  test('a real paid order pushes through the sender and books in Odoo', () async {
    if (url.isEmpty) { print('SKIPPED: no STAGING_URL'); return; }
    final db = Db.open(':memory:');
    final outbox = Outbox(store: SqliteOutboxStore(db), senders: <String, OutboxSender>{});
    final wiring = OdooWiring(outbox: outbox);
    wiring.configure(OdooEndpoint(baseUrl: url, db: dbn, login: login, password: pw));

    // a real POS product to sell
    final prods = await wiring.catalogueCall('product.product', 'search_read',
        [[['available_in_pos', '=', true]], ['id', 'display_name', 'lst_price']], {'limit': 1});
    final p = (prods as List).first as Map;
    final order = Order(deviceId: 'device-abc', cashierId: 'setup')
      ..lines.add(OrderLine(
          productId: p['id'] as int,
          name: (p['display_name'] ?? '') as String,
          quantity: 1,
          unitPrice: (p['lst_price'] as num).toDouble()))
      ..state = OrderState.paid;

    await outbox.enqueue('order.push', order.uuid, order.toMap());
    final sent = await outbox.drain();
    print('SENT=$sent uuid=${order.uuid} total=${order.total}');
    expect(sent, greaterThan(0));

    // confirm Odoo actually booked it as a sale order, keyed by the client uuid
    final found = await wiring.catalogueCall('sale.order', 'search_read',
        [[['offline_uuid', '=', order.uuid]],
         ['id', 'amount_total', 'offline_device_id', 'state']], {});
    print('ODOO ORDER: $found');
    expect((found as List).isNotEmpty, isTrue,
        reason: 'the order should exist in Odoo after a drain');
    expect((found).first['state'], 'sale',
        reason: 'the sale order should be confirmed, so it reaches sales reports');
    db.close();
  }, timeout: const Timeout(Duration(minutes: 3)));
}
