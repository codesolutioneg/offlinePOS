import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/app/pos_app.dart';
import 'package:offline_pos/core/audit/audit_log.dart';
import 'package:offline_pos/core/auth/auth_service.dart';
import 'package:offline_pos/core/auth/totp.dart';
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

/// The manager's second factor where it actually bites: the approval dialog of a
/// running till, with the line down (nothing here has a network at all).
void main() {
  const secret = 'GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ';

  late Db db;
  late OrderStore orders;
  late UserStore users;
  late AuditLog audit;

  setUpAll(useSystemSqlite);
  setUp(() async {
    db = Db.open(':memory:');
    orders = OrderStore(db);
    users = UserStore(db);
    audit = AuditLog(db);
    final auth =
        AuthService(users: users, hasher: FakePinHasher(), audit: audit);
    await auth.enrol(id: 'sara', name: 'Sara', pin: '1234');
    await auth.enrol(id: 'mo', name: 'Mo', pin: '9999', role: 'manager');
    WizardStore(db).dismiss(WizardId.firstSale, 'sara');
  });
  tearDown(() => db.close());

  Widget app() {
    final outbox = Outbox(store: SqliteOutboxStore(db), senders: {});
    return PosApp(
      auth: AuthService(users: users, hasher: FakePinHasher(), audit: audit),
      users: users,
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
              OrderLine(productId: 1, name: 'Pizza', quantity: 1, unitPrice: 100)),
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

  /// A cashier reaching for a discount, which their role does not carry, so the
  /// manager approval dialog opens.
  Future<void> askForADiscount(WidgetTester t) async {
    await t.tap(find.byKey(const Key('discount')));
    await t.pumpAndSettle();
  }

  Future<void> approve(WidgetTester t, {required String pin, String? code}) async {
    await t.enterText(find.byKey(const Key('manager-pin')), pin);
    if (code != null) {
      await t.enterText(find.byKey(const Key('manager-code')), code);
    }
    await t.tap(find.byKey(const Key('manager-ok')));
    await t.pumpAndSettle();
  }

  testWidgets('a till with no authenticator enrolled never asks for a code',
      (t) async {
    draftOnTheTill();
    await t.pumpWidget(app());
    await signIn(t);
    await askForADiscount(t);

    expect(find.byKey(const Key('manager-pin')), findsOneWidget);
    expect(find.byKey(const Key('manager-code')), findsNothing,
        reason: 'a shop that uses no second factor must see no second field');

    await approve(t, pin: '9999');
    expect(find.byKey(const Key('apply-discount')), findsOneWidget);
  });

  testWidgets('the manager PIN alone no longer approves once a code is enrolled',
      (t) async {
    users.setTotpSecret('mo', secret);
    draftOnTheTill();
    await t.pumpWidget(app());
    await signIn(t);
    await askForADiscount(t);

    expect(find.byKey(const Key('manager-code')), findsOneWidget);
    await approve(t, pin: '9999', code: '');

    expect(find.byKey(const Key('apply-discount')), findsNothing,
        reason: 'the right PIN with no code must not open the discount');
    expect(find.text('Manager approval failed'), findsOneWidget);
  });

  testWidgets('a wrong code is refused and says so in the trail', (t) async {
    users.setTotpSecret('mo', secret);
    draftOnTheTill();
    await t.pumpWidget(app());
    await signIn(t);
    await askForADiscount(t);
    await approve(t, pin: '9999', code: '000000');

    expect(find.byKey(const Key('apply-discount')), findsNothing);
    expect(audit.recent(event: 'manager.totp_rejected'), isNotEmpty);
  });

  testWidgets('the code from the phone approves, offline, on the clock alone',
      (t) async {
    users.setTotpSecret('mo', secret);
    draftOnTheTill();
    await t.pumpWidget(app());
    await signIn(t);
    await askForADiscount(t);
    await approve(t, pin: '9999', code: Totp.codeAt(secret, DateTime.now()));

    expect(find.byKey(const Key('apply-discount')), findsOneWidget,
        reason: 'PIN plus the current code is what gets a manager through');
  });

  testWidgets('resetting a PIN does not quietly drop the second factor', (t) async {
    users.setTotpSecret('mo', secret);
    // A PIN reset from the roster goes through enrol under the same id.
    await AuthService(users: users, hasher: FakePinHasher(), audit: audit)
        .enrol(id: 'mo', name: 'Mo', pin: '8888', role: 'manager');

    expect(users.byId('mo')!.totpSecret, secret);

    draftOnTheTill();
    await t.pumpWidget(app());
    await signIn(t);
    await askForADiscount(t);
    await approve(t, pin: '8888', code: Totp.codeAt(secret, DateTime.now()));
    expect(find.byKey(const Key('apply-discount')), findsOneWidget);
  });
}
