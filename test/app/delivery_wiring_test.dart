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
import 'package:offline_pos/core/db/delivery_store.dart';
import 'package:offline_pos/core/db/order_store.dart';
import 'package:offline_pos/core/db/settings_store.dart';
import 'package:offline_pos/core/db/shift_store.dart';
import 'package:offline_pos/core/db/sqlite_outbox_store.dart';
import 'package:offline_pos/core/db/table_store.dart';
import 'package:offline_pos/core/onboarding/wizard_id.dart';
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
import 'package:offline_pos/features/sell/sell_screen.dart';
import 'package:offline_pos/features/tables/table_floor_screen.dart';

import '../db/sqlite_loader.dart';
import '../ui/fake_pin_hasher.dart';

class _NoPrinters extends PrinterDiscovery {
  @override
  Future<bool> probe(String host, {int? port}) async => false;

  @override
  Future<List<DiscoveredPrinter>> scan({int? port, Duration? budget}) async => const [];
}

/// The printed text of a job, with the control bytes taken out.
String _printed(List<int> bytes) {
  final out = <int>[];
  var i = 0;
  while (i < bytes.length) {
    final b = bytes[i];
    if (b == 0x1b) {
      final cmd = i + 1 < bytes.length ? bytes[i + 1] : 0;
      i += switch (cmd) {
        0x40 => 2,
        0x61 || 0x45 || 0x21 || 0x74 => 3,
        0x70 => 5,
        _ => 2,
      };
      continue;
    }
    if (b == 0x1d) {
      i += 4;
      continue;
    }
    out.add(b);
    i++;
  }
  return String.fromCharCodes(out);
}

/// Delivery as a cashier meets it on a real app shell: the zone that prices the
/// drive, the channel the order came through, the driver who takes it, and the bag
/// already parked when the next call comes in.
///
/// None of this touches the network. Every test here would pass with the cable out,
/// which is the point: the lists are on the device and the sale never waits.
void main() {
  late Db db;
  late OrderStore orders;
  late DeliveryStore delivery;
  late AuditLog audit;
  late MemorySpoolStore spool;

  setUpAll(useSystemSqlite);
  setUp(() async {
    db = Db.open(':memory:');
    orders = OrderStore(db, ownDeviceId: 'till-1');
    delivery = DeliveryStore(db);
    audit = AuditLog(db);
    spool = MemorySpoolStore();
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
      customers: CustomerStore(db),
      delivery: delivery,
      attendance: AttendanceStore(db),
      receiptSpool: spool,
      config: const TillConfig(),
    );
  }

  /// A delivery being rung on the till, restored as the open order at sign-in so
  /// the shell lands straight on the sell screen.
  Order deliveryOnTheTill() {
    final order = Order(deviceId: 'till-1', cashierId: 'sara', type: OrderType.delivery)
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

  Future<void> openDeliveryDialog(WidgetTester t) async {
    await t.tap(find.byKey(const Key('customer')));
    await t.pumpAndSettle();
  }

  Future<void> save(WidgetTester t) async {
    await t.tap(find.text('Save'));
    await t.pumpAndSettle();
  }

  /// The open order as it stands on disk.
  Order stored(String uuid) => orders.byUuid(uuid)!;

  group('zones', () {
    testWidgets('a zone chip fills in the charge for that area', (t) async {
      final zone = delivery.addZone(name: 'Maadi', fee: 25);
      final order = deliveryOnTheTill();

      await t.pumpWidget(app());
      await signIn(t);
      await openDeliveryDialog(t);
      await t.tap(find.byKey(Key('delivery-zone-${zone.id}')));
      await t.pumpAndSettle();
      await save(t);

      expect(stored(order.uuid).deliveryCost, 25,
          reason: 'the chip must reach the order, not just the text field');
    });

    testWidgets('a typed charge still overrides the zone', (t) async {
      final zone = delivery.addZone(name: 'Maadi', fee: 25);
      final order = deliveryOnTheTill();

      await t.pumpWidget(app());
      await signIn(t);
      await openDeliveryDialog(t);
      await t.tap(find.byKey(Key('delivery-zone-${zone.id}')));
      await t.pumpAndSettle();
      await t.enterText(find.byKey(const Key('delivery-cost')), '40');
      await save(t);

      expect(stored(order.uuid).deliveryCost, 40);
    });

    testWidgets('a zone added while the till is running shows on the next order',
        (t) async {
      deliveryOnTheTill();

      await t.pumpWidget(app());
      await signIn(t);
      // The manager configures it on another screen mid-service; the dialog reads
      // the list fresh every time it opens rather than at startup.
      final zone = delivery.addZone(name: 'Zamalek', fee: 30);
      await openDeliveryDialog(t);

      expect(find.byKey(Key('delivery-zone-${zone.id}')), findsOneWidget);
    });

    testWidgets('a shop with no zones sees no zone chips', (t) async {
      deliveryOnTheTill();

      await t.pumpWidget(app());
      await signIn(t);
      await openDeliveryDialog(t);

      expect(find.byKey(const Key('delivery-cost')), findsOneWidget);
      expect(find.textContaining('Maadi'), findsNothing);
    });
  });

  group('channels', () {
    testWidgets('the channel and its own number ride on the order, never on the wire',
        (t) async {
      final channel = delivery.addChannel(name: 'Talabat', partnerId: 77);
      final order = deliveryOnTheTill();

      await t.pumpWidget(app());
      await signIn(t);
      await openDeliveryDialog(t);
      await t.tap(find.byKey(Key('delivery-channel-${channel.id}')));
      await t.pumpAndSettle();
      await t.enterText(find.byKey(const Key('delivery-company-no')), 'TLB-99182');
      await save(t);

      final saved = stored(order.uuid);
      expect(saved.deliveryChannel, 'Talabat');
      expect(saved.companyOrderNo, 'TLB-99182');
      // The aggregator is who the shop invoices.
      expect(saved.partnerId, 77);
      final payload = saved.toServerPayload();
      expect(payload['order_type'], 'delivery');
      expect(payload.containsKey('delivery_channel'), isFalse);
      expect(payload.containsKey('company_order_no'), isFalse);
      expect(payload['partner_id'], 77);
    });

    testWidgets('the order number field only appears once a channel is chosen',
        (t) async {
      final channel = delivery.addChannel(name: 'Talabat');
      deliveryOnTheTill();

      await t.pumpWidget(app());
      await signIn(t);
      await openDeliveryDialog(t);
      expect(find.byKey(const Key('delivery-company-no')), findsNothing);

      await t.tap(find.byKey(Key('delivery-channel-${channel.id}')));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('delivery-company-no')), findsOneWidget);
    });

    testWidgets('turning the sale into a takeaway drops the channel', (t) async {
      final channel = delivery.addChannel(name: 'Talabat', partnerId: 77);
      final order = deliveryOnTheTill();

      await t.pumpWidget(app());
      await signIn(t);
      await openDeliveryDialog(t);
      await t.tap(find.byKey(Key('delivery-channel-${channel.id}')));
      await t.pumpAndSettle();
      await save(t);
      await t.tap(find.byKey(const Key('order-type-takeaway')));
      await t.pumpAndSettle();

      expect(stored(order.uuid).deliveryChannel, isNull);
      expect(stored(order.uuid).companyOrderNo, isNull);
    });
  });

  group('drivers', () {
    testWidgets('the chip hands the bag to a driver', (t) async {
      final driver = delivery.addDriver(name: 'Hany', phone: '0100');
      final order = deliveryOnTheTill();

      await t.pumpWidget(app());
      await signIn(t);
      await t.tap(find.byKey(const Key('driver-chip')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(Key('driver-${driver.id}')));
      await t.pumpAndSettle();

      expect(stored(order.uuid).driverName, 'Hany');
      expect(find.widgetWithText(ActionChip, 'Hany'), findsOneWidget);
    });

    testWidgets('the driver can be taken back off the order', (t) async {
      final driver = delivery.addDriver(name: 'Hany');
      final order = deliveryOnTheTill();

      await t.pumpWidget(app());
      await signIn(t);
      await t.tap(find.byKey(const Key('driver-chip')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(Key('driver-${driver.id}')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('driver-chip')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('driver-clear')));
      await t.pumpAndSettle();

      expect(stored(order.uuid).driverName, isNull);
    });

    testWidgets('a driver never travels to the server', (t) async {
      final driver = delivery.addDriver(name: 'Hany');
      final order = deliveryOnTheTill();

      await t.pumpWidget(app());
      await signIn(t);
      await t.tap(find.byKey(const Key('driver-chip')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(Key('driver-${driver.id}')));
      await t.pumpAndSettle();

      expect(stored(order.uuid).toServerPayload().containsKey('driver_name'), isFalse);
    });

    testWidgets('the driver picker reads in Arabic', (t) async {
      SettingsStore(db).language = 'ar';
      delivery.addDriver(name: 'Hany');
      deliveryOnTheTill();

      await t.pumpWidget(app());
      await signIn(t);
      await t.tap(find.byKey(const Key('driver-chip')));
      await t.pumpAndSettle();

      expect(find.text('السائق'), findsWidgets);
      expect(find.text('بدون سائق'), findsOneWidget);
    });

    testWidgets('a shop with no drivers is told where to add them', (t) async {
      deliveryOnTheTill();

      await t.pumpWidget(app());
      await signIn(t);
      await t.tap(find.byKey(const Key('driver-chip')));
      await t.pumpAndSettle();

      expect(find.byKey(const Key('no-drivers')), findsOneWidget);
    });
  });

  group('the slip that goes out with the bag', () {
    testWidgets('carries the phone, the address and the driver', (t) async {
      final driver = delivery.addDriver(name: 'Hany');
      deliveryOnTheTill();

      await t.pumpWidget(app());
      await signIn(t);
      await openDeliveryDialog(t);
      await t.enterText(find.byKey(const Key('delivery-name')), 'Nadia');
      await t.enterText(find.byKey(const Key('delivery-phone')), '0100 123 4567');
      await t.enterText(find.byKey(const Key('delivery-address')), '12 Nile St, Maadi');
      await save(t);
      await t.tap(find.byKey(const Key('driver-chip')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(Key('driver-${driver.id}')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('pay')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('confirm-payment')));
      await t.pumpAndSettle();

      final jobs = await spool.oldestFirst(limit: 100);
      final slips = jobs.map((j) => _printed(j.bytes)).toList();
      final receipt = slips.firstWhere((s) => s.contains('TOTAL'));
      expect(receipt, contains('Phone: 0100 123 4567'));
      expect(receipt, contains('12 Nile St, Maadi'));
      expect(receipt, contains('Driver: Hany'));
      // And the kitchen's copy says who the bag belongs to.
      final ticket = slips.firstWhere((s) => s.contains('DELIVERY'));
      expect(ticket, contains('For: Nadia'));
    });
  });

  group('a delivery already waiting', () {
    /// One parked delivery, exactly as the last call left it.
    void parkADelivery({String name = 'Nadia'}) {
      final order = Order(
        deviceId: 'till-1',
        cashierId: 'sara',
        type: OrderType.delivery,
        state: OrderState.held,
        customerName: name,
        customerPhone: '0100',
      )..lines.add(OrderLine(productId: 10, name: 'Pizza', quantity: 2, unitPrice: 100));
      orders.save(order, announce: false);
    }

    testWidgets('the floor offers to pick it up instead of starting a second one',
        (t) async {
      parkADelivery();

      await t.pumpWidget(app());
      await signIn(t);
      expect(find.byType(TableFloorScreen), findsOneWidget);
      await t.tap(find.byKey(const Key('floor-delivery')));
      await t.pumpAndSettle();

      expect(find.text('Deliveries waiting'), findsOneWidget);
      await t.tap(find.byKey(Key('resume-delivery-${orders.held().single.uuid}')));
      await t.pumpAndSettle();

      // The parked bag is back in the cart, and no empty second order was started.
      expect(find.byType(SellScreen), findsOneWidget);
      expect(find.text('Nadia'), findsWidgets);
      expect(orders.held(), isEmpty);
    });

    testWidgets('starting a new one leaves the parked order parked', (t) async {
      parkADelivery();

      await t.pumpWidget(app());
      await signIn(t);
      await t.tap(find.byKey(const Key('floor-delivery')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('new-delivery')));
      await t.pumpAndSettle();

      expect(orders.held(), hasLength(1));
      expect(find.byType(SellScreen), findsOneWidget);
    });

    testWidgets('backing out of the prompt starts nothing at all', (t) async {
      parkADelivery();

      await t.pumpWidget(app());
      await signIn(t);
      await t.tap(find.byKey(const Key('floor-delivery')));
      await t.pumpAndSettle();
      // Dismiss the sheet the way a tap outside it does.
      await t.tapAt(const Offset(20, 20));
      await t.pumpAndSettle();

      expect(find.byType(TableFloorScreen), findsOneWidget,
          reason: 'a dismissed prompt must leave the cashier on the floor');
      expect(orders.held(), hasLength(1));
    });

    testWidgets('an Arabic till reads the prompt in Arabic', (t) async {
      SettingsStore(db).language = 'ar';
      parkADelivery();

      await t.pumpWidget(app());
      await signIn(t);
      await t.tap(find.byKey(const Key('floor-delivery')));
      await t.pumpAndSettle();

      expect(find.text('طلبات توصيل منتظرة'), findsOneWidget);
      expect(find.text('طلب توصيل جديد'), findsOneWidget);
    });

    testWidgets('with nothing parked the button still starts a delivery straight away',
        (t) async {
      await t.pumpWidget(app());
      await signIn(t);
      await t.tap(find.byKey(const Key('floor-delivery')));
      await t.pumpAndSettle();

      expect(find.text('Deliveries waiting'), findsNothing);
      expect(find.byType(SellScreen), findsOneWidget);
      expect(find.byKey(const Key('delivery')), findsOneWidget);
    });
  });
}
