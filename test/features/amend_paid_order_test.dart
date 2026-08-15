import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/app/pos_app.dart';
import 'package:offline_pos/core/audit/audit_log.dart';
import 'package:offline_pos/core/auth/auth_service.dart';
import 'package:offline_pos/core/auth/user_store.dart';
import 'package:offline_pos/core/db/attendance_store.dart';
import 'package:offline_pos/core/db/catalogue_store.dart';
import 'package:offline_pos/core/db/customer_store.dart';
import 'package:offline_pos/core/db/database.dart';
import 'package:offline_pos/core/db/order_store.dart';
import 'package:offline_pos/core/db/settings_store.dart';
import 'package:offline_pos/core/db/shift_store.dart';
import 'package:offline_pos/core/db/sqlite_outbox_store.dart';
import 'package:offline_pos/core/db/table_store.dart';
import 'package:offline_pos/core/onboarding/wizard_store.dart';
import 'package:offline_pos/core/printing/printer_discovery.dart';
import 'package:offline_pos/core/printing/printer_registry.dart';
import 'package:offline_pos/core/printing/spool_store.dart';
import 'package:offline_pos/core/sync/odoo_endpoint.dart';
import 'package:offline_pos/core/sync/odoo_wiring.dart';
import 'package:offline_pos/core/sync/outbox.dart';
import 'package:offline_pos/core/sync/sync_service.dart';
import 'package:offline_pos/domain/catalogue.dart';
import 'package:offline_pos/domain/order.dart';
import 'package:offline_pos/features/orders/order_history_screen.dart';
import 'package:offline_pos/features/sell/sell_screen.dart';
import 'package:offline_pos/features/tables/table_floor_screen.dart';

import '../db/sqlite_loader.dart';
import '../ui/fake_pin_hasher.dart';

/// Nothing answers a sweep. A test till has no hardware, and a discovery that
/// reached for the network is the one thing here that could hang.
class _NoPrinters extends PrinterDiscovery {
  @override
  Future<bool> probe(String host, {int? port}) async => false;

  @override
  Future<List<DiscoveredPrinter>> scan({int? port, Duration? budget}) async => const [];
}

/// Correcting a paid sale on the till it was rung on: "rang it wrong", and
/// "they added one more thing right after checkout".
void main() {
  late Db db;
  late OrderStore orders;
  late SqliteOutboxStore outboxStore;
  late AuditLog audit;
  late MemorySpoolStore spool;

  setUpAll(useSystemSqlite);
  setUp(() async {
    db = Db.open(':memory:');
    orders = OrderStore(db, ownDeviceId: 'till-1');
    outboxStore = SqliteOutboxStore(db);
    audit = AuditLog(db);
    // Nothing on this till can print, so every slip lands here instead, which is
    // how a test reads what the printer would have produced.
    spool = MemorySpoolStore();
    CatalogueStore(db).replaceAll(
      categories: const [Category(id: 1, name: 'Food')],
      products: const [
        Product(id: 10, name: 'Pizza', price: 250, categoryId: 1),
        Product(id: 11, name: 'Cola', price: 30, categoryId: 1),
      ],
      groups: const [],
      productGroupIds: const {},
      paymentMethods: const [
        PaymentMethod(id: 1, name: 'Cash', isCash: true),
        PaymentMethod(id: 2, name: 'Card'),
      ],
      refreshedAt: DateTime.now().toUtc(),
    );
  });
  tearDown(() => db.close());

  /// A manager, so the amend permission passes without a PIN dialog in the way of
  /// what this file is actually testing. The gate itself is covered in
  /// test/core/permissions_test.dart.
  Future<AuthService> managerOnTheTill() async {
    final auth = AuthService(
        users: UserStore(db), hasher: FakePinHasher(), audit: AuditLog(db));
    await auth.enrol(id: 'sara', name: 'Sara', pin: '1234', role: 'manager');
    return auth;
  }

  Widget app(AuthService auth) {
    final outbox = Outbox(store: outboxStore, senders: {});
    return PosApp(
      auth: auth,
      users: UserStore(db),
      catalogue: CatalogueStore(db),
      orders: orders,
      outbox: outbox,
      audit: audit,
      sync: SyncService(
        outbox: outbox,
        catalogue: CatalogueStore(db),
        outboxStore: outboxStore,
        deviceId: 'till-1',
        appVersion: 'test',
      ),
      outboxStore: outboxStore,
      printers: PrinterRegistry(discovery: _NoPrinters()),
      wizards: WizardStore(db),
      shifts: ShiftStore(db),
      deviceId: 'till-1',
      endpoints: OdooEndpointStore(db),
      odoo: OdooWiring(outbox: outbox),
      tables: TableStore(db),
      settings: SettingsStore(db),
      customers: CustomerStore(db),
      attendance: AttendanceStore(db),
      receiptSpool: spool,
    );
  }

  /// What the printer would have produced, by spool reference prefix.
  Future<List<String>> slipsMatching(String prefix) async {
    final jobs = await spool.oldestFirst(limit: 100);
    return jobs
        .where((j) => (j.reference ?? '').startsWith(prefix))
        .map((j) => String.fromCharCodes(j.bytes))
        .toList();
  }

  /// A tendered sale sitting on the till waiting for the shift-close batch, with
  /// its line already cooked, which is what a paid order looks like in a real shop.
  Future<Order> paidSale({bool withUnfiredLine = false, double colas = 1}) async {
    final o = Order(deviceId: 'till-1', cashierId: 'sara', lines: [
      OrderLine(
        productId: 10,
        name: 'Pizza',
        quantity: 1,
        unitPrice: 250,
        printedToKitchen: true,
        firedStations: ['kitchen'],
      ),
      // A line the kitchen never got, because the station was down when the sale
      // was rung. Removing it leaves no paper anywhere except the correction slip.
      if (withUnfiredLine)
        OrderLine(productId: 11, name: 'Cola', quantity: colas, unitPrice: 30),
    ])
      ..state = OrderState.paid
      ..payments = const [OrderPayment(methodId: 1, amount: 250, label: 'Cash')];
    orders.save(o);
    await outboxStore.append('order.push', o.uuid, o.toServerPayload());
    return o;
  }

  Future<void> signIn(WidgetTester t) async {
    await t.tap(find.byKey(const Key('user-sara')));
    await t.pump();
    for (final d in '1234'.split('')) {
      await t.tap(find.byKey(Key('key-$d')));
      await t.pump();
    }
    await t.tap(find.byKey(const Key('pin-ok')));
    // The PIN check resolves off the frame pipeline; give the microtask queue real
    // time rather than trusting one settle.
    for (var i = 0; i < 20; i++) {
      await t.pump(const Duration(milliseconds: 50));
      if (find.byType(SellScreen).evaluate().isNotEmpty) break;
    }
    await t.pumpAndSettle();
    // Nothing is parked on this till (the sale under test is already paid), so
    // signing in lands on the floor. These tests are about the counter, so come
    // back to it the way a cashier would.
    if (find.byType(TableFloorScreen).evaluate().isNotEmpty) {
      await t.pageBack();
      await t.pumpAndSettle();
    }
    // The first-sale walkthrough covers the counter on a fresh till. Skipped, so
    // these tests exercise the till a cashier actually works on.
    await t.tap(find.byKey(const Key('wizard-skip')));
    await t.pumpAndSettle();
  }

  /// Boot the till on a screen the size of a real one, so the cart is not cut off
  /// by the test surface, and get past the sign-in.
  Future<void> boot(WidgetTester t) async {
    await t.binding.setSurfaceSize(const Size(1280, 1000));
    addTearDown(() => t.binding.setSurfaceSize(null));
    await t.pumpWidget(app(await managerOnTheTill()));
    await signIn(t);
  }

  /// Sign in, walk to the sale in history and press Edit.
  Future<Order> reachEditAndTap(WidgetTester t,
      {bool withUnfiredLine = false, double colas = 1}) async {
    final sale =
        await paidSale(withUnfiredLine: withUnfiredLine, colas: colas);
    await boot(t);

    await t.tap(find.byType(DrawerButton));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('nav-history')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(Key('history-${sale.uuid}')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(Key('edit-${sale.uuid}')));
    await t.pumpAndSettle();
    return sale;
  }

  testWidgets('editing a paid sale puts it back on the counter', (t) async {
    final sale = await reachEditAndTap(t);

    // Back on the sell screen with the sale in the cart, not behind two screens.
    expect(find.byType(SellScreen), findsOneWidget);
    expect(find.byType(OrderHistoryScreen), findsNothing);
    expect(orders.byUuid(sale.uuid)!.state, OrderState.draft);
    expect(find.byKey(Key('line-${sale.lines.single.uuid}')), findsOneWidget);
    expect(t.widget<Text>(find.byKey(const Key('total'))).data, '250.00');
  });

  testWidgets('the queued push is withdrawn, so the pre-edit sale cannot book',
      (t) async {
    expect(outboxStore.pendingSalesCount, 0);
    final sale = await reachEditAndTap(t);

    expect(outboxStore.pendingSalesCount, 0);
    expect(await outboxStore.pending(), isEmpty);
    expect(orders.awaitingSync(), isEmpty);
    expect(orders.byUuid(sale.uuid)!.state, OrderState.draft);
  });

  testWidgets('the correction is audited with what the sale was worth before',
      (t) async {
    final sale = await reachEditAndTap(t);

    final entry = audit.recent(event: 'order.amended').single;
    expect(entry['detail'], '${sale.uuid}|250.00');
    expect(entry['actor'], 'sara');
  });

  testWidgets('the corrected sale books once, carrying the added item', (t) async {
    final sale = await reachEditAndTap(t);

    // The customer adds a drink, and the sale is tendered again.
    await t.tap(find.byKey(const Key('product-11')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('pay')));
    await t.pumpAndSettle();
    // Card, so the sheet is covered without a cash-received amount.
    await t.tap(find.byKey(const Key('method-2')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('confirm-payment')));
    await t.pumpAndSettle();

    final booked = await outboxStore.pending();
    expect(booked, hasLength(1));
    expect(booked.single.payloadUuid, sale.uuid);
    expect(booked.single.payload['lines'], hasLength(2));

    final back = orders.byUuid(sale.uuid)!;
    expect(back.state, OrderState.paid);
    expect(back.total, 280);
    // One set of tenders for one sale, not the first payment plus the second.
    expect(back.payments, hasLength(1));
    expect(back.amountPaid, 280);
    // And the receipt says the sale was corrected.
    expect(back.amended, isTrue);
    // The wire contract does not grow with the till's own bookkeeping.
    expect(booked.single.payload.containsKey('amended'), isFalse);
  });

  testWidgets('the food already cooked is not sent to the kitchen again', (t) async {
    final sale = await reachEditAndTap(t);

    await t.tap(find.byKey(const Key('product-11')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('pay')));
    await t.pumpAndSettle();
    // Card, so the sheet is covered without a cash-received amount.
    await t.tap(find.byKey(const Key('method-2')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('confirm-payment')));
    await t.pumpAndSettle();

    final back = orders.byUuid(sale.uuid)!;
    final pizza = back.lines.firstWhere((l) => l.name == 'Pizza');
    // Untouched by the second payment: the station it was already sent to is not
    // recorded a second time, which is what a re-fire would look like.
    expect(pizza.printedToKitchen, isTrue);
    expect(pizza.firedStations, ['kitchen']);
  });

  testWidgets('an item taken off a paid sale leaves a slip at the till', (t) async {
    final sale = await reachEditAndTap(t, withUnfiredLine: true);
    final cola = sale.lines.firstWhere((l) => l.name == 'Cola');

    // The kitchen never had this one, so it deletes without a void prompt and
    // would otherwise come off a paid bill leaving no paper at all.
    await t.tap(find.descendant(
        of: find.byKey(Key('line-${cola.uuid}')),
        matching: find.byIcon(Icons.delete_outline)));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('pay')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('method-2')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('confirm-payment')));
    await t.pumpAndSettle();

    final slips = await slipsMatching('void-slip-${sale.uuid}');
    expect(slips, hasLength(1));
    expect(slips.single, contains('REMOVED ON EDIT'));
    expect(slips.single, contains('Cola'));
    // And the sale that books is the corrected one.
    expect(orders.byUuid(sale.uuid)!.total, 250);
  });

  testWidgets('stepping units off a paid line leaves a slip for those units',
      (t) async {
    final sale = await reachEditAndTap(t, withUnfiredLine: true, colas: 3);
    final cola = sale.lines.firstWhere((l) => l.name == 'Cola');

    // 3 Colas down to 1: the line keeps its uuid, so only the quantity says two
    // units the customer paid for are no longer on the bill.
    await t.tap(find.descendant(
        of: find.byKey(Key('line-${cola.uuid}')),
        matching: find.byIcon(Icons.remove_circle_outline)));
    await t.pumpAndSettle();
    await t.tap(find.descendant(
        of: find.byKey(Key('line-${cola.uuid}')),
        matching: find.byIcon(Icons.remove_circle_outline)));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('pay')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('method-2')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('confirm-payment')));
    await t.pumpAndSettle();

    final slips = await slipsMatching('void-slip-${sale.uuid}');
    expect(slips, hasLength(1));
    expect(slips.single, contains('REMOVED ON EDIT'));
    // The two units that came off, at what they were sold for.
    expect(slips.single, contains('2 x Cola'));
    expect(slips.single, contains('60.00'));
    expect(orders.byUuid(sale.uuid)!.total, 280);
  });

  testWidgets('a sale corrected with nothing taken off prints no removal slip',
      (t) async {
    final sale = await reachEditAndTap(t);

    await t.tap(find.byKey(const Key('product-11')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('pay')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('method-2')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('confirm-payment')));
    await t.pumpAndSettle();

    expect(await slipsMatching('void-slip-${sale.uuid}'), isEmpty);
  });

  testWidgets('a sale the server already has is refused rather than edited',
      (t) async {
    final sale = await paidSale();
    orders.markSynced(sale.uuid, 42);
    await boot(t);

    await t.tap(find.byType(DrawerButton));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('nav-history')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(Key('history-${sale.uuid}')));
    await t.pumpAndSettle();

    // Not offered at all, because the answer there is a refund and a re-ring.
    expect(find.byKey(Key('edit-${sale.uuid}')), findsNothing);
    expect(find.byKey(Key('refund-${sale.uuid}')), findsOneWidget);
    expect(orders.byUuid(sale.uuid)!.state, OrderState.synced);
    expect(audit.recent(event: 'order.amended'), isEmpty);
  });
}
