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
import 'package:offline_pos/core/sync/batch_push.dart';
import 'package:offline_pos/core/sync/odoo_endpoint.dart';
import 'package:offline_pos/core/sync/odoo_sender.dart';
import 'package:offline_pos/core/sync/odoo_site.dart';
import 'package:offline_pos/core/sync/odoo_wiring.dart';
import 'package:offline_pos/core/sync/outbox.dart';
import 'package:offline_pos/core/sync/sync_service.dart';
import 'package:offline_pos/domain/catalogue.dart';
import 'package:offline_pos/domain/order.dart';
import 'package:offline_pos/domain/payload_balance.dart';
import 'package:offline_pos/features/sell/sell_screen.dart';
import 'package:offline_pos/features/settings/server_settings_screen.dart';

import '../db/sqlite_loader.dart';
import '../ui/fake_pin_hasher.dart';

class _NoPrinters extends PrinterDiscovery {
  @override
  Future<bool> probe(String host, {int? port}) async => false;

  @override
  Future<List<DiscoveredPrinter>> scan({int? port, Duration? budget}) async => const [];
}

/// What actually reaches Odoo, read off the wire of a running till.
///
/// Two things are proved here, both about a payload rather than about a screen:
/// that a sale states every piastre it was paid, delivery and tip included; and
/// that a shop which has asked for its night as one sales order gets exactly one
/// payload, keyed on the shift so a retry cannot book the night twice.
void main() {
  late Db db;
  late OrderStore orders;
  late SettingsStore settings;
  late SqliteOutboxStore outboxStore;
  late ShiftStore shifts;
  late AuditLog audit;
  late Outbox outbox;
  late List<Map<String, dynamic>> calls;

  setUpAll(useSystemSqlite);
  setUp(() async {
    db = Db.open(':memory:');
    shifts = ShiftStore(db);
    shifts.openShift(openingFloat: 100, cashierId: 'sara');
    orders = OrderStore(db, ownDeviceId: 'till-1');
    settings = SettingsStore(db);
    outboxStore = SqliteOutboxStore(db);
    audit = AuditLog(db);
    calls = [];
    CatalogueStore(db).replaceAll(
      categories: const [Category(id: 1, name: 'Food')],
      products: const [Product(id: 10, name: 'Pizza', price: 100, categoryId: 1)],
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
    OdooSite.shared = const OdooSite();
    db.close();
  });

  /// An Odoo that books whatever it is handed, and keeps every request.
  Future<HttpReply> fakeOdoo(
      Uri url, Map<String, String> headers, String body) async {
    final request = jsonDecode(body) as Map<String, dynamic>;
    calls.add(request);
    if (url.path.endsWith('/authenticate')) {
      return HttpReply(200, jsonEncode({'result': {'uid': 2}}),
          headers: const {'set-cookie': 'session_id=abc; Path=/'});
    }
    // The three ids are picked off Odoo's own lists now, so the lists have to be
    // there to pick from.
    final site = switch ((request['params'] as Map?)?['model']) {
      'res.company' => [
          {'id': 3, 'name': 'Downtown'}
        ],
      'pos.config' => [
          {'id': 7, 'name': 'Counter', 'company_id': false}
        ],
      'stock.warehouse' => [
          {'id': 2, 'name': 'Main', 'company_id': false}
        ],
      _ => null,
    };
    if (site != null) return HttpReply(200, jsonEncode({'result': site}));
    return HttpReply(200, jsonEncode({'result': [{'status': 'created', 'id': 9}]}));
  }

  late OdooWiring odoo;

  Widget app() {
    outbox = Outbox(store: outboxStore, senders: {});
    odoo = OdooWiring(
      outbox: outbox,
      post: fakeOdoo,
      onOrderBooked: orders.markSynced,
    );
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
        // Sweep paid sales onto the wire before a push, as the app does.
        reconcile: () async {
          for (final o in orders.awaitingSync()) {
            await outbox.enqueue('order.push', o.uuid, o.toServerPayload());
          }
        },
        // Wired exactly as the app wires it: off unless the shop turned it on,
        // and keyed on the shift the till is standing in.
        mergeBatch: BatchPush(
          outboxStore: outboxStore,
          send: odoo.pushPayload,
          enabled: () => settings.mergeBatchIntoOneSaleOrder,
          batchUuid: () => shifts.latestShift()?.uuid,
          onOrderBooked: orders.markSynced,
        ).run,
      ),
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
    );
  }

  Future<void> signIn(WidgetTester t) async {
    await t.binding.setSurfaceSize(const Size(1280, 1600));
    addTearDown(() => t.binding.setSurfaceSize(null));
    await t.pumpWidget(app());
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
    // Lands on the counter when an order was already being rung, on the floor
    // otherwise. Both carry the drawer, so nothing below needs to leave either.
  }

  Future<void> openServerSettings(WidgetTester t) async {
    await t.tap(find.byType(DrawerButton));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('nav-settings')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('set-server')));
    await t.pumpAndSettle();
    expect(find.byType(ServerSettingsScreen), findsOneWidget);
  }

  Future<void> leaveSettings(WidgetTester t) async {
    await t.pageBack();
    await t.pumpAndSettle();
    await t.pageBack();
    await t.pumpAndSettle();
  }

  /// Choose one of the three ids off its picker, the way a manager does now that
  /// they are lists rather than boxes to guess a number into.
  Future<void> pickSite(WidgetTester t, String picker, String option) async {
    await t.ensureVisible(find.byKey(Key('pick-$picker')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(Key('pick-$picker')));
    await t.pumpAndSettle();
    // The chosen row is drawn in the field as well as in the open menu.
    await t.tap(find.text(option).last);
    await t.pumpAndSettle();
  }

  /// Point the till at the fake server and name the shop, the way a manager does.
  Future<void> setTheShopUp(WidgetTester t, {bool merge = false}) async {
    await openServerSettings(t);
    await t.enterText(find.byKey(const Key('field-url')), 'https://shop.example.com');
    await t.enterText(find.byKey(const Key('field-db')), 'shop');
    await t.enterText(find.byKey(const Key('field-login')), 'till@example.com');
    // Saved once first: a till with no address has nowhere to read the pickers'
    // lists from.
    await t.ensureVisible(find.byKey(const Key('save-server')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('save-server')));
    await t.pumpAndSettle();
    await pickSite(t, 'branch', 'Downtown (3)');
    await pickSite(t, 'restaurant', 'Counter (7)');
    await pickSite(t, 'warehouse', 'Main (2)');
    if (merge) {
      await t.ensureVisible(find.byKey(const Key('merge-batch')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('merge-batch')));
      await t.pumpAndSettle();
    }
    await t.tap(find.byKey(const Key('save-server')));
    await t.pumpAndSettle();
    await leaveSettings(t);
  }

  /// Every payload the till put on the wire.
  List<Map<String, dynamic>> booked() => [
        for (final c in calls)
          if ((c['params'] as Map)['method'] == 'create_from_offline_pos')
            for (final p in (((c['params'] as Map)['args'] as List).first as List))
              (p as Map).cast<String, dynamic>()
      ];

  Future<void> payTheOrder(WidgetTester t, {String? tip}) async {
    await t.tap(find.byKey(const Key('pay')));
    await t.pumpAndSettle();
    if (tip != null) {
      await t.enterText(find.byKey(const Key('tip')), tip);
      await t.pumpAndSettle();
    }
    await t.tap(find.byKey(const Key('confirm-payment')));
    await t.pumpAndSettle();
  }

  group('a sale states the money it was paid', () {
    testWidgets('a delivery with a charge and a tip declares both on the wire',
        (t) async {
      orders.save(
        Order(deviceId: 'till-1', cashierId: 'sara', type: OrderType.delivery)
          ..lines.add(
              OrderLine(productId: 10, name: 'Pizza', quantity: 2, unitPrice: 100)),
        announce: false,
      );
      await signIn(t);
      await setTheShopUp(t);
      // The charge for the drive, typed where a cashier types it.
      await t.tap(find.byKey(const Key('customer')));
      await t.pumpAndSettle();
      await t.enterText(find.byKey(const Key('delivery-cost')), '25');
      await t.tap(find.text('Save'));
      await t.pumpAndSettle();
      await payTheOrder(t, tip: '10');

      expect(await outbox.drain(), greaterThan(0));
      final payload = booked().single;
      // 200 of food, 25 for the drive, 10 for the driver: all three have to be in
      // the sale the server builds, or it settles 235 against a 200 order.
      expect(payload['delivery_cost'], 25);
      expect(payload['tip'], 10);
      expect(payload['amount_total'], closeTo(235, 0.01));
      expect(payloadTendered(payload), closeTo(235, 0.01));
      expect(payloadLinesTotal(payload), closeTo(200, 0.01));
      expect(payloadBalances(payload), isTrue,
          reason: payloadImbalanceReason(payload) ?? '');
    });

    testWidgets('a payload that does not add up is parked, not sent', (t) async {
      await signIn(t);
      await setTheShopUp(t);
      // A sale whose payments claim more than its lines and charges do: whatever
      // built it, it must not reach the books as a booked sale.
      await outboxStore.append('order.push', 'broken-1', {
        'uuid': 'broken-1',
        'created_at': DateTime.now().toUtc().toIso8601String(),
        'lines': [
          {'product_id': 10, 'name': 'Pizza', 'quantity': 1, 'unit_price': 100.0}
        ],
        'payments': [
          {'method_id': 1, 'amount': 140.0}
        ],
      });
      await outbox.drain();

      expect(booked(), isEmpty, reason: 'nothing unbookable may be sent');
      final parked = outboxStore.dead();
      expect(parked, hasLength(1));
      expect(parked.single.payloadUuid, 'broken-1');
      expect(parked.single.lastError, contains('does not add up'));
    });
  });

  group('a shift as one sales order', () {
    /// Two paid sales sitting on the till, waiting for the close.
    void twoSalesQueued() {
      for (var i = 0; i < 2; i++) {
        final o = Order(deviceId: 'till-1', cashierId: 'sara')
          ..lines.add(
              OrderLine(productId: 10, name: 'Pizza', quantity: 1, unitPrice: 100))
          ..state = OrderState.paid;
        o.payments = [OrderPayment(methodId: 1, amount: o.total, label: 'Cash')];
        orders.save(o, announce: false);
      }
    }

    Future<void> syncNow(WidgetTester t) async {
      await t.tap(find.byType(DrawerButton));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('nav-support')));
      await t.pumpAndSettle();
      await t.ensureVisible(find.byKey(const Key('sync-now')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('sync-now')));
      await t.pumpAndSettle();
    }

    testWidgets('off by default: each sale goes out as its own order', (t) async {
      twoSalesQueued();
      await signIn(t);
      await setTheShopUp(t);
      expect(settings.mergeBatchIntoOneSaleOrder, isFalse,
          reason: 'it must not be on until Odoo can take a batch');
      await syncNow(t);

      expect(booked(), hasLength(2));
      expect(booked().every((p) => p['batch'] == null), isTrue);
    });

    testWidgets('turned on, the whole shift reaches Odoo as one payload', (t) async {
      twoSalesQueued();
      await signIn(t);
      await setTheShopUp(t, merge: true);
      expect(settings.mergeBatchIntoOneSaleOrder, isTrue);
      await syncNow(t);

      final payloads = booked();
      expect(payloads, hasLength(1), reason: 'one night, one sales order');
      final batch = payloads.single;
      // Keyed on the shift, so a retry after a timeout is the same night rather
      // than a second one.
      expect(batch['uuid'], shifts.latestShift()!.uuid);
      expect(batch['order_count'], 2);
      // Carrying where the shop is, which is the whole point of the merge.
      expect(batch['company_id'], 3);
      expect(batch['config_id'], 7);
      expect(batch['warehouse_id'], 2);
      // Nothing about a sale is lost: every line says which ticket it came from,
      // and every ticket keeps its own header.
      final lines = (batch['lines'] as List).cast<Map>();
      expect(lines, hasLength(2));
      final ticketUuids = orders.recent().map((o) => o.uuid).toSet();
      expect(lines.map((l) => l['order_uuid']).toSet(), ticketUuids);
      final tickets = (batch['orders'] as List).cast<Map>();
      expect(tickets.map((o) => o['uuid']).toSet(), ticketUuids);
      expect(tickets.every((o) => o['cashier_id'] == 'sara'), isTrue);
      expect(tickets.every((o) => o.containsKey('created_at')), isTrue);
      // And it adds up the same way a single sale does.
      expect(payloadBalances(batch.cast<String, dynamic>()), isTrue);
      // Both sales are marked synced, so the next close does not send them again.
      expect(orders.awaitingSync(), isEmpty);
    });

    testWidgets('the switch says on screen that Odoo has to change first',
        (t) async {
      await signIn(t);
      await openServerSettings(t);
      await t.ensureVisible(find.byKey(const Key('merge-batch-warning')));
      await t.pumpAndSettle();

      expect(find.byKey(const Key('merge-batch-warning')), findsOneWidget);
      expect(find.textContaining('has to be changed to accept it'), findsOneWidget);
    });
  });
}
