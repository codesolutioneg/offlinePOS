import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/app/pos_session.dart';
import 'package:offline_pos/core/audit/audit_log.dart';
import 'package:offline_pos/core/db/catalogue_store.dart';
import 'package:offline_pos/core/db/database.dart';
import 'package:offline_pos/core/db/order_store.dart';
import 'package:offline_pos/core/db/sqlite_outbox_store.dart';
import 'package:offline_pos/core/sync/outbox.dart';
import 'package:offline_pos/domain/catalogue.dart';
import 'package:offline_pos/domain/order.dart';
import 'package:offline_pos/features/sell/split_check_screen.dart';

import '../db/sqlite_loader.dart';

const pizza = Product(id: 10, name: 'Pizza', price: 100);
const cola = Product(id: 11, name: 'Cola', price: 20);
const cake = Product(id: 12, name: 'Cake', price: 40);

void main() {
  late Db db;
  late PosSession session;
  late OrderStore orders;

  setUpAll(useSystemSqlite);
  setUp(() {
    db = Db.open(':memory:');
    orders = OrderStore(db);
    session = PosSession(
      catalogue: CatalogueStore(db),
      orders: orders,
      outbox: Outbox(store: SqliteOutboxStore(db), senders: const {}),
      audit: AuditLog(db),
      deviceId: 'till-1',
      cashierId: 'sara',
    );
    session.setOrderType(OrderType.dineIn);
    session.claimSeat('7');
  });
  tearDown(() => db.close());

  String lineFor(int productId) =>
      session.current.lines.firstWhere((l) => l.productId == productId).uuid;

  group('splitIntoChecks', () {
    test('each guest becomes a held check linked on the same table', () {
      session.addProduct(pizza);
      session.addProduct(cola);
      session.addProduct(cake);
      final made = session.splitIntoChecks([
        [(line: lineFor(10), quantity: 1)],
        [(line: lineFor(11), quantity: 1), (line: lineFor(12), quantity: 1)],
      ]);

      expect(made, hasLength(2));
      expect(made.first.uuid, session.current.uuid);
      expect(session.current.lines.map((l) => l.name), ['Pizza']);
      final second = orders.byUuid(made[1].uuid)!;
      expect(second.state, OrderState.held);
      expect(second.tableLabel, '7');
      expect(second.lines.map((l) => l.name), ['Cola', 'Cake']);
      expect(second.linkedOrderUuids, contains(session.current.uuid));
      expect(orders.byUuid(session.current.uuid)!.linkedOrderUuids,
          contains(second.uuid));
    });

    test('units of one line can go to different guests', () {
      session.addProduct(pizza);
      session.addProduct(pizza);
      session.addProduct(pizza);
      final line = session.current.lines.single;
      expect(line.quantity, 3);

      final made = session.splitIntoChecks([
        [(line: line.uuid, quantity: 1)],
        [(line: line.uuid, quantity: 2)],
      ]);

      expect(session.current.lines.single.quantity, 1);
      expect(orders.byUuid(made[1].uuid)!.lines.single.quantity, 2);
    });

    test('an item shared between guests splits its price and adds back up', () {
      session.addProduct(pizza);
      final line = lineFor(10);
      final made = session.splitIntoChecks([
        [(line: line, quantity: 1 / 3)],
        [(line: line, quantity: 1 / 3)],
        [(line: line, quantity: 1 - 2 / 3)],
      ]);

      expect(made, hasLength(3));
      final sum = made
          .map((o) => orders.byUuid(o.uuid)!.subtotal)
          .fold(0.0, (a, b) => a + b);
      expect(sum, closeTo(100, 1e-9));
    });

    test('the table\'s checks can be laid out again, and an emptied one closes',
        () {
      session.addProduct(pizza);
      session.addProduct(cola);
      session.addProduct(cake);
      final made = session.splitIntoChecks([
        [(line: lineFor(10), quantity: 1)],
        [(line: lineFor(11), quantity: 1)],
        [(line: lineFor(12), quantity: 1)],
      ]);
      expect(session.tableChecks(), hasLength(3));
      final colaLine = orders.byUuid(made[1].uuid)!.lines.single.uuid;
      final cakeLine = orders.byUuid(made[2].uuid)!.lines.single.uuid;

      final again = session.splitIntoChecks([
        [(line: lineFor(10), quantity: 1), (line: cakeLine, quantity: 1)],
        [(line: colaLine, quantity: 1)],
      ], among: session.tableChecks());

      expect(again.map((o) => o.uuid), [made[0].uuid, made[1].uuid]);
      expect(session.current.lines.map((l) => l.name), ['Pizza', 'Cake']);
      expect(orders.byUuid(made[2].uuid), isNull);
      expect(session.tableChecks(), hasLength(2));
      expect(orders.byUuid(made[1].uuid)!.linkedOrderUuids,
          isNot(contains(made[2].uuid)));
    });

    test('a bill printed from the split marks that check, not the one on screen',
        () {
      session.addProduct(pizza);
      session.addProduct(cola);
      final made = session.splitIntoChecks([
        [(line: lineFor(10), quantity: 1)],
        [(line: lineFor(11), quantity: 1)],
      ]);
      session.markBillPrinted(made[1]);
      expect(orders.byUuid(made[1].uuid)!.billPrintedAt, isNotNull);
      expect(session.current.billPrintedAt, isNull);
    });

    test('unsplitting puts the table back on one bill, shared items made whole',
        () {
      session.addProduct(pizza);
      session.addProduct(cola);
      final pizzaLine = lineFor(10);
      final made = session.splitIntoChecks([
        [(line: pizzaLine, quantity: 0.5)],
        [(line: pizzaLine, quantity: 0.5), (line: lineFor(11), quantity: 1)],
      ]);
      final all = [
        for (final o in session.tableChecks())
          for (final l in o.lines) (line: l.uuid, quantity: l.quantity),
      ];
      final back = session.splitIntoChecks([all], among: session.tableChecks());

      expect(back, hasLength(1));
      expect(orders.byUuid(made[1].uuid), isNull);
      expect(session.tableChecks(), hasLength(1));
      final pizzaRows =
          session.current.lines.where((l) => l.productId == 10).toList();
      expect(pizzaRows.single.quantity, 1);
      expect(session.current.subtotal, closeTo(120, 1e-9));
    });

    test('a single check leaves the bill alone', () {
      session.addProduct(pizza);
      final before = session.current.lines.single.uuid;
      final made = session.splitIntoChecks([
        [(line: before, quantity: 1)],
      ]);
      expect(made, hasLength(1));
      expect(session.current.lines.single.uuid, before);
    });
  });

  group('SplitCheckScreen', () {
    List<List<SplitShare>>? result;

    Order check(List<OrderLine> lines) =>
        Order(deviceId: 'till-1', cashierId: 'sara', lines: lines);

    Future<void> open(WidgetTester t, List<OrderLine> lines,
        {List<Order>? checks,
        Future<List<Order>> Function(List<List<SplitShare>>, int, SplitAction)?
            onAction}) async {
      t.view.physicalSize = const Size(1366, 768);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      result = null;
      await t.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: ElevatedButton(
              key: const Key('go'),
              onPressed: () async {
                result = await Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => SplitCheckScreen(
                    checks: checks ?? [check(lines)],
                    formatAmount: (v) => v.toStringAsFixed(2),
                    guests: 2,
                    onAction: onAction,
                  ),
                ));
              },
              child: const Text('go'),
            ),
          ),
        ),
      ));
      await t.tap(find.byKey(const Key('go')));
      await t.pumpAndSettle();
    }

    Future<void> moveCola(WidgetTester t) async {
      await t.tap(find.byKey(const Key('split-piece-1')));
      await t.pump();
      await t.tap(find.byKey(const Key('split-body-1')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('split-count-2')));
      await t.pumpAndSettle();
    }

    List<OrderLine> sample() => [
          OrderLine(productId: 10, name: 'Pizza', quantity: 1, unitPrice: 100),
          OrderLine(productId: 11, name: 'Cola', quantity: 2, unitPrice: 20),
        ];

    testWidgets('everything starts on guest 1; tap then tap a guest moves it',
        (t) async {
      final lines = sample();
      await open(t, lines);

      expect(find.byKey(const Key('split-col-0')), findsOneWidget);
      expect(find.byKey(const Key('split-col-1')), findsOneWidget);
      expect(find.text('140.00'), findsOneWidget);

      await moveCola(t);
      expect(find.text('40.00'), findsNWidgets(2));

      await t.tap(find.byKey(const Key('split-done')));
      await t.pumpAndSettle();
      expect(result, hasLength(2));
      expect(result![0].single.line, lines[0].uuid);
      expect(result![1].single.line, lines[1].uuid);
    });

    testWidgets('Add opens a new guest and takes the selected items',
        (t) async {
      final lines = sample();
      await open(t, lines);
      expect(find.byKey(const Key('split-col-2')), findsNothing);
      await t.tap(find.byKey(const Key('split-piece-0')));
      await t.pump();
      await t.tap(find.byKey(const Key('split-add')));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('split-col-2')), findsOneWidget);
      expect(find.byKey(const Key('split-total-2')), findsOneWidget);
      expect(
          (t.widget<Text>(find.byKey(const Key('split-total-2')))).data, '100.00');
    });

    testWidgets('moving an item of several asks how many go', (t) async {
      await open(t, [
        OrderLine(productId: 13, name: 'Burger', quantity: 5, unitPrice: 10),
      ]);
      await t.tap(find.byKey(const Key('split-piece-0')));
      await t.pump();
      await t.tap(find.byKey(const Key('split-body-1')));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('split-count')), findsOneWidget);
      expect(find.byKey(const Key('split-count-5')), findsOneWidget);
      await t.tap(find.byKey(const Key('split-count-2')));
      await t.pumpAndSettle();
      expect(find.text('3× Burger'), findsOneWidget);
      expect(find.text('2× Burger'), findsOneWidget);

      // Moving one more joins the row already there.
      await t.tap(find.text('3× Burger'));
      await t.pump();
      await t.tap(find.byKey(const Key('split-body-1')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('split-count-1')));
      await t.pumpAndSettle();
      expect(find.text('3× Burger'), findsOneWidget);
      expect(find.text('2× Burger'), findsOneWidget);
      expect(t.widget<Text>(find.byKey(const Key('split-total-1'))).data,
          '30.00');
    });

    testWidgets('Split Item shares an item between the guests ticked',
        (t) async {
      await open(t, [
        OrderLine(productId: 13, name: 'Burger', quantity: 5, unitPrice: 10),
      ]);
      await t.tap(find.byKey(const Key('split-piece-0')));
      await t.pump();
      await t.tap(find.byKey(const Key('split-item')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('split-guests-ok')));
      await t.pumpAndSettle();
      expect(find.text('2 1/2× Burger'), findsNWidgets(2));
      expect(t.widget<Text>(find.byKey(const Key('split-total-1'))).data,
          '25.00');
    });

    testWidgets('Split Item can add a guest from its own dialog', (t) async {
      await open(t, sample());
      await t.tap(find.byKey(const Key('split-piece-0')));
      await t.pump();
      await t.tap(find.byKey(const Key('split-item')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('split-guest-add')));
      await t.pump();
      await t.tap(find.byKey(const Key('split-guest-0')));
      await t.pump();
      await t.tap(find.byKey(const Key('split-guests-ok')));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('split-col-2')), findsOneWidget);
      expect(find.text('1/2 Pizza'), findsNWidgets(2));
      expect(t.widget<Text>(find.byKey(const Key('split-total-0'))).data,
          '40.00');
    });

    testWidgets('sharing one item puts a slice on each guest', (t) async {
      await open(t, sample());
      await t.tap(find.byKey(const Key('split-piece-0')));
      await t.pump();
      await t.tap(find.byKey(const Key('split-item')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('split-guests-ok')));
      await t.pumpAndSettle();
      expect(find.text('1/2 Pizza'), findsNWidgets(2));

      await t.tap(find.text('1/2 Pizza').first);
      await t.pump();
      await t.tap(find.byKey(const Key('split-unsplit')));
      await t.pump();
      expect(find.text('Pizza'), findsOneWidget);
    });

    testWidgets('Split Check with one guest holding everything is refused',
        (t) async {
      await open(t, sample());
      await t.tap(find.byKey(const Key('split-done')));
      await t.pump();
      expect(find.byKey(const Key('split-check-screen')), findsOneWidget);
    });

    testWidgets('the x on a guest takes them off and gives their items back',
        (t) async {
      await open(t, sample());
      await moveCola(t);
      await t.tap(find.byKey(const Key('split-remove-1')));
      await t.pump();
      expect(find.byKey(const Key('split-col-1')), findsNothing);
      expect(t.widget<Text>(find.byKey(const Key('split-total-0'))).data,
          '140.00');
      expect(find.byKey(const Key('split-remove-0')), findsNothing);
    });

    testWidgets('a table already split opens with a column per check',
        (t) async {
      final a = sample();
      final b = [
        OrderLine(productId: 12, name: 'Cake', quantity: 1, unitPrice: 40),
      ];
      await open(t, const [], checks: [check(a), check(b), check(const [])]);
      expect(find.byKey(const Key('split-col-1')), findsOneWidget);
      expect(find.byKey(const Key('split-col-2')), findsNothing);
      expect(t.widget<Text>(find.byKey(const Key('split-total-1'))).data,
          '40.00');
    });

    testWidgets('Print on a guest hands the host that guest and reloads',
        (t) async {
      final lines = sample();
      int? asked;
      SplitAction? did;
      List<List<SplitShare>>? laid;
      await open(t, lines, onAction: (layout, i, action) async {
        laid = layout;
        asked = i;
        did = action;
        return [
          check([lines[0]]),
          check([lines[1]])..billPrintedAt = DateTime.now(),
        ];
      });
      await moveCola(t);
      await t.tap(find.byKey(const Key('split-print-1')));
      await t.pumpAndSettle();
      expect(asked, 1);
      expect(did, SplitAction.print);
      expect(laid, hasLength(2));
      expect(find.byKey(const Key('split-printed')), findsOneWidget);
      expect(find.byKey(const Key('split-check-screen')), findsOneWidget);
    });

    testWidgets('Unsplit Check folds every guest into one and goes back',
        (t) async {
      final a = sample();
      final b = [
        OrderLine(productId: 12, name: 'Cake', quantity: 1, unitPrice: 40),
      ];
      await open(t, const [], checks: [check(a), check(b)]);
      await t.tap(find.byKey(const Key('split-unsplit-all')));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('split-check-screen')), findsNothing);
      expect(result, hasLength(1));
      expect(result!.single.map((s) => s.line).toSet(),
          {a[0].uuid, a[1].uuid, b[0].uuid});
    });

    testWidgets('Unsplit Check on a table never split just goes back',
        (t) async {
      await open(t, sample());
      await moveCola(t);
      await t.tap(find.byKey(const Key('split-unsplit-all')));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('split-check-screen')), findsNothing);
      expect(result, isNull);
    });

    group('an item shared four ways and already applied', () {
      /// Four checks on the table, each holding its own quarter-pizza line, as
      /// the session leaves them after the split is applied.
      List<Order> quartered() {
        session.addProduct(pizza);
        session.addProduct(cola);
        final p = lineFor(10);
        session.splitIntoChecks([
          [(line: p, quantity: 0.25), (line: lineFor(11), quantity: 1)],
          [(line: p, quantity: 0.25)],
          [(line: p, quantity: 0.25)],
          [(line: p, quantity: 0.25)],
        ]);
        return session.tableChecks();
      }

      testWidgets('taking the guests off makes the pizza whole again',
          (t) async {
        await open(t, const [], checks: quartered());
        for (final i in [3, 2, 1]) {
          await t.tap(find.byKey(Key('split-remove-$i')));
          await t.pump();
        }
        expect(find.text('Pizza'), findsOneWidget);
        expect(find.textContaining('1/4'), findsNothing);
      });

      testWidgets('Unsplit Item gathers every quarter into one', (t) async {
        await open(t, const [], checks: quartered());
        await t.tap(find.text('1/4 Pizza').first);
        await t.pump();
        await t.tap(find.byKey(const Key('split-unsplit')));
        await t.pump();
        expect(find.text('Pizza'), findsOneWidget);
        expect(find.textContaining('1/4'), findsNothing);
      });

      testWidgets('Unsplit Check puts one whole pizza back on one bill',
          (t) async {
        await open(t, const [], checks: quartered());
        await t.tap(find.byKey(const Key('split-unsplit-all')));
        await t.pumpAndSettle();

        session.splitIntoChecks(result!, among: session.tableChecks());
        expect(session.tableChecks(), hasLength(1));
        final pizzas =
            session.current.lines.where((l) => l.productId == 10).toList();
        expect(pizzas.single.quantity, 1);
        expect(session.current.subtotal, closeTo(120, 1e-9));
      });
    });

    testWidgets('once the host says the table is settled the screen closes',
        (t) async {
      await open(t, sample(), onAction: (_, _, _) async => const []);
      await t.tap(find.byKey(const Key('split-pay-0')));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('split-check-screen')), findsNothing);
    });
  });
}
