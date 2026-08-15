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

/// A discount typed as money, as the cashier actually gives it: enabled in
/// settings, typed on a bill rung on a real app shell, and landing on the order as
/// a percentage.
///
/// The conversion maths is covered in the domain test. What is covered here is that
/// the setting reaches the sell screen at all: a toggle nothing reads is a feature
/// nobody has.
void main() {
  late Db db;
  late OrderStore orders;
  late SettingsStore settings;
  late AuditLog audit;

  setUpAll(useSystemSqlite);
  setUp(() async {
    db = Db.open(':memory:');
    orders = OrderStore(db);
    settings = SettingsStore(db);
    audit = AuditLog(db);
    // A manager, because giving a discount is manager-gated and a PIN prompt in
    // front of the dialog is not what this test is about.
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
      settings: settings,
      customers: CustomerStore(db),
      attendance: AttendanceStore(db),
      config: const TillConfig(),
    );
  }

  void draftOnTheTill() {
    final order = Order(
      deviceId: 'till-1',
      cashierId: 'sara',
      type: OrderType.takeaway,
    )..lines.add(OrderLine(productId: 1, name: 'Pizza', quantity: 1, unitPrice: 100));
    orders.save(order, announce: false);
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

  Future<void> applyAmountOff(WidgetTester t, String amount) async {
    await t.tap(find.byKey(const Key('discount')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('discount-mode-amount')));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const Key('discount-value')), amount);
    await t.tap(find.byKey(const Key('apply-discount')));
    await t.pumpAndSettle();
  }

  testWidgets('an amount typed on the till discounts the bill by that money',
      (t) async {
    settings.allowAmountDiscount = true;
    draftOnTheTill();

    await t.pumpWidget(app());
    await signIn(t);
    await applyAmountOff(t, '25');
    await t.tap(find.byKey(const Key('hold')));
    await t.pumpAndSettle();

    final held = orders.held().single;
    expect(held.discountPercent, 25,
        reason: 'the amount must be stored as its equivalent percentage');
    expect(held.total, 75);
  });

  testWidgets('an amount past the cap is capped like a percentage is', (t) async {
    settings.allowAmountDiscount = true;
    settings.maxDiscountPercent = 10;
    draftOnTheTill();

    await t.pumpWidget(app());
    await signIn(t);
    await applyAmountOff(t, '50');
    await t.tap(find.byKey(const Key('hold')));
    await t.pumpAndSettle();

    expect(orders.held().single.discountPercent, 10);
    expect(orders.held().single.total, 90);
  });

  testWidgets('with the setting off there is no money field to type into',
      (t) async {
    draftOnTheTill();

    await t.pumpWidget(app());
    await signIn(t);
    await t.tap(find.byKey(const Key('discount')));
    await t.pumpAndSettle();

    expect(find.byKey(const Key('discount-mode-amount')), findsNothing);
  });
}
