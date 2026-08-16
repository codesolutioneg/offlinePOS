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
import 'package:offline_pos/core/sync/odoo_site.dart';
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

/// The shop's own identity in Odoo, typed on the till and riding on the sale.
///
/// A manager types the branch, the point of sale and the warehouse on the server
/// screen; a cashier then rings a sale on the same running app; the payload that
/// reaches the wire carries all three. Anything less and the ids are a form that
/// remembers what was typed and changes nothing.
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
    // The published ids outlive one test's database, so hand them back.
    OdooSite.shared = const OdooSite();
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

  Future<void> setTheShopUp(WidgetTester t,
      {String branch = '3', String restaurant = '7', String warehouse = '2'}) async {
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
    await t.enterText(find.byKey(const Key('field-branch')), branch);
    await t.enterText(find.byKey(const Key('field-restaurant')), restaurant);
    await t.enterText(find.byKey(const Key('field-warehouse')), warehouse);
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

  testWidgets('a sale rung after the shop is named carries all three ids',
      (t) async {
    draftOnTheTill();
    await boot(t);
    await setTheShopUp(t);
    await ringItUp(t);

    // What a cashier changed on screen has to reach the store the sender reads.
    expect(settings.odooBranchId, 3);
    expect(settings.odooRestaurantId, 7);
    expect(settings.odooWarehouseId, 2);

    expect(await outbox.drain(), greaterThan(0));
    final payload = bookedOrder();
    expect(payload['company_id'], 3, reason: 'the branch is a company in jouma');
    expect(payload['config_id'], 7,
        reason: 'the point of sale is the one id the booking method acts on');
    expect(payload['warehouse_id'], 2);
    // Still one sale under its own uuid: naming the shop must not change what a
    // sale is.
    expect(payload['uuid'], orders.recent().single.uuid);
  });

  testWidgets('a sale taken before the shop was named still carries the ids',
      (t) async {
    draftOnTheTill();
    await boot(t);
    // Rung first, named after: exactly the week-of-outage case, where the manager
    // only sets the shop up once the line is back.
    await ringItUp(t);
    await setTheShopUp(t, branch: '1', restaurant: '4', warehouse: '5');

    expect(await outbox.drain(), greaterThan(0));
    final payload = bookedOrder();
    expect(payload['config_id'], 4);
    expect(payload['company_id'], 1);
    expect(payload['warehouse_id'], 5);
  });

  testWidgets('ids nobody set do not travel', (t) async {
    draftOnTheTill();
    await boot(t);
    // The point of sale named, the rest left blank: a shop with one company and
    // one warehouse should not have to type them.
    await setTheShopUp(t, branch: '', restaurant: '7', warehouse: '');
    await ringItUp(t);

    expect(await outbox.drain(), greaterThan(0));
    final payload = bookedOrder();
    expect(payload['config_id'], 7);
    expect(payload.containsKey('company_id'), isFalse,
        reason: 'an unset id must not arrive as a zero Odoo would try to browse');
    expect(payload.containsKey('warehouse_id'), isFalse);
  });
}
