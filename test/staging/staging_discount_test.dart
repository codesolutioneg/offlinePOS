// ignore_for_file: avoid_print
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

  test('a 25% order discount books the reduced total in Odoo', () async {
    if (url.isEmpty) { print('SKIPPED'); return; }
    final db = Db.open(':memory:');
    final outbox = Outbox(store: SqliteOutboxStore(db), senders: <String, OutboxSender>{});
    final wiring = OdooWiring(outbox: outbox);
    wiring.configure(OdooEndpoint(baseUrl: url, db: dbn, login: login, password: pw));
    // a product with a non-trivial price so the discount is visible
    final prod = ((await wiring.catalogueCall('product.product', 'search_read',
        [[['available_in_pos', '=', true], ['lst_price', '>', 20]],
         ['id', 'display_name', 'lst_price']], {'limit': 1})) as List).first as Map;
    final price = (prod['lst_price'] as num).toDouble();
    final order = Order(deviceId: 'device-abc', cashierId: 'setup')
      ..lines.add(OrderLine(productId: prod['id'] as int, name: (prod['display_name'] ?? '') as String, quantity: 2, unitPrice: price))
      ..discountPercent = 25
      ..state = OrderState.paid;
    final expected = price * 2 * 0.75;
    print('PRICE=$price qty=2 expectedTotal=$expected localTotal=${order.total}');
    await outbox.enqueue('order.push', order.uuid, order.toServerPayload());
    expect(await outbox.drain(), greaterThan(0));
    final booked = ((await wiring.catalogueCall('pos.order', 'search_read',
        [[['uuid', '=', order.uuid]], ['amount_total']], {})) as List).first as Map;
    print('ODOO amount_total=${booked['amount_total']}');
    expect(((booked['amount_total'] as num) - expected).abs() < 0.05, isTrue,
        reason: 'Odoo should book the 25%-discounted total');
    db.close();
  }, timeout: const Timeout(Duration(minutes: 3)));
}
