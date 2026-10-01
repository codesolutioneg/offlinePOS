import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/app/pos_session.dart';
import 'package:offline_pos/core/audit/audit_log.dart';
import 'package:offline_pos/core/db/catalogue_store.dart';
import 'package:offline_pos/core/db/database.dart';
import 'package:offline_pos/core/db/order_store.dart';
import 'package:offline_pos/core/db/sqlite_outbox_store.dart';
import 'package:offline_pos/core/sync/ecommerce_order_mapper.dart';
import 'package:offline_pos/core/sync/ecommerce_orders_client.dart';
import 'package:offline_pos/core/sync/outbox.dart';
import 'package:offline_pos/domain/catalogue.dart';
import 'package:offline_pos/domain/ecommerce_order.dart';
import 'package:offline_pos/domain/order.dart';

import '../db/sqlite_loader.dart';

void main() {
  late Db db;
  late CatalogueStore catalogue;
  late PosSession session;

  setUpAll(useSystemSqlite);

  setUp(() {
    db = Db.open(':memory:');
    catalogue = CatalogueStore(db);
    catalogue.replaceAll(
      categories: const [Category(id: 1, name: 'Food')],
      products: const [Product(id: 10, name: 'Burger', price: 50, categoryId: 1)],
      groups: const [],
      productGroupIds: const {},
    );
    session = PosSession(
      catalogue: catalogue,
      orders: OrderStore(db),
      outbox: Outbox(store: SqliteOutboxStore(db), senders: const {}),
      audit: AuditLog(db),
      deviceId: 'till1',
      cashierId: 'c1',
    );
  });

  tearDown(() => db.close());

  test('parser reads mobile ecommerce_orders shape', () {
    final order = EcommerceOrderParser.fromMap('doc1', {
      'status': 'pending',
      'orderNumber': '42',
      'customer_name': 'Ali',
      'customer_phone': '0100',
      'delivery_address': 'Nasr City',
      'order_type': 'delivery',
      'branchId': 'b1',
      'deliveryFee': 15,
      'serviceFee': 2,
      'discount': 5,
      'totalAmount': 112,
      'items': [
        {
          'name': 'Burger',
          'quantity': 2,
          'price_unit': 50,
          'product_id': 10,
          'notes': 'no onion',
          'modifiers': [
            {'option_name': 'Cheese', 'price_extra': 7},
          ],
        },
      ],
    });
    expect(order.id, 'doc1');
    expect(order.isPending, isTrue);
    expect(order.isDelivery, isTrue);
    expect(order.customerName, 'Ali');
    expect(order.items.single.productId, 10);
    expect(order.items.single.modifiers.single.name, 'Cheese');
  });

  test('pickup order_type is not delivery', () {
    final order = EcommerceOrderParser.fromMap('p1', {
      'status': 'pending',
      'order_type': 'pickup',
      'items': const [],
    });
    expect(order.isDelivery, isFalse);
  });

  test('mapper loads bag onto session with ecommerceOrderId', () {
    final ecom = EcommerceOrder(
      id: 'ecom-9',
      status: 'pending',
      orderNumber: '9',
      customerName: 'Mona',
      customerPhone: '0111',
      deliveryAddress: 'Maadi',
      deliveryFee: 20,
      items: const [
        EcommerceOrderItem(
          name: 'Burger',
          quantity: 1,
          unitPrice: 50,
          productId: 10,
          notes: 'well done',
          modifiers: [EcommerceOrderModifier(name: 'Cheese', priceExtra: 7)],
        ),
        EcommerceOrderItem(
          name: 'Unknown Wrap',
          quantity: 1,
          unitPrice: 30,
          productId: 999,
        ),
      ],
    );
    EcommerceOrderMapper.applyToSession(
      session: session,
      catalogue: catalogue,
      order: ecom,
    );
    final o = session.current;
    expect(o.ecommerceOrderId, 'ecom-9');
    expect(o.type, OrderType.storeDelivery);
    expect(o.customerName, 'Mona');
    expect(o.deliveryCost, 20);
    expect(o.note, 'Store #9');
    expect(o.lines, hasLength(2));
    expect(o.lines.first.name, 'Burger');
    expect(o.lines.first.note, 'well done');
    expect(o.lines.first.modifiers.single.name, 'Cheese');
    expect(o.lines.first.taxRate, EcommerceOrderMapper.storeVatPercent);
    expect(o.lines.last.name, 'Unknown Wrap');
    expect(o.lines.last.productId, 999);
  });

  test('mapper prefers ticket unit price and adds store VAT', () {
    // Catalogue burger is 50; ticket says 70 — Pay must follow the phone.
    final ecom = EcommerceOrder(
      id: 'ecom-price',
      status: 'pending',
      deliveryFee: 20,
      items: const [
        EcommerceOrderItem(
          name: 'Frank Beef',
          quantity: 2,
          unitPrice: 70,
          productId: 10,
        ),
      ],
    );
    EcommerceOrderMapper.applyToSession(
      session: session,
      catalogue: catalogue,
      order: ecom,
    );
    final o = session.current;
    expect(o.lines.single.unitPrice, 70);
    expect(o.lines.single.quantity, 2);
    expect(o.subtotal, 140);
    expect(o.deliveryCost, 20);
    expect(o.taxTotal, closeTo(19.6, 0.01)); // 14% of 140
    expect(o.total, closeTo(179.6, 0.01));
  });

  test('customerTotal matches mobile checkout (net + delivery + VAT)', () {
    const ecom = EcommerceOrder(
      id: 't1',
      status: 'pending',
      deliveryFee: 20,
      // Stale Firebase total must not win over the computed customer total.
      totalAmount: 159.98,
      items: [
        EcommerceOrderItem(name: 'Frank Beef', quantity: 2, unitPrice: 70),
      ],
    );
    expect(ecom.itemsNet, 140);
    expect(ecom.vatAmount, 19.6);
    expect(ecom.customerTotal, 179.6);
  });
}
