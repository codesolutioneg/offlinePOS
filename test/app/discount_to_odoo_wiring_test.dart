import 'dart:convert';

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
import 'package:offline_pos/core/sync/odoo_sender.dart';
import 'package:offline_pos/core/sync/odoo_wiring.dart';
import 'package:offline_pos/core/sync/outbox.dart';
import 'package:offline_pos/core/sync/sync_service.dart';
import 'package:offline_pos/domain/catalogue.dart';
import 'package:offline_pos/domain/order.dart';
import 'package:offline_pos/features/sell/sell_screen.dart';
import 'package:offline_pos/features/settings/server_settings_screen.dart';
import 'package:offline_pos/features/tables/table_floor_screen.dart';

import '../db/sqlite_loader.dart';
import '../ui/fake_pin_hasher.dart';

class _NoPrinters extends PrinterDiscovery {
  @override
  Future<bool> probe(String host, {int? port}) async => false;

  @override
  Future<List<DiscoveredPrinter>> scan({int? port, Duration? budget}) async => const [];
}

/// A discount given at the till, as Odoo receives it.
///
/// The shop's complaint was that discounts cannot be found in Odoo. A cashier takes
/// money off on the running app and the payload that leaves the till is checked for
/// what the shop needs to see there: the amount given away, and, once a discount
/// product is named, the menu prices with the discount as its own line.
void main() {
  late Db db;
  late OrderStore orders;
  late SettingsStore settings;
  late SqliteOutboxStore outboxStore;
  late AuditLog audit;
  late Outbox outbox;
  late List<Map<String, dynamic>> calls;

  setUpAll(useSystemSqlite);
  setUp(() async {
    db = Db.open(':memory:');
    // The till refuses to start an order with no shift open, so a test that
    // sells opens the drawer first.
    ShiftStore(db).openShift(openingFloat: 100, cashierId: 'sara');
    orders = OrderStore(db);
    settings = SettingsStore(db);
    outboxStore = SqliteOutboxStore(db);
    audit = AuditLog(db);
    calls = [];
    CatalogueStore(db).replaceAll(
      categories: const [Category(id: 1, name: 'Pizza')],
      products: const [Product(id: 10, name: 'Margherita', price: 250, categoryId: 1)],
      groups: const [],
      productGroupIds: const {},
      paymentMethods: const [PaymentMethod(id: 1, name: 'Cash', isCash: true)],
      refreshedAt: DateTime.now().toUtc(),
    );
    await AuthService(users: UserStore(db), hasher: FakePinHasher(), audit: audit)
        .enrol(id: 'sara', name: 'Sara', pin: '1234', role: 'manager');
    WizardStore(db).dismiss(WizardId.firstSale, 'sara');
  });
  tearDown(() {
    // The published setting outlives one test's database, so hand it back.
    DiscountBooking.productId = null;
    db.close();
  });

  /// Answers like an Odoo that accepts everything, and keeps what it was asked.
  Future<HttpReply> fakeOdoo(
      Uri url, Map<String, String> headers, String body) async {
    calls.add(jsonDecode(body) as Map<String, dynamic>);
    if (url.path.endsWith('/authenticate')) {
      return HttpReply(200, jsonEncode({'result': {'uid': 2}}),
          headers: const {'set-cookie': 'session_id=abc; Path=/'});
    }
    return HttpReply(
        200,
        jsonEncode({
          'result': [
            {'status': 'created', 'id': 9}
          ]
        }));
  }

  Widget app() {
    outbox = Outbox(store: outboxStore, senders: {});
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
      odoo: OdooWiring(outbox: outbox, post: fakeOdoo),
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
            productId: 10, name: 'Margherita', quantity: 2, unitPrice: 250)),
      announce: false,
    );
  }

  Future<void> boot(WidgetTester t) async {
    await t.binding.setSurfaceSize(const Size(1280, 1600));
    addTearDown(() => t.binding.setSurfaceSize(null));
    await t.pumpWidget(app());
    await t.tap(find.byKey(const Key('user-sara')));
    await t.pump();
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
    if (find.byType(TableFloorScreen).evaluate().isNotEmpty) {
      await t.pageBack();
      await t.pumpAndSettle();
    }
  }

  Future<void> setTheShopUp(WidgetTester t, {String discountProduct = ''}) async {
    await t.tap(find.byType(DrawerButton));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('nav-settings')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('set-server')));
    await t.pumpAndSettle();
    expect(find.byType(ServerSettingsScreen), findsOneWidget);

    await t.enterText(find.byKey(const Key('field-url')), 'https://shop.example.com');
    await t.enterText(find.byKey(const Key('field-db')), 'shop');
    await t.enterText(find.byKey(const Key('field-login')), 'till@example.com');
    await t.enterText(
        find.byKey(const Key('field-discount-product')), discountProduct);
    await t.tap(find.byKey(const Key('save-server')));
    await t.pumpAndSettle();
    // Back to the sell screen the way a manager leaves the settings: the server
    // screen, then the hub.
    await t.pageBack();
    await t.pumpAndSettle();
    await t.pageBack();
    await t.pumpAndSettle();
  }

  Future<void> ringItUp(WidgetTester t) async {
    await t.tap(find.byKey(const Key('pay')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('confirm-payment')));
    await t.pumpAndSettle();
  }

  /// The payload of the one booking call the sender made.
  Map<String, dynamic> bookedOrder() {
    final booking = calls.firstWhere(
        (c) => (c['params'] as Map)['method'] == 'create_from_offline_pos',
        orElse: () => throw StateError('no sale reached the wire: $calls'));
    final args = ((booking['params'] as Map)['args'] as List).first as List;
    return (args.first as Map).cast<String, dynamic>();
  }

  /// Take 10% off the bill the way a cashier does: the chip, a preset, apply.
  Future<void> takeTenPercentOff(WidgetTester t) async {
    await t.tap(find.byKey(const Key('discount')));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const Key('discount-value')), '10');
    await t.tap(find.byKey(const Key('apply-discount')));
    await t.pumpAndSettle();
  }

  testWidgets('a discounted sale tells Odoo what was taken off', (t) async {
    draftOnTheTill();
    await boot(t);
    await setTheShopUp(t);
    await takeTenPercentOff(t);
    await ringItUp(t);

    expect(await outbox.drain(), greaterThan(0));
    final payload = bookedOrder();
    // 2 x 250, less 10%.
    expect(payload['discount_amount'], 50,
        reason: 'a payload that only carries cheaper prices leaves nothing in Odoo '
            'that says a discount happened');
    expect(payload['prices_include_discount'], isTrue);
    expect((payload['lines'] as List).single['unit_price'], 225);
  });

  testWidgets('with a discount product it books as a discount line', (t) async {
    draftOnTheTill();
    await boot(t);
    await setTheShopUp(t, discountProduct: '55');
    await takeTenPercentOff(t);
    await ringItUp(t);

    expect(await outbox.drain(), greaterThan(0));
    final payload = bookedOrder();
    final lines = payload['lines'] as List;
    expect(lines, hasLength(2));
    expect(lines.first['unit_price'], 250, reason: 'the menu price, as Odoo knows it');
    expect(lines.last['product_id'], 55);
    expect(lines.last['unit_price'], -50);
    expect(payload['prices_include_discount'], isFalse);
    // The customer paid 450 either way.
    expect(orders.recent().single.total, 450);
  });
}
