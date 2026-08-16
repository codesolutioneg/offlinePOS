import 'dart:convert';

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
import 'package:offline_pos/core/sync/odoo_sender.dart';
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

/// Finding a customer the catalogue pull never brought down.
///
/// The pull is capped at 500 partners, which a shop with a real customer book
/// outgrows. This is the way back to the rest, and it is only ever a bonus: the
/// picker answers from disk first, the search runs beside it, and a till with no
/// line behaves exactly as it did before this existed.
void main() {
  late Db db;
  late OrderStore orders;
  late AuditLog audit;
  late SyncService sync;
  late CatalogueStore catalogue;

  /// Every call_kw the app made, so a test can prove what was asked and that
  /// nothing was asked at all when the till believes it is offline.
  late List<Map<String, dynamic>> calls;

  /// The partners the server holds but the pull never carried.
  late List<Map<String, dynamic>> serverPartners;

  /// Set to make the server refuse, which is what a captive portal looks like.
  var serverBroken = false;

  setUpAll(useSystemSqlite);
  setUp(() async {
    db = Db.open(':memory:');
    // The till refuses to start an order with no shift open, so a test that
    // sells opens the drawer first.
    ShiftStore(db).openShift(openingFloat: 100, cashierId: 'sara');
    orders = OrderStore(db, ownDeviceId: 'till-1');
    audit = AuditLog(db);
    catalogue = CatalogueStore(db);
    calls = [];
    serverBroken = false;
    serverPartners = [
      {'id': 501, 'name': 'Farida Kamel', 'phone': '0100 999'},
    ];
    catalogue.replaceAll(
      categories: const [Category(id: 1, name: 'Food')],
      products: const [Product(id: 10, name: 'Pizza', price: 100, categoryId: 1)],
      groups: const [],
      productGroupIds: const {},
      customers: const [Customer(id: 1, name: 'Nadia Local', phone: '0111')],
      refreshedAt: DateTime.now().toUtc(),
    );
    await AuthService(users: UserStore(db), hasher: FakePinHasher(), audit: audit)
        .enrol(id: 'sara', name: 'Sara', pin: '1234');
    WizardStore(db).dismiss(WizardId.firstSale, 'sara');
  });
  tearDown(() => db.close());

  /// An Odoo that authenticates and answers a res.partner read.
  Future<HttpReply> fakeOdoo(
      Uri url, Map<String, String> headers, String body) async {
    if (url.path.contains('authenticate')) {
      return HttpReply(200, '{"result":{"uid":2}}',
          headers: const {'set-cookie': 'session_id=abc; Path=/'});
    }
    if (serverBroken) return const HttpReply(500, 'nope');
    final params =
        (jsonDecode(body) as Map<String, dynamic>)['params'] as Map<String, dynamic>;
    calls.add(params);
    return HttpReply(200, jsonEncode({'result': serverPartners}));
  }

  Widget app({bool online = true, bool configured = true}) {
    final outbox = Outbox(store: SqliteOutboxStore(db), senders: {});
    sync = SyncService(
      outbox: outbox,
      catalogue: catalogue,
      outboxStore: SqliteOutboxStore(db),
      deviceId: 'till-1',
      appVersion: 'test',
      // A real till always has one, and it is what stops a refresh reaching for a
      // socket that is not there. Without it here, an "offline" till in this file
      // was offline only in the badge, and sign-in still pulled the catalogue.
      probe: () async => online,
    );
    // What a till that has reached the server once looks like. Nothing about a sale
    // depends on it; it is the flag the search asks before bothering.
    sync.online.value = online;
    final odoo = OdooWiring(outbox: outbox, post: fakeOdoo);
    if (configured) {
      odoo.configure(const OdooEndpoint(
          baseUrl: 'https://shop.example.com', db: 'shop', login: 'till', password: 'p'));
    }
    return PosApp(
      auth: AuthService(users: UserStore(db), hasher: FakePinHasher(), audit: audit),
      users: UserStore(db),
      catalogue: catalogue,
      orders: orders,
      outbox: outbox,
      audit: audit,
      sync: sync,
      outboxStore: SqliteOutboxStore(db),
      printers: PrinterRegistry(discovery: _NoPrinters()),
      wizards: WizardStore(db),
      shifts: ShiftStore(db),
      deviceId: 'till-1',
      endpoints: OdooEndpointStore(db),
      odoo: odoo,
      tables: TableStore(db),
      settings: SettingsStore(db),
      customers: CustomerStore(db),
      attendance: AttendanceStore(db),
      config: const TillConfig(),
    );
  }

  Order draftOnTheTill() {
    final order = Order(deviceId: 'till-1', cashierId: 'sara', type: OrderType.takeaway)
      ..lines.add(OrderLine(productId: 10, name: 'Pizza', quantity: 1, unitPrice: 100));
    orders.save(order, announce: false);
    return order;
  }

  Future<void> signIn(WidgetTester t) async {
    await t.binding.setSurfaceSize(const Size(1280, 1000));
    addTearDown(() => t.binding.setSurfaceSize(null));
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

  Future<void> searchFor(WidgetTester t, String term) async {
    await t.tap(find.byKey(const Key('customer-chip')));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const Key('customer-search')), term);
    await t.pumpAndSettle();
  }

  testWidgets('a partner the till never pulled can still be attached', (t) async {
    final order = draftOnTheTill();

    await t.pumpWidget(app());
    await signIn(t);
    await searchFor(t, 'Farida');

    expect(find.text('Farida Kamel'), findsOneWidget,
        reason: 'the shell must hand the picker a search, or the 500 cap is a wall');
    await t.tap(find.text('Farida Kamel'));
    await t.pumpAndSettle();

    expect(orders.byUuid(order.uuid)!.partnerId, 501);
    expect(orders.byUuid(order.uuid)!.customerName, 'Farida Kamel');
  });

  testWidgets('the read is a plain res.partner search of the typed term', (t) async {
    draftOnTheTill();

    await t.pumpWidget(app());
    await signIn(t);
    await searchFor(t, 'Farida');

    expect(calls, isNotEmpty);
    final args = calls.last;
    expect(args['model'], 'res.partner');
    expect(args['method'], 'search_read');
    expect(jsonEncode(args['args']), contains('Farida'));
  });

  testWidgets('a partner found once is kept, so the next order finds them offline',
      (t) async {
    draftOnTheTill();

    await t.pumpWidget(app());
    await signIn(t);
    await searchFor(t, 'Farida');
    await t.tap(find.text('Farida Kamel'));
    await t.pumpAndSettle();

    expect(catalogue.customers(search: 'Farida').single.id, 501);
    // And the ones the pull brought down are still there.
    expect(catalogue.customers(search: 'Nadia').single.name, 'Nadia Local');
  });

  testWidgets('an offline till asks nothing and still answers from disk', (t) async {
    draftOnTheTill();

    await t.pumpWidget(app(online: false));
    await signIn(t);
    await searchFor(t, 'Nadia');

    expect(calls, isEmpty, reason: 'a till with no line must not sit on a socket');
    expect(find.text('Nadia Local'), findsOneWidget);
  });

  testWidgets('a server that refuses is silent, not an error on the sell screen',
      (t) async {
    serverBroken = true;
    final order = draftOnTheTill();

    await t.pumpWidget(app());
    await signIn(t);
    await searchFor(t, 'Nadia');

    expect(find.text('Nadia Local'), findsOneWidget);
    expect(find.textContaining('Error'), findsNothing);
    // And the sale carries on: the picker still attaches the local customer.
    await t.tap(find.text('Nadia Local'));
    await t.pumpAndSettle();
    expect(orders.byUuid(order.uuid)!.customerName, 'Nadia Local');
  });

  testWidgets('two typed letters are not a search', (t) async {
    draftOnTheTill();

    await t.pumpWidget(app());
    await signIn(t);
    await searchFor(t, 'Fa');

    expect(calls, isEmpty,
        reason: 'every keystroke asking the server would be a call per letter');
  });

  testWidgets('a reply to a term the cashier has deleted is dropped', (t) async {
    draftOnTheTill();

    await t.pumpWidget(app());
    await signIn(t);
    await t.tap(find.byKey(const Key('customer-chip')));
    await t.pumpAndSettle();
    // Typed, then cut back before the answer lands. What comes back matches the
    // term that is gone, so putting it on screen would be a list that does not
    // answer what the cashier is looking at.
    await t.enterText(find.byKey(const Key('customer-search')), 'Farida');
    await t.enterText(find.byKey(const Key('customer-search')), 'Na');
    await t.pumpAndSettle();

    expect(find.text('Farida Kamel'), findsNothing);
    expect(find.text('Nadia Local'), findsOneWidget);
  });

  testWidgets('taking the money asks the server nothing', (t) async {
    draftOnTheTill();

    await t.pumpWidget(app());
    await signIn(t);
    await t.tap(find.byKey(const Key('pay')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('confirm-payment')));
    await t.pumpAndSettle();

    expect(calls, isEmpty, reason: 'nothing on a payment path may wait on a server');
    expect(orders.recent(limit: 1).single.state, OrderState.paid);
  });
}
