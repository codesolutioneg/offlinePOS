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
import 'package:offline_pos/domain/catalogue.dart';
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

/// A regular who settles at the end of the month, rung on a running till: the
/// account tender only exists when the shop has nominated one, it is refused
/// without a customer, and what it books lands in the receivables report.
void main() {
  late Db db;
  late OrderStore orders;
  late SettingsStore settings;
  late CustomerStore customers;
  late SqliteOutboxStore outboxStore;
  late AuditLog audit;

  const cash = PaymentMethod(id: 1, name: 'Cash', isCash: true);
  const account = PaymentMethod(id: 7, name: 'Customer account');

  setUpAll(useSystemSqlite);
  setUp(() async {
    db = Db.open(':memory:');
    // The till refuses to start an order with no shift open, so a test that
    // sells opens the drawer first.
    ShiftStore(db).openShift(openingFloat: 100, cashierId: 'sara');
    orders = OrderStore(db);
    settings = SettingsStore(db);
    customers = CustomerStore(db);
    outboxStore = SqliteOutboxStore(db);
    audit = AuditLog(db);
    CatalogueStore(db).replaceAll(
      categories: const [Category(id: 1, name: 'Pizza')],
      products: const [Product(id: 10, name: 'Margherita', price: 250, categoryId: 1)],
      groups: const [],
      productGroupIds: const {},
      paymentMethods: const [cash, account],
      refreshedAt: DateTime.now().toUtc(),
    );
    await AuthService(users: UserStore(db), hasher: FakePinHasher(), audit: audit)
        .enrol(id: 'sara', name: 'Sara', pin: '1234');
    WizardStore(db).dismiss(WizardId.firstSale, 'sara');
  });
  tearDown(() => db.close());

  Widget app() {
    final outbox = Outbox(store: outboxStore, senders: {});
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
      settings: settings,
      customers: customers,
      attendance: AttendanceStore(db),
      config: const TillConfig(),
    );
  }

  Order draftOnTheTill({String? customerName, int? partnerId}) {
    final order = Order(
      deviceId: 'till-1',
      cashierId: 'sara',
      type: OrderType.takeaway,
      customerName: customerName,
      partnerId: partnerId,
    )..lines.add(
        OrderLine(productId: 10, name: 'Margherita', quantity: 2, unitPrice: 250));
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

  Future<void> openPayment(WidgetTester t) async {
    await t.tap(find.byKey(const Key('pay')));
    await t.pumpAndSettle();
  }

  void tallWindow(WidgetTester t) {
    t.view.physicalSize = const Size(1000, 3200);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
  }

  testWidgets('a shop that runs no accounts sees no such button', (t) async {
    tallWindow(t);
    draftOnTheTill(customerName: 'Nadia', partnerId: 42);
    await t.pumpWidget(app());
    await signIn(t);
    await openPayment(t);

    expect(find.byKey(const Key('pay-later')), findsNothing);
  });

  testWidgets('without a customer the account tender is refused', (t) async {
    tallWindow(t);
    settings.payLaterMethodId = account.id;
    draftOnTheTill();
    await t.pumpWidget(app());
    await signIn(t);
    await openPayment(t);

    await t.tap(find.byKey(const Key('pay-later')));
    await t.pumpAndSettle();

    expect(find.byKey(const Key('on-account-refused')), findsOneWidget);
    // Nothing was taken and nothing was booked: the sheet is still open.
    expect(find.byKey(const Key('confirm-payment')), findsOneWidget);
    expect(orders.recent(), isEmpty);
  });

  testWidgets('with a customer it books the whole bill under its own label',
      (t) async {
    tallWindow(t);
    settings.payLaterMethodId = account.id;
    draftOnTheTill(customerName: 'Nadia', partnerId: 42);
    await t.pumpWidget(app());
    await signIn(t);
    await openPayment(t);

    await t.tap(find.byKey(const Key('pay-later')));
    await t.pumpAndSettle();

    final sale = orders.recent().single;
    expect(sale.state, OrderState.paid);
    expect(sale.total, 500);
    final tender = sale.payments.single;
    expect(tender.label, kOnAccountLabel,
        reason: 'the receivables report reads the sale by this label');
    expect(tender.methodId, account.id,
        reason: 'it books against the method the shop nominated, never an invented one');
    expect(tender.amount, 500);
    // The wire contract is untouched: one ordinary sale, queued for the close batch.
    expect(outboxStore.pendingSalesCount, 1);
  });

  testWidgets('what was put on account shows up in the receivables report',
      (t) async {
    tallWindow(t);
    settings.payLaterMethodId = account.id;
    draftOnTheTill(customerName: 'Nadia', partnerId: 42);
    await t.pumpWidget(app());
    await signIn(t);
    await openPayment(t);
    await t.tap(find.byKey(const Key('pay-later')));
    await t.pumpAndSettle();

    // Straight to the reports the manager reads at the end of the day.
    t.state<ScaffoldState>(find
            .descendant(of: find.byType(SellScreen), matching: find.byType(Scaffold))
            .first)
        .openDrawer();
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('nav-report')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('rep-receivables')));
    await t.pumpAndSettle();

    expect(find.text('Nadia'), findsWidgets);
    expect(find.text('500.00'), findsWidgets);
  });

  testWidgets('a sale settled in cash is not a receivable', (t) async {
    tallWindow(t);
    settings.payLaterMethodId = account.id;
    draftOnTheTill(customerName: 'Nadia', partnerId: 42);
    await t.pumpWidget(app());
    await signIn(t);
    await openPayment(t);
    await t.tap(find.byKey(const Key('confirm-payment')));
    await t.pumpAndSettle();

    t.state<ScaffoldState>(find
            .descendant(of: find.byType(SellScreen), matching: find.byType(Scaffold))
            .first)
        .openDrawer();
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('nav-report')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('rep-receivables')));
    await t.pumpAndSettle();

    expect(find.byKey(const Key('receivables-empty')), findsOneWidget);
  });
}
