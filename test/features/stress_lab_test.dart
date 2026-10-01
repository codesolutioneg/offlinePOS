import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/db/catalogue_store.dart';
import 'package:offline_pos/core/db/table_store.dart';
import 'package:offline_pos/core/printing/kitchen_ticket.dart';
import 'package:offline_pos/core/printing/print_probe.dart';
import 'package:offline_pos/domain/order.dart';
import 'package:offline_pos/features/dev/stress_lab_runner.dart';
import 'package:offline_pos/features/dev/stress_lab_store.dart';
import 'package:offline_pos/features/dev/stress_note.dart';
import 'package:offline_pos/features/dev/stress_printer.dart';

import '../db/sqlite_loader.dart';
import '../stress/stress_till.dart';

/// The Stress Lab writes real rows on a till, so the part that matters most is
/// that cleanup takes every one of them back out, queue included.
void main() {
  late StressTill till;
  late StressLabRunner runner;
  late TableStore tables;

  setUpAll(useSystemSqlite);
  setUp(() {
    till = StressTill();
    tables = TableStore(till.db);
    runner = StressLabRunner(
      session: till.session(),
      catalogue: CatalogueStore(till.db),
      tables: tables,
      store: StressLabStore(db: till.db, orders: till.orders, tables: tables),
    );
  });
  tearDown(() => till.close());

  void noProgress(int done, int total) {}

  test('a flood is numbered once per order and every sale is queued', () async {
    final report = await runner.flood(20, Duration.zero, noProgress);

    expect(report.done, 20);
    expect(report.failed, 0);
    final text = report.notes.map((n) => n.fill(n.template)).join('\n');
    expect(text, contains('repeated 0'));
    expect(text, contains('not in the queue: 0'));
    expect(report.notes.any((n) => n.alarm), isFalse);
    expect(till.outboxStore.pendingSalesCount, 20);
  });

  test('another till\'s lab sales are not expected in this till\'s queue', () async {
    final own = StressLabRunner(
      session: till.session(),
      catalogue: CatalogueStore(till.db),
      tables: tables,
      store: StressLabStore(
          db: till.db, orders: till.orders, tables: tables, deviceId: till.deviceId),
    );
    final theirs = Order(deviceId: 'till-2', cashierId: 'ana', note: kStressNote)
      ..orderNo = '9001'
      ..state = OrderState.paid
      ..lines.add(OrderLine(productId: 1, name: 'x', quantity: 1, unitPrice: 10));
    till.orders.save(theirs, announce: false);

    final report = await own.flood(5, Duration.zero, noProgress);

    final paid = report.notes.firstWhere((n) => n.template.startsWith('Paid on this till'));
    expect(paid.args['paid'], 5);
    expect(paid.args['missing'], 0);
    expect(paid.alarm, isFalse);
  });

  test('cleanup tells the other tills to drop their copies', () async {
    var announced = 0;
    final store = StressLabStore(
        db: till.db, orders: till.orders, tables: tables, announceCleanup: () => announced++);
    await runner.flood(3, Duration.zero, noProgress);

    expect((await store.cleanup()).removed, 3);
    expect(announced, 1);
  });

  test('every lab sale goes through the till printing, and lost tickets are flagged',
      () async {
    final fired = <String>[];
    final receipts = <String>[];
    var n = 0;
    final printing = StressLabRunner(
      session: till.session(),
      catalogue: CatalogueStore(till.db),
      tables: tables,
      store: StressLabStore(db: till.db, orders: till.orders, tables: tables),
      printer: StressPrinter(
        fireKitchen: (o) async {
          fired.add(o.uuid);
          return ++n % 5 == 0 ? KitchenFireResult.lost : KitchenFireResult.sent;
        },
        printReceipt: (o) async => receipts.add(o.uuid),
      ),
    );

    final report = await printing.flood(10, Duration.zero, noProgress);

    expect(fired, hasLength(10));
    expect(receipts, fired, reason: 'each receipt follows its own kitchen ticket');
    final kitchen = report.notes.firstWhere((x) => x.template.startsWith('Kitchen:'));
    expect(kitchen.args['lost'], 2);
    expect(kitchen.alarm, isTrue);
  });

  test('the run tells tickets at the kitchen from ones that landed at the till', () async {
    PrintProbe? probe;
    var n = 0;
    var held = 3;
    final printing = StressLabRunner(
      session: till.session(),
      catalogue: CatalogueStore(till.db),
      tables: tables,
      store: StressLabStore(db: till.db, orders: till.orders, tables: tables),
      printer: StressPrinter(
        attachProbe: (p) => probe = p,
        heldPrints: () => held,
        fireKitchen: (o) async {
          final outcome = switch (++n % 3) {
            0 => PrintOutcome.onReceiptPrinter,
            1 => PrintOutcome.atPrinter,
            _ => PrintOutcome.spooled,
          };
          probe?.record(PrintChannel.kitchen, outcome);
          if (outcome == PrintOutcome.spooled) held++;
          return outcome == PrintOutcome.spooled
              ? KitchenFireResult.spooled
              : KitchenFireResult.sent;
        },
        printReceipt: (o) async =>
            probe?.record(PrintChannel.receipt, PrintOutcome.atPrinter),
      ),
    );

    final report = await printing.flood(6, Duration.zero, noProgress);

    StressNote note(String prefix) =>
        report.notes.firstWhere((x) => x.template.startsWith(prefix));
    final kitchen = note('Kitchen tickets:');
    expect(kitchen.args['station'], 2);
    expect(kitchen.args['rerouted'], 2);
    expect(kitchen.args['held'], 2);
    expect(kitchen.alarm, isTrue);
    expect(note('Receipts:').args['printed'], 6);
    final spool = note('Held prints');
    expect(spool.args, {'before': 3, 'after': 5});
    expect(spool.alarm, isTrue);
    expect(note('Count the paper').args, {'kitchen': 2, 'till': 8});
    expect(probe, isNull, reason: 'the till stops reporting once the run is read');
  });

  test('an empty floor gets lab tables, and every one is filled then settled', () async {
    final filled = await runner.fillTables(noProgress);
    expect(filled.done, 30);
    expect(till.orders.held(), hasLength(30));

    final settled = await runner.settleTables(noProgress);
    expect(settled.done, 30);
    expect(till.orders.held(), isEmpty);
  });

  test('cleanup removes lab orders, their queued sales and the lab tables only', () async {
    final real = till.session();
    till.ring(real, lines: 2);
    final kept = till.payCash(real);
    await runner.flood(10, Duration.zero, noProgress);
    await runner.fillTables(noProgress);

    final removed = (await runner.store.cleanup()).removed;

    expect(removed, 40);
    expect(till.orders.recent(limit: 100).map((o) => o.uuid), [kept.uuid]);
    expect(till.orders.held(), isEmpty);
    expect(till.outboxStore.pendingSalesCount, 1,
        reason: 'only the real sale may still be waiting for Odoo');
    expect(tables.inSection(kStressSection), isEmpty);
    expect(kept.state, OrderState.paid);
  });
}
