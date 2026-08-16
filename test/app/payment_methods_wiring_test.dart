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
import 'package:offline_pos/core/onboarding/wizard_id.dart';
import 'package:offline_pos/core/onboarding/wizard_store.dart';
import 'package:offline_pos/core/printing/printer_discovery.dart';
import 'package:offline_pos/core/printing/printer_registry.dart';
import 'package:offline_pos/core/sync/odoo_endpoint.dart';
import 'package:offline_pos/core/sync/odoo_puller.dart';
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

/// "Payment needs to come from Odoo": what the tender step shows when the methods
/// have arrived, what it shows when they never have, and what a refresh the server
/// half-refuses is allowed to do to the ones the till already had.
void main() {
  late Db db;
  late OrderStore orders;
  late SettingsStore settings;
  late AuditLog audit;
  late bool tendersReadable;
  late bool pointedAtAServer;

  setUpAll(useSystemSqlite);
  setUp(() async {
    db = Db.open(':memory:');
    // The till refuses to start an order with no shift open, so a test that
    // sells opens the drawer first.
    ShiftStore(db).openShift(openingFloat: 100, cashierId: 'sara');
    orders = OrderStore(db);
    settings = SettingsStore(db);
    audit = AuditLog(db);
    tendersReadable = true;
    pointedAtAServer = true;
    await AuthService(users: UserStore(db), hasher: FakePinHasher(), audit: audit)
        .enrol(id: 'sara', name: 'Sara', pin: '1234', role: 'manager');
    WizardStore(db).dismiss(WizardId.firstSale, 'sara');
  });
  tearDown(() => db.close());

  void catalogueOnTheTill({List<PaymentMethod> methods = const []}) {
    CatalogueStore(db).replaceAll(
      categories: const [Category(id: 1, name: 'Pizza')],
      products: const [Product(id: 10, name: 'Margherita', price: 250, categoryId: 1)],
      groups: const [],
      productGroupIds: const {},
      paymentMethods: methods,
      refreshedAt: DateTime.now().toUtc(),
    );
  }

  /// A server that always has the menu and only sometimes answers about tenders,
  /// which is what an integration user without the Point of Sale group looks like.
  OdooPuller puller() => OdooPuller(
        call: (model, method, args, kwargs) async {
          switch (model) {
            case 'product.product':
              return [
                {
                  'id': 10, 'display_name': 'Margherita', 'lst_price': 250,
                  'pos_categ_ids': const <int>[], 'active': true,
                }
              ];
            case 'pos.payment.method':
              if (!tendersReadable) throw Exception('Access denied');
              return [
                {'id': 1, 'name': 'Cash', 'is_cash_count': true},
                {'id': 2, 'name': 'Visa', 'is_cash_count': false},
              ];
            default:
              return const [];
          }
        },
      );

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
        // A till nobody configured has no server to ask, which is the commonest
        // reason a shop sees no methods at all.
        puller: pointedAtAServer ? puller() : null,
      ),
      outboxStore: SqliteOutboxStore(db),
      printers: PrinterRegistry(discovery: _NoPrinters()),
      wizards: WizardStore(db),
      shifts: ShiftStore(db),
      deviceId: 'till-1',
      endpoints: OdooEndpointStore(db),
      odoo: OdooWiring(outbox: outbox),
      tables: TableStore(db),
      settings: settings,
      customers: CustomerStore(db),
      attendance: AttendanceStore(db),
    );
  }

  void draftOnTheTill() {
    orders.save(
      Order(deviceId: 'till-1', cashierId: 'sara', type: OrderType.takeaway)
        ..lines.add(OrderLine(
            productId: 10, name: 'Margherita', quantity: 1, unitPrice: 250)),
      announce: false,
    );
  }

  void tallWindow(WidgetTester t) {
    t.view.physicalSize = const Size(1000, 3200);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
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

  testWidgets('the tender buttons are the methods Odoo sent', (t) async {
    tallWindow(t);
    catalogueOnTheTill(methods: const [
      PaymentMethod(id: 1, name: 'Cash', isCash: true),
      PaymentMethod(id: 2, name: 'Visa'),
    ]);
    draftOnTheTill();
    await t.pumpWidget(app());
    await signIn(t);
    await openPayment(t);

    expect(find.byKey(const Key('method-1')), findsOneWidget);
    expect(find.byKey(const Key('method-2')), findsOneWidget);
    expect(find.byKey(const Key('no-payment-methods')), findsNothing);

    await t.tap(find.byKey(const Key('method-2')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('confirm-payment')));
    await t.pumpAndSettle();

    expect(orders.recent().single.payments.single.methodId, 2,
        reason: 'the sale books against the Odoo method, not a till-invented one');
  });

  testWidgets('a till that never got any says so, and still takes the money',
      (t) async {
    tallWindow(t);
    pointedAtAServer = false;
    catalogueOnTheTill();
    draftOnTheTill();
    await t.pumpWidget(app());
    await signIn(t);
    await openPayment(t);

    expect(find.byKey(const Key('no-payment-methods')), findsOneWidget,
        reason: 'a bare "Cash" reads as a cash-only till rather than a till that '
            'has not been pointed at a server yet');

    await t.tap(find.byKey(const Key('confirm-payment')));
    await t.pumpAndSettle();

    final sale = orders.recent().single;
    expect(sale.state, OrderState.paid);
    expect(sale.payments, isEmpty,
        reason: 'no tender is named, so the server books the whole amount to cash');
  });

  testWidgets('a refresh the server half-refuses keeps the tenders it had',
      (t) async {
    tallWindow(t);
    // The till pulled its methods yesterday and is selling with them.
    catalogueOnTheTill(methods: const [
      PaymentMethod(id: 1, name: 'Cash', isCash: true),
      PaymentMethod(id: 2, name: 'Visa'),
    ]);
    draftOnTheTill();
    // Today the integration user lost the group that lets it read them.
    tendersReadable = false;
    await t.pumpWidget(app());
    await signIn(t);
    await t.pumpAndSettle();

    // The sign-in refresh has run against that server by now.
    expect(CatalogueStore(db).paymentMethods().map((m) => m.name), ['Cash', 'Visa'],
        reason: 'a refused tender read must not empty the payment sheet');
    await openPayment(t);
    expect(find.byKey(const Key('method-2')), findsOneWidget);
  });
}
