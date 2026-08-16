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
import 'package:offline_pos/core/printing/spool_store.dart';
import 'package:offline_pos/core/sync/odoo_endpoint.dart';
import 'package:offline_pos/core/sync/odoo_wiring.dart';
import 'package:offline_pos/core/sync/outbox.dart';
import 'package:offline_pos/core/sync/sync_service.dart';
import 'package:offline_pos/domain/catalogue.dart';
import 'package:offline_pos/domain/order.dart';
import 'package:offline_pos/features/sell/sell_screen.dart';

import '../db/sqlite_loader.dart';
import '../printing/strip_escpos.dart';
import '../ui/fake_pin_hasher.dart';

/// Nothing answers on the LAN, so every slip lands in the spool instead of on
/// paper. That is both how a test reads what would have printed and the case that
/// matters: taking money must never wait on a printer.
class _NoPrinters extends PrinterDiscovery {
  @override
  Future<bool> probe(String host, {int? port}) async => false;

  @override
  Future<List<DiscoveredPrinter>> scan({int? port, Duration? budget}) async => const [];
}

/// The payment experience, driven on a real app shell the way a cashier works it:
/// everything about taking money is asked in the payment sheet, and a payment that
/// leaves the table part paid puts its own detail slip on the roll.
void main() {
  late Db db;
  late OrderStore orders;
  late MemorySpoolStore spool;
  late AuditLog audit;
  late SqliteOutboxStore outboxStore;

  setUpAll(useSystemSqlite);
  setUp(() async {
    db = Db.open(':memory:');
    orders = OrderStore(db, ownDeviceId: 'till-1');
    outboxStore = SqliteOutboxStore(db);
    spool = MemorySpoolStore();
    audit = AuditLog(db);
    await AuthService(users: UserStore(db), hasher: FakePinHasher(), audit: audit)
        .enrol(id: 'sara', name: 'Sara', pin: '1234');
    WizardStore(db).dismiss(WizardId.firstSale, 'sara');
    CatalogueStore(db).replaceAll(
      categories: const [Category(id: 1, name: 'Food')],
      products: const [
        Product(id: 10, name: 'Pizza', price: 250, categoryId: 1),
        Product(id: 11, name: 'Cola', price: 50, categoryId: 1),
      ],
      groups: const [],
      productGroupIds: const {},
      paymentMethods: const [
        PaymentMethod(id: 1, name: 'Cash', isCash: true),
        PaymentMethod(id: 2, name: 'Card'),
      ],
      refreshedAt: DateTime.now().toUtc(),
    );
  });
  tearDown(() => db.close());

  Widget app() {
    final outbox = Outbox(store: outboxStore, senders: {});
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
      receiptSpool: spool,
      wizards: WizardStore(db),
      shifts: ShiftStore(db),
      deviceId: 'till-1',
      endpoints: OdooEndpointStore(db),
      odoo: OdooWiring(outbox: outbox),
      tables: TableStore(db),
      settings: SettingsStore(db),
      customers: CustomerStore(db),
      attendance: AttendanceStore(db),
    );
  }

  /// A seated table already on the till, so signing in lands on the order rather
  /// than on the floor plan. Pizza + Cola = 300.
  Order tableOnTheTill({OrderType type = OrderType.dineIn, double service = 0}) {
    final order = Order(
      deviceId: 'till-1',
      cashierId: 'sara',
      type: type,
      tableLabel: type == OrderType.dineIn ? '5' : null,
      serviceChargePercent: service,
    )
      ..lines.add(OrderLine(productId: 10, name: 'Pizza', quantity: 1, unitPrice: 250))
      ..lines.add(OrderLine(productId: 11, name: 'Cola', quantity: 1, unitPrice: 50));
    orders.save(order, announce: false);
    return order;
  }

  Future<void> signIn(WidgetTester t) async {
    // Room for the sheet to lay out the way a real till has: this is a 10 inch
    // screen, not a phone.
    await t.binding.setSurfaceSize(const Size(1280, 1000));
    addTearDown(() => t.binding.setSurfaceSize(null));
    await t.pumpWidget(app());
    await t.tap(find.byKey(const Key('user-sara')));
    await t.pumpAndSettle();
    for (final d in '1234'.split('')) {
      await t.tap(find.byKey(Key('key-$d')));
      await t.pump();
    }
    await t.tap(find.byKey(const Key('pin-ok')));
    // The key derivation resolves off the frame pipeline, so give the microtask
    // queue real time rather than trusting a single settle.
    for (var i = 0; i < 20; i++) {
      await t.pump(const Duration(milliseconds: 50));
      if (find.byType(SellScreen).evaluate().isNotEmpty) break;
    }
    await t.pumpAndSettle();
  }

  /// The text of the one slip whose spool reference starts with [prefix].
  Future<String> slip(String prefix) async {
    final jobs = await spool.oldestFirst(limit: 100);
    final held = jobs.where((j) => (j.reference ?? '').startsWith(prefix)).toList();
    expect(held, hasLength(1), reason: 'expected exactly one $prefix slip');
    return strippedText(held.single.bytes);
  }

  Future<int> slipCount(String prefix) async {
    final jobs = await spool.oldestFirst(limit: 100);
    return jobs.where((j) => (j.reference ?? '').startsWith(prefix)).length;
  }

  testWidgets('the payment sheet asks how the bill is being paid, in one place',
      (t) async {
    tableOnTheTill();
    await signIn(t);

    await t.tap(find.byKey(const Key('pay')));
    await t.pumpAndSettle();

    // The first step of the payment sheet, which is where a cashier looks for it.
    expect(find.byKey(const Key('pay-mode-all')), findsOneWidget);
    expect(find.byKey(const Key('pay-mode-evenly')), findsOneWidget);
    expect(find.byKey(const Key('pay-mode-guest')), findsOneWidget);
    expect(find.byKey(const Key('pay-mode-item')), findsOneWidget);
    // And what is owed is on the sheet the whole time.
    expect(find.byKey(const Key('pay-total')), findsOneWidget);
  });

  testWidgets('a counter sale is never asked how to split a table it has not got',
      (t) async {
    tableOnTheTill(type: OrderType.takeaway);
    await signIn(t);

    await t.tap(find.byKey(const Key('pay')));
    await t.pumpAndSettle();

    expect(find.byKey(const Key('pay-mode-evenly')), findsNothing);
    expect(find.byKey(const Key('confirm-payment')), findsOneWidget);
  });

  testWidgets('an even share is taken from the payment sheet and prints its own slip',
      (t) async {
    final order = tableOnTheTill();
    await signIn(t);

    await t.tap(find.byKey(const Key('pay')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('pay-mode-evenly')));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const Key('split-ways')), '2');
    await t.tap(find.byKey(const Key('split-ways-ok')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('method-1'))); // cash
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('confirm-payment')));
    await t.pumpAndSettle();

    // Half the money is in and the table is still open on the rest.
    final tab = orders.byUuid(order.uuid)!;
    expect(tab.amountPaid, closeTo(150, 0.01));
    expect(tab.balance, closeTo(150, 0.01));
    expect(tab.state, OrderState.held);

    // The share put its own detail slip on the roll: what was paid, and what the
    // table still owes. No sale receipt yet, because the tab is not settled.
    final paper = await slip('part-${order.uuid}-');
    expect(paper, contains('PAYMENT'));
    expect(paper, contains('PAID NOW'));
    expect(paper, contains('STILL OWED'));
    expect(paper, contains('150.00'));
    expect(paper, contains('Table 5'));
    // Not a tax receipt: that one prints when the tab settles.
    expect(paper, contains('NOT A TAX RECEIPT'));
    expect(await slipCount(order.uuid), 0);
  });

  testWidgets('the last share settles the tab and prints the receipt, not another slip',
      (t) async {
    final order = tableOnTheTill();
    await signIn(t);

    for (var share = 0; share < 2; share++) {
      await t.tap(find.byKey(const Key('pay')));
      await t.pumpAndSettle();
      if (share == 0) {
        await t.tap(find.byKey(const Key('pay-mode-evenly')));
        await t.pumpAndSettle();
        await t.enterText(find.byKey(const Key('split-ways')), '2');
        await t.tap(find.byKey(const Key('split-ways-ok')));
        await t.pumpAndSettle();
      }
      await t.tap(find.byKey(const Key('method-1')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('confirm-payment')));
      await t.pumpAndSettle();
    }

    expect(orders.byUuid(order.uuid)!.state, OrderState.paid);
    // One detail slip for the share that left money owing, and the sale receipt for
    // the one that settled it. The settling payment is not slipped twice.
    expect(await slipCount('part-${order.uuid}-'), 1);
    final receipt = await slip(order.uuid);
    expect(receipt, contains('TOTAL'));
  });

  testWidgets('a part-paid tab shows what is left, not the whole bill again',
      (t) async {
    tableOnTheTill();
    await signIn(t);

    await t.tap(find.byKey(const Key('pay')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('pay-mode-evenly')));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const Key('split-ways')), '2');
    await t.tap(find.byKey(const Key('split-ways-ok')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('method-1')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('confirm-payment')));
    await t.pumpAndSettle();

    await t.tap(find.byKey(const Key('pay')));
    await t.pumpAndSettle();

    // The running balance is on the sheet, so the cashier can see the tab is half
    // settled instead of taking the figure on trust.
    final running = t.widget<Text>(find.byKey(const Key('running-balance')));
    expect(running.data, contains('300.00')); // the whole bill
    expect(running.data, contains('150.00')); // taken off it so far
    // And the figure being charged is the balance, not the bill all over again.
    expect(t.widget<Text>(find.byKey(const Key('pay-total'))).data, '150.00');
  });

  testWidgets('paying by item is reached from the payment sheet and slips the rest',
      (t) async {
    final order = tableOnTheTill();
    await signIn(t);

    await t.tap(find.byKey(const Key('pay')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('pay-mode-item')));
    await t.pumpAndSettle();

    // Take the Cola off as its own check, leaving the Pizza on the table.
    await t.tap(find.descendant(
        of: find.widgetWithText(ListTile, 'Cola'), matching: find.byType(Checkbox)));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('pick-confirm')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('method-1')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('confirm-payment')));
    await t.pumpAndSettle();

    // The check is its own paid sale, and the table keeps the Pizza.
    expect(orders.byUuid(order.uuid)!.lines.single.productId, 10);
    // The check's own slip says what it covered and what the table still owes.
    final paper = await slip('part-');
    expect(paper, contains('Cola'));
    expect(paper, contains('PAID NOW'));
    expect(paper, contains('STILL OWED'));
    expect(paper, contains('250.00'));
  });

  testWidgets('a check asks for the service charge it is about to book', (t) async {
    // Quoting the food alone left the table eating the service on every split guest.
    tableOnTheTill(service: 10);
    await signIn(t);

    await t.tap(find.byKey(const Key('pay')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('pay-mode-item')));
    await t.pumpAndSettle();
    await t.tap(find.descendant(
        of: find.widgetWithText(ListTile, 'Cola'), matching: find.byType(Checkbox)));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('pick-confirm')));
    await t.pumpAndSettle();

    // Cola at 50 plus 10% service.
    expect(t.widget<Text>(find.byKey(const Key('pay-total'))).data, '55.00');

    await t.tap(find.byKey(const Key('method-1')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('confirm-payment')));
    await t.pumpAndSettle();

    final check = orders.recent(limit: 5).firstWhere((o) => o.state == OrderState.paid);
    expect(check.total, closeTo(55, 0.01));
    expect(check.amountPaid, closeTo(55, 0.01));
  });

  testWidgets('a dead printer never stands between the cashier and the money',
      (t) async {
    final order = tableOnTheTill();
    await signIn(t);

    await t.tap(find.byKey(const Key('pay')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('pay-mode-evenly')));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const Key('split-ways')), '2');
    await t.tap(find.byKey(const Key('split-ways-ok')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('method-1')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('confirm-payment')));
    await t.pumpAndSettle();

    // Nothing on the LAN answered, yet the money is booked and the till is back on
    // the order. The slip is held, not lost.
    expect(orders.byUuid(order.uuid)!.amountPaid, closeTo(150, 0.01));
    expect(find.byType(SellScreen), findsOneWidget);
    expect(await slipCount('part-'), 1);
  });
}
