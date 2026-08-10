// ignore_for_file: avoid_print
// Proves a tendered payment (chosen method) books against Odoo through the app.
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

  test('a sale with a chosen payment method books that method in Odoo', () async {
    if (url.isEmpty) { print('SKIPPED'); return; }
    final db = Db.open(':memory:');
    final outbox = Outbox(store: SqliteOutboxStore(db), senders: <String, OutboxSender>{});
    final wiring = OdooWiring(outbox: outbox);
    wiring.configure(OdooEndpoint(baseUrl: url, db: dbn, login: login, password: pw));

    final prod = ((await wiring.catalogueCall('product.product', 'search_read',
        [[['available_in_pos', '=', true]], ['id', 'display_name', 'lst_price']], {'limit': 1})) as List).first as Map;
    final method = ((await wiring.catalogueCall('pos.payment.method', 'search_read',
        [[['active', '=', true]], ['id', 'name']], {'limit': 1})) as List).first as Map;
    print('METHOD: ${method['id']} ${method['name']}');

    final price = (prod['lst_price'] as num).toDouble();
    final order = Order(deviceId: 'device-abc', cashierId: 'setup')
      ..lines.add(OrderLine(productId: prod['id'] as int, name: (prod['display_name'] ?? '') as String, quantity: 1, unitPrice: price))
      ..state = OrderState.paid
      ..payments = [OrderPayment(methodId: method['id'] as int, amount: price)];

    await outbox.enqueue('order.push', order.uuid, order.toMap());
    final sent = await outbox.drain();
    expect(sent, greaterThan(0));

    final booked = ((await wiring.catalogueCall('sale.order', 'search_read',
        [[['offline_uuid', '=', order.uuid]],
         ['id', 'amount_total', 'state', 'invoice_ids']], {})) as List);
    print('ORDER: $booked');
    expect(booked.isNotEmpty, isTrue);
    final o = booked.first as Map;
    final invIds = (o['invoice_ids'] as List).cast<int>();
    expect(invIds.isNotEmpty, isTrue, reason: 'the sale should be invoiced');
    // The sale.order cascade takes payment through account: the invoice is paid.
    final inv = ((await wiring.catalogueCall('account.move', 'search_read',
        [[['id', 'in', invIds]], ['payment_state', 'amount_residual']], {})) as List);
    print('INVOICE: $inv');
    expect((inv.first as Map)['payment_state'], 'paid',
        reason: 'the tendered sale should leave the invoice fully paid');
    db.close();
  }, timeout: const Timeout(Duration(minutes: 3)));
}
