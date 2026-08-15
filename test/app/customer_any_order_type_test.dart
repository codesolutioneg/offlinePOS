import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/app/pos_app.dart';
import 'package:offline_pos/core/audit/audit_log.dart';
import 'package:offline_pos/core/auth/auth_service.dart';
import 'package:offline_pos/core/auth/user_store.dart';
import 'package:offline_pos/core/config/till_config.dart';
import 'package:offline_pos/core/db/attendance_store.dart';
import 'package:offline_pos/core/db/catalogue_store.dart';
import 'package:offline_pos/core/db/customer_store.dart';
import 'package:offline_pos/core/db/database.dart';
import 'package:offline_pos/core/db/order_store.dart';
import 'package:offline_pos/core/db/settings_store.dart';
import 'package:offline_pos/core/db/shift_store.dart';
import 'package:offline_pos/core/db/sqlite_outbox_store.dart';
import 'package:offline_pos/core/db/table_store.dart';
import 'package:offline_pos/core/onboarding/wizard_id.dart';
import 'package:offline_pos/core/onboarding/wizard_store.dart';
import 'package:offline_pos/core/printing/printer_discovery.dart';
import 'package:offline_pos/core/printing/printer_registry.dart';
import 'package:offline_pos/core/sync/odoo_endpoint.dart';
import 'package:offline_pos/core/sync/odoo_wiring.dart';
import 'package:offline_pos/core/sync/outbox.dart';
import 'package:offline_pos/core/sync/sync_service.dart';
import 'package:offline_pos/domain/order.dart';
import 'package:offline_pos/features/sell/sell_screen.dart';

import '../db/sqlite_loader.dart';
import '../ui/fake_pin_hasher.dart';

class _NoPrinters extends PrinterDiscovery {
  @override
  Future<bool> probe(String host, {int? port}) async => false;

  @override
  Future<List<DiscoveredPrinter>> scan({int? port, Duration? budget}) async => const [];
}

/// A customer on a sale that is not a delivery, as the cashier reaches it: the chip
/// on the context bar of a real app shell, the picker behind it, and the walk-in
/// action that takes them off again.
void main() {
  late Db db;
  late OrderStore orders;
  late CustomerStore customers;
  late AuditLog audit;

  setUpAll(useSystemSqlite);
  setUp(() async {
    db = Db.open(':memory:');
    orders = OrderStore(db);
    customers = CustomerStore(db);
    audit = AuditLog(db);
    await AuthService(users: UserStore(db), hasher: FakePinHasher(), audit: audit)
        .enrol(id: 'sara', name: 'Sara', pin: '1234');
    WizardStore(db).dismiss(WizardId.firstSale, 'sara');
  });
  tearDown(() => db.close());

  Widget app() {
    final outbox = Outbox(store: SqliteOutboxStore(db), senders: {});
    return PosApp(
      auth: AuthService(users: UserStore(db), hasher: FakePinHasher(), audit: audit),
      users: UserStore(db),
      catalogue: CatalogueStore(db),
      orders: orders,
      outbox: outbox,
      audit: audit,
      sync: SyncService(
        outbox: outbox,
        catalogue: CatalogueStore(db),
        outboxStore: SqliteOutboxStore(db),
        deviceId: 'till-1',
        appVersion: 'test',
      ),
      outboxStore: SqliteOutboxStore(db),
      printers: PrinterRegistry(discovery: _NoPrinters()),
      wizards: WizardStore(db),
      shifts: ShiftStore(db),
      deviceId: 'till-1',
      endpoints: OdooEndpointStore(db),
      odoo: OdooWiring(outbox: outbox),
      tables: TableStore(db),
      settings: SettingsStore(db),
      customers: customers,
      attendance: AttendanceStore(db),
      config: const TillConfig(),
    );
  }

  Order draftOnTheTill({OrderType type = OrderType.takeaway}) {
    final order = Order(deviceId: 'till-1', cashierId: 'sara', type: type)
      ..lines.add(OrderLine(productId: 1, name: 'Pizza', quantity: 1, unitPrice: 100));
    orders.save(order, announce: false);
    return order;
  }

  Future<void> signIn(WidgetTester t) async {
    await t.tap(find.byKey(const Key('user-sara')));
    await t.pumpAndSettle();
    for (final d in '1234'.split('')) {
      await t.tap(find.byKey(Key('key-$d')));
      await t.pump();
    }
    await t.tap(find.byKey(const Key('pin-ok')));
    for (var i = 0; i < 20; i++) {
      await t.pump(const Duration(milliseconds: 50));
      if (find.byType(SellScreen).evaluate().isNotEmpty) break;
    }
    await t.pumpAndSettle();
  }

  testWidgets('a takeaway sale can be booked against a customer', (t) async {
    customers.add(name: 'Nadia', phone: '0100');
    draftOnTheTill();

    await t.pumpWidget(app());
    await signIn(t);
    await t.tap(find.byKey(const Key('customer-chip')));
    await t.pumpAndSettle();
    await t.tap(find.text('Nadia'));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('hold')));
    await t.pumpAndSettle();

    final held = orders.held().single;
    expect(held.customerName, 'Nadia');
    expect(held.partnerId, isNotNull,
        reason: 'the chip must attach the partner, not just the typed name');
  });

  testWidgets('a dine-in table can be booked against a customer too', (t) async {
    customers.add(name: 'Nadia', phone: '0100');
    draftOnTheTill(type: OrderType.dineIn);

    await t.pumpWidget(app());
    await signIn(t);
    await t.tap(find.byKey(const Key('customer-chip')));
    await t.pumpAndSettle();
    await t.tap(find.text('Nadia'));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('hold')));
    await t.pumpAndSettle();

    expect(orders.held().single.customerName, 'Nadia');
  });

  testWidgets('walk-in takes the customer back off the sale', (t) async {
    customers.add(name: 'Nadia', phone: '0100');
    draftOnTheTill();

    await t.pumpWidget(app());
    await signIn(t);
    await t.tap(find.byKey(const Key('customer-chip')));
    await t.pumpAndSettle();
    await t.tap(find.text('Nadia'));
    await t.pumpAndSettle();
    // The action that was accepted by the picker and then dropped on the floor.
    await t.tap(find.byKey(const Key('customer-chip')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('customer-clear')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('hold')));
    await t.pumpAndSettle();

    final held = orders.held().single;
    expect(held.customerName, isNull);
    expect(held.partnerId, isNull);
  });

  testWidgets('a customer captured mid-order is attached and kept', (t) async {
    draftOnTheTill();

    await t.pumpWidget(app());
    await signIn(t);
    await t.tap(find.byKey(const Key('customer-chip')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('customer-add-new')));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const Key('cust-name')), 'Yasmin');
    await t.enterText(find.byKey(const Key('cust-phone')), '0111');
    await t.tap(find.byKey(const Key('customer-form-save')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('hold')));
    await t.pumpAndSettle();

    expect(orders.held().single.customerName, 'Yasmin');
    expect(customers.search(query: 'Yasmin').single.name, 'Yasmin',
        reason: 'the next order should be able to pick them without retyping');
  });

  testWidgets('a delivery turned into a takeaway keeps its customer', (t) async {
    final order = draftOnTheTill(type: OrderType.delivery)
      ..partnerId = 42
      ..customerName = 'Nadia'
      ..customerPhone = '0100'
      ..customerAddress = '12 Nile St'
      ..deliveryCost = 20;
    orders.save(order, announce: false);

    await t.pumpWidget(app());
    await signIn(t);
    await t.tap(find.byKey(const Key('order-type-takeaway')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('hold')));
    await t.pumpAndSettle();

    final held = orders.held().single;
    expect(held.customerName, 'Nadia', reason: 'every type can name a customer now');
    expect(held.partnerId, 42);
    // What was delivery's alone still goes: there is nowhere to drive to.
    expect(held.customerAddress, isNull);
    expect(held.deliveryCost, 0);
  });
}
