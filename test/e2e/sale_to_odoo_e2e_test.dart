import 'dart:async';
import 'dart:convert';
import 'dart:io';

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
import 'package:offline_pos/core/sync/batch_push.dart';
import 'package:offline_pos/core/sync/http_post.dart';
import 'package:offline_pos/core/sync/odoo_endpoint.dart';
import 'package:offline_pos/core/sync/odoo_site.dart';
import 'package:offline_pos/core/sync/odoo_wiring.dart';
import 'package:offline_pos/core/sync/outbox.dart';
import 'package:offline_pos/core/sync/sync_service.dart';
import 'package:offline_pos/domain/catalogue.dart';
import 'package:offline_pos/domain/order.dart';
import 'package:offline_pos/features/sell/modifier_sheet.dart';
import 'package:offline_pos/features/sell/sell_screen.dart';
import 'package:offline_pos/features/shift/shift_screen.dart';

import '../db/sqlite_loader.dart';
import '../ui/fake_pin_hasher.dart';
import '../ui/pay_button.dart';

class _NoPrinters extends PrinterDiscovery {
  @override
  Future<bool> probe(String host, {int? port}) async => false;

  @override
  Future<List<DiscoveredPrinter>> scan({int? port, Duration? budget}) async => const [];
}

double _r2(double v) => (v * 100).roundToDouble() / 100;

/// What a till sells in a day, rung through the screens and booked into a real
/// HTTP server standing in for Odoo.
///
/// The fake does its own arithmetic from the lines it receives, per line and to
/// the piastre, the way the module does, so a payload that the till's own balance
/// check likes but Odoo would total differently still fails here.
void main() {
  late Db db;
  late OrderStore orders;
  late SettingsStore settings;
  late ShiftStore shifts;
  late SqliteOutboxStore outboxStore;
  late AuditLog audit;
  late Outbox outbox;
  late OdooWiring odoo;
  late SyncService sync;
  late HttpServer server;
  final requests = <Map<String, dynamic>>[];

  setUpAll(() {
    useSystemSqlite();
    // The test binding answers every HttpClient with a 400 unless told otherwise.
    HttpOverrides.global = null;
  });

  setUp(() async {
    useSystemSqlite();
    db = Db.open(':memory:');
    shifts = ShiftStore(db);
    shifts.openShift(openingFloat: 100, cashierId: 'sara');
    orders = OrderStore(db, ownDeviceId: 'till-1');
    settings = SettingsStore(db)..lanRolePromptDismissed = true;
    outboxStore = SqliteOutboxStore(db);
    audit = AuditLog(db);
    requests.clear();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      final body = await utf8.decoder.bind(req).join();
      final json = jsonDecode(body) as Map<String, dynamic>;
      requests.add({'path': req.uri.path, ...json});
      Object result;
      if (req.uri.path.endsWith('/authenticate')) {
        req.response.headers.set('set-cookie', 'session_id=abc; Path=/');
        result = {'uid': 2};
      } else if (((json['params'] as Map?)?['method']) == 'create_from_offline_pos') {
        result = [
          {'status': 'created', 'id': 901, 'name': 'S09001'}
        ];
      } else {
        result = [];
      }
      req.response
        ..statusCode = 200
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({'jsonrpc': '2.0', 'id': json['id'], 'result': result}));
      await req.response.close();
    });
    CatalogueStore(db).replaceAll(
      categories: const [Category(id: 1, name: 'Food')],
      products: const [
        Product(id: 10, name: 'Pizza', price: 33.33, categoryId: 1, taxRate: 14),
        Product(id: 11, name: 'Burger', price: 45.45, categoryId: 1, taxRate: 14),
        Product(id: 12, name: 'Cola', price: 12.35, categoryId: 1, taxRate: 14),
      ],
      groups: const [
        ModifierGroup(
          id: 100,
          name: 'Size',
          minSelection: 1,
          maxSelection: 1,
          required: true,
          modifiers: [
            Modifier(id: 1000, groupId: 100, name: 'Large', price: 7.77),
            Modifier(id: 1001, groupId: 100, name: 'Small', price: 0),
          ],
        ),
      ],
      productGroupIds: const {
        10: [100]
      },
      paymentMethods: const [
        PaymentMethod(id: 1, name: 'Cash', isCash: true),
        PaymentMethod(id: 2, name: 'Card'),
      ],
      refreshedAt: DateTime.now().toUtc(),
    );
    await AuthService(users: UserStore(db), hasher: FakePinHasher(), audit: audit)
        .enrol(id: 'sara', name: 'Sara', pin: '1234', role: 'manager');
    WizardStore(db).dismiss(WizardId.firstSale, 'sara');
  });

  tearDown(() async {
    OdooSite.shared = const OdooSite();
    await server.close(force: true);
    db.close();
  });

  void configureShop({required bool withBranch}) {
    final endpoint = OdooEndpoint(
        baseUrl: 'http://127.0.0.1:${server.port}',
        db: 'shop',
        login: 'till@example.com',
        password: 'secret');
    OdooEndpointStore(db).save(endpoint);
    if (withBranch) {
      settings.odooBranchId = 5;
      settings.odooCompanyId = 3;
      settings.odooRestaurantId = 7;
      settings.odooSessionPartnerId = 88;
      settings.odooSessionPartnerName = 'Session customer';
    }
    settings.serviceChargePercent = 12;
    settings.setServiceChargeOrderType(OrderType.takeaway, true);
    odoo.configure(endpoint);
  }

  Widget app() {
    outbox = Outbox(store: outboxStore, senders: {});
    odoo = OdooWiring(
      outbox: outbox,
      // The product's own HTTP transport, run on the real clock and real sockets:
      // the widget tester's zone would otherwise never let a socket complete.
      post: (url, headers, body) =>
          Zone.root.run(() => httpPost(url, headers, body)),
      onOrderBooked: (uuid, [id, name]) => orders.markSynced(uuid, id),
    );
    sync = SyncService(
      outbox: outbox,
      catalogue: CatalogueStore(db),
      outboxStore: outboxStore,
      deviceId: 'till-1',
      appVersion: 'test',
      reconcile: () async {
        for (final o in orders.awaitingSync()) {
          await outbox.enqueue('order.push', o.uuid, o.toServerPayload());
        }
      },
      mergeBatch: BatchPush(
        outboxStore: outboxStore,
        send: odoo.pushPayload,
        enabled: () => settings.mergeBatchIntoOneSaleOrder,
        batchUuid: () => shifts.latestShift()?.uuid,
        onOrderBooked: (uuid, [id, name]) {
          orders.markSynced(uuid, id);
          sync.noteOdooAck(name: name, id: id);
        },
        partnerId: () => settings.odooSessionPartnerId,
        partnerName: () => settings.odooSessionPartnerName,
        routed: () =>
            settings.odooBranchId != null || settings.odooSessionPartnerId != null,
      ).run,
    );
    return PosApp(
      auth: AuthService(users: UserStore(db), hasher: FakePinHasher(), audit: audit),
      users: UserStore(db),
      catalogue: CatalogueStore(db),
      orders: orders,
      outbox: outbox,
      audit: audit,
      sync: sync,
      outboxStore: outboxStore,
      printers: PrinterRegistry(discovery: _NoPrinters()),
      wizards: WizardStore(db),
      shifts: shifts,
      deviceId: 'till-1',
      endpoints: OdooEndpointStore(db),
      odoo: odoo,
      tables: TableStore(db),
      settings: settings,
      customers: CustomerStore(db),
      attendance: AttendanceStore(db),
      config: const TillConfig(),
    );
  }

  Future<void> boot(WidgetTester t, {required bool withBranch}) async {
    await t.binding.setSurfaceSize(const Size(1280, 2400));
    addTearDown(() => t.binding.setSurfaceSize(null));
    await t.pumpWidget(app());
    configureShop(withBranch: withBranch);
    await t.pumpAndSettle();
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

  Future<void> toTheCounter(WidgetTester t) async {
    if (find.byKey(const Key('product-10')).evaluate().isEmpty) {
      final quick = find.byKey(const Key('floor-action-table'));
      await t.tap(quick.evaluate().isNotEmpty
          ? quick
          : find.byKey(const Key('new-order')));
      await t.pumpAndSettle();
    }
    if (find.byKey(const Key('product-10')).evaluate().isEmpty) {
        }
    expect(find.byKey(const Key('product-10')), findsOneWidget);
    await t.tap(find.byKey(const Key('order-type-takeaway')));
    await t.pumpAndSettle();
  }

  Future<void> ring(WidgetTester t, int productId, {int times = 1}) async {
    for (var i = 0; i < times; i++) {
      await t.tap(find.byKey(Key('product-$productId')));
      await t.pumpAndSettle();
    }
  }

  Future<void> chooseLarge(WidgetTester t) async {
    expect(find.byType(ModifierSheet), findsOneWidget);
    await t.tap(find.byKey(const Key('mod-1000')));
    await t.pumpAndSettle();
    if (find.byKey(const Key('confirm-modifiers')).evaluate().isNotEmpty) {
      await t.tap(find.byKey(const Key('confirm-modifiers')));
      await t.pumpAndSettle();
    }
  }

  Future<void> tenPercentOff(WidgetTester t) async {
    await t.tap(find.byKey(const Key('discount')));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const Key('discount-value')), '10');
    await t.tap(find.byKey(const Key('apply-discount')));
    await t.pumpAndSettle();
  }

  Future<void> payCash(WidgetTester t) async {
    await t.tap(findPay());
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('method-1')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('confirm-payment')));
    await t.pumpAndSettle();
  }

  Future<void> payCard(WidgetTester t) async {
    await t.tap(findPay());
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('method-2')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('confirm-payment')));
    await t.pumpAndSettle();
  }

  /// Part cash, the rest on the card.
  Future<void> paySplit(WidgetTester t, String cash) async {
    await t.tap(findPay());
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('split-toggle')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('method-1')));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const Key('tender-amount')), cash);
    await t.tap(find.byKey(const Key('add-tender')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('method-2')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('add-tender')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('confirm-payment')));
    await t.pumpAndSettle();
  }

  Future<void> ringTheDay(WidgetTester t) async {
    // Sale 1: a large pizza twice over, cola, 10% off the bill, cash.
    await toTheCounter(t);
    await ring(t, 10);
    await chooseLarge(t);
    await ring(t, 10);
    await chooseLarge(t);
    await ring(t, 12, times: 3);
    await tenPercentOff(t);
    await payCash(t);
    // Sale 2: burgers and a cola, part cash part card.
    await toTheCounter(t);
    await ring(t, 11, times: 2);
    await ring(t, 12);
    await paySplit(t, '50');
    // Sale 3: one burger on the card.
    await toTheCounter(t);
    await ring(t, 11);
    await payCard(t);
  }

  Future<String?> closeTheShift(WidgetTester t, {required String counted}) async {
    // The way a cashier reaches the cash-up.
    await t.tap(find.byTooltip('Open navigation menu'));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('nav-shift')));
    await t.pumpAndSettle();
    expect(find.byType(ShiftScreen), findsOneWidget);
    await t.ensureVisible(find.byKey(const Key('close-shift')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('close-shift')));
    await t.pumpAndSettle();
    for (final d in counted.split('')) {
      await t.tap(find.byKey(d == '.' ? const Key('key-.') : Key('key-$d')));
      await t.pump();
    }
    await t.tap(find.byKey(const Key('keypad-ok')));
    await t.pumpAndSettle();
    if (find.byKey(const Key('cash-variance-block')).evaluate().isNotEmpty) {
      fail('the drawer count was refused: counted $counted');
    }
    await t.tap(find.byKey(const Key('confirm-close-shift')));
    // Real sockets: the clock the widgets run on is fake, the server is not.
    for (var i = 0; i < 100; i++) {
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await t.pump(const Duration(milliseconds: 100));
      if (find.text('Session closed').evaluate().isNotEmpty &&
          find.byType(CircularProgressIndicator).evaluate().isEmpty) {
        break;
      }
    }
    await t.pump(const Duration(milliseconds: 100));
    return null;
  }

  List<Map<String, dynamic>> bookings() => [
        for (final r in requests)
          if ((r['params'] as Map?)?['method'] == 'create_from_offline_pos')
            for (final p in (((r['params'] as Map)['args'] as List).first as List))
              (p as Map).cast<String, dynamic>()
      ];

  /// Odoo's own sum for a payload: each line to the piastre times its quantity to
  /// the piastre, tax on each line rounded, then the charges that ride as fields.
  double oddoTotal(Map<String, dynamic> p) {
    var sum = 0.0;
    for (final raw in p['lines'] as List) {
      final l = (raw as Map).cast<String, dynamic>();
      final rate = (l['tax_rate'] as num? ?? 0).toDouble();
      final qty = (l['quantity'] as num).toDouble();
      final base = _r2(_r2((l['unit_price'] as num).toDouble()) * qty);
      sum += base + _r2(base * rate / 100);
      for (final m in (l['modifiers'] as List? ?? const [])) {
        final mod = (m as Map).cast<String, dynamic>();
        if (mod['product_id'] == null) continue;
        final mb = _r2(_r2((mod['unit_price'] as num).toDouble()) *
            ((mod['quantity'] as num).toDouble() * qty));
        sum += mb + _r2(mb * rate / 100);
      }
    }
    for (final k in ['delivery_cost', 'tip', 'service_fee']) {
      sum += (p[k] as num? ?? 0).toDouble();
    }
    return sum;
  }

  testWidgets('A: taxed sales rung on the till reach Odoo as one balanced shift order',
      (t) async {
    await boot(t, withBranch: true);
    await ringTheDay(t);

    final paid = orders.recent().where((o) => o.state == OrderState.paid).toList();
    expect(paid, hasLength(3), reason: 'three sales were rung');
    final tillTotal = paid.fold<double>(0, (a, o) => a + o.total);
    expect(paid.any((o) => o.serviceCharge > 0), isTrue);
    expect(paid.any((o) => o.discountPercent > 0), isTrue);
    expect(paid.any((o) => o.lines.any((l) => l.modifiers.isNotEmpty)), isTrue);
    expect(paid.any((o) => o.payments.length == 2), isTrue);

    final cash = paid
        .expand((o) => o.payments)
        .where((p) => p.methodId == 1)
        .fold<double>(0, (a, p) => a + p.amount);
    await closeTheShift(t, counted: (100 + cash).toStringAsFixed(2));

    final sent = bookings();
    expect(find.textContaining('Odoo order: S09001'), findsOneWidget,
        reason: 'the close screen names the booked sale order');
    expect(sent, hasLength(1), reason: 'one shift, one sales order');
    final batch = sent.single;
    expect(batch['uuid'], shifts.latestShift()!.uuid);
    expect(batch['order_count'], 3);
    expect(batch['partner_id'], 88);
    expect(batch['company_id'], 3);
    expect(batch['config_id'], 7);
    final tendered = (batch['payments'] as List)
        .fold<double>(0, (a, p) => a + ((p as Map)['amount'] as num).toDouble());
    expect(oddoTotal(batch), closeTo(tillTotal, 0.005),
        reason: 'Odoo totals the lines to the same piastre the till charged');
    expect(tendered, closeTo(tillTotal, 0.005));
    expect(outboxStore.dead(), isEmpty, reason: 'nothing parked');
    expect(await outboxStore.pending(limit: 50), isEmpty);
    expect(orders.awaitingSync(), isEmpty);
    expect(shifts.currentOpenShift(), isNull, reason: 'the shift is closed');
  });

  testWidgets('B: a till with no branch or session customer still closes, sales stay queued',
      (t) async {
    await boot(t, withBranch: false);
    // Two sales, enough for a merge even without a session customer.
    await toTheCounter(t);
    await ring(t, 11);
    await payCard(t);
    await toTheCounter(t);
    await ring(t, 12);
    await payCard(t);
    await closeTheShift(t, counted: '100');

    expect(shifts.currentOpenShift(), isNull, reason: 'the Z completed');
    expect(find.textContaining('pick the branch under Server settings'), findsOneWidget,
        reason: 'the close says why the sale is still queued');
    expect(bookings(), isEmpty, reason: 'nothing is sent without somewhere to book it');
    expect(outboxStore.dead(), isEmpty, reason: 'queued, not parked');
    expect((await outboxStore.pending(limit: 50)).where((e) => e.kind == 'order.push'),
        hasLength(2));
    expect(orders.awaitingSync(), hasLength(2));
  });
}
