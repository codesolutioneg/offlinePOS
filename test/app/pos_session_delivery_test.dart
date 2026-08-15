import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/app/pos_session.dart';
import 'package:offline_pos/core/audit/audit_log.dart';
import 'package:offline_pos/core/db/catalogue_store.dart';
import 'package:offline_pos/core/db/database.dart';
import 'package:offline_pos/core/db/order_store.dart';
import 'package:offline_pos/core/db/sqlite_outbox_store.dart';
import 'package:offline_pos/core/sync/outbox.dart';
import 'package:offline_pos/domain/catalogue.dart';
import 'package:offline_pos/domain/delivery.dart';
import 'package:offline_pos/domain/order.dart';

import '../db/sqlite_loader.dart';

const pizza = Product(id: 10, name: 'Margherita', price: 100);
const talabat = DeliveryChannel(id: 'c1', name: 'Talabat', partnerId: 77);
const shopPhone = DeliveryChannel(id: 'c2', name: 'Phone');

/// What the running order does with the delivery details around it.
void main() {
  late Db db;
  late OrderStore orders;
  late PosSession session;

  setUpAll(useSystemSqlite);
  setUp(() {
    db = Db.open(':memory:');
    orders = OrderStore(db);
    session = PosSession(
      catalogue: CatalogueStore(db),
      orders: orders,
      outbox: Outbox(store: SqliteOutboxStore(db), senders: const {}),
      audit: AuditLog(db),
      deviceId: 'till-1',
      cashierId: 'sara',
    );
    session.setOrderType(OrderType.delivery);
    session.addProduct(pizza);
  });
  tearDown(() => db.close());

  test('emptying the bill takes the channel and the driver with it', () {
    session.setDeliveryChannel(talabat, companyOrderNo: 'TLB-1');
    session.setDriver('Hany');

    session.clear();

    expect(session.current.deliveryChannel, isNull);
    expect(session.current.companyOrderNo, isNull);
    expect(session.current.driverName, isNull);
  });

  test('a blank company number is stored as nothing', () {
    session.setDeliveryChannel(talabat, companyOrderNo: '   ');
    expect(session.current.companyOrderNo, isNull);
  });

  test('a company channel books the sale against its partner', () {
    session.setDeliveryChannel(talabat);
    expect(session.current.partnerId, 77);
  });

  test('moving to a channel with no company drops the old one', () {
    session.setDeliveryChannel(talabat);
    session.setDeliveryChannel(shopPhone, previous: talabat);
    expect(session.current.partnerId, isNull);
    expect(session.current.deliveryChannel, 'Phone');
  });

  test('a customer attached by hand is not the channel to remove', () {
    session.setCustomer(const Customer(id: 42, name: 'Nadia'));
    session.setDeliveryChannel(shopPhone, previous: talabat);
    expect(session.current.partnerId, 42);
  });

  test('a driver is trimmed and clearable', () {
    session.setDriver('  Hany  ');
    expect(session.current.driverName, 'Hany');
    session.setDriver(null);
    expect(session.current.driverName, isNull);
  });
}
