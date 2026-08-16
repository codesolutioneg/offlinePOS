import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

/// The two keys a fast counter uses, driven through a running till: F12 takes the
/// money, Ctrl+K puts the cursor in the search box.
void main() {
  late Db db;
  late OrderStore orders;
  late AuditLog audit;

  setUpAll(useSystemSqlite);
  setUp(() async {
    db = Db.open(':memory:');
    orders = OrderStore(db);
    audit = AuditLog(db);
    CatalogueStore(db).replaceAll(
      categories: const [Category(id: 1, name: 'Pizza')],
      products: const [
        Product(id: 10, name: 'Margherita', price: 250, categoryId: 1),
        Product(id: 11, name: 'Water', price: 10, categoryId: 1),
      ],
      groups: const [],
      productGroupIds: const {},
      refreshedAt: DateTime.now().toUtc(),
    );
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
      customers: CustomerStore(db),
      attendance: AttendanceStore(db),
      config: const TillConfig(),
    );
  }

  void draftOnTheTill() {
    orders.save(
        Order(deviceId: 'till-1', cashierId: 'sara', type: OrderType.takeaway)
          ..lines.add(
              OrderLine(productId: 10, name: 'Margherita', quantity: 1, unitPrice: 250)),
        announce: false);
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

  bool searchHasFocus(WidgetTester t) =>
      t.widget<TextField>(find.byKey(const Key('search'))).focusNode!.hasFocus;

  testWidgets('F12 opens the payment sheet on the order in hand', (t) async {
    draftOnTheTill();
    await t.pumpWidget(app());
    await signIn(t);

    await t.sendKeyEvent(LogicalKeyboardKey.f12);
    await t.pumpAndSettle();

    expect(find.byKey(const Key('confirm-payment')), findsOneWidget);
    expect(find.byKey(const Key('pay-total')), findsOneWidget);
  });

  testWidgets('F12 on an empty order does nothing at all', (t) async {
    await t.pumpWidget(app());
    await signIn(t);
    // Sign-in with no draft lands on the floor, so come back to the till first.
    await t.tap(find.byKey(const Key('floor-takeaway')));
    await t.pumpAndSettle();

    await t.sendKeyEvent(LogicalKeyboardKey.f12);
    await t.pumpAndSettle();

    expect(find.byKey(const Key('confirm-payment')), findsNothing);
  });

  testWidgets('Ctrl+K puts the cursor in the search box and types nowhere else',
      (t) async {
    draftOnTheTill();
    await t.pumpWidget(app());
    await signIn(t);

    expect(searchHasFocus(t), isFalse);
    await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await t.sendKeyEvent(LogicalKeyboardKey.keyK);
    await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await t.pumpAndSettle();

    expect(searchHasFocus(t), isTrue);
    // Now typing filters the grid, which is the point of the shortcut.
    await t.enterText(find.byKey(const Key('search')), 'Water');
    await t.pumpAndSettle();
    expect(find.byKey(const Key('product-11')), findsOneWidget);
    expect(find.byKey(const Key('product-10')), findsNothing);
  });

  testWidgets('a scanned barcode still rings through the same handler', (t) async {
    // The shortcuts sit in front of the scanner, so prove the scanner still works.
    CatalogueStore(db).replaceAll(
      categories: const [Category(id: 1, name: 'Pizza')],
      products: const [
        Product(id: 10, name: 'Margherita', price: 250, categoryId: 1, barcode: '5012345'),
      ],
      groups: const [],
      productGroupIds: const {},
      refreshedAt: DateTime.now().toUtc(),
    );
    draftOnTheTill();
    await t.pumpWidget(app());
    await signIn(t);

    for (final d in '5012345'.split('')) {
      await t.sendKeyEvent(_digit(d));
    }
    await t.sendKeyEvent(LogicalKeyboardKey.enter);
    await t.pump();

    expect(find.byKey(const Key('scanned')), findsOneWidget);
  });
}

LogicalKeyboardKey _digit(String d) => switch (d) {
      '0' => LogicalKeyboardKey.digit0,
      '1' => LogicalKeyboardKey.digit1,
      '2' => LogicalKeyboardKey.digit2,
      '3' => LogicalKeyboardKey.digit3,
      '4' => LogicalKeyboardKey.digit4,
      '5' => LogicalKeyboardKey.digit5,
      '6' => LogicalKeyboardKey.digit6,
      '7' => LogicalKeyboardKey.digit7,
      '8' => LogicalKeyboardKey.digit8,
      _ => LogicalKeyboardKey.digit9,
    };
