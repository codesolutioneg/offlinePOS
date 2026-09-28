import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/app/pos_session.dart';
import 'package:offline_pos/core/audit/audit_log.dart';
import 'package:offline_pos/core/db/catalogue_store.dart';
import 'package:offline_pos/core/db/database.dart';
import 'package:offline_pos/core/db/order_store.dart';
import 'package:offline_pos/core/db/settings_store.dart';
import 'package:offline_pos/core/db/sqlite_outbox_store.dart';
import 'package:offline_pos/core/sync/outbox.dart';
import 'package:offline_pos/domain/catalogue.dart';
import 'package:offline_pos/domain/order.dart';
import 'package:offline_pos/features/sell/sell_screen.dart';

import '../db/sqlite_loader.dart';

/// The Dinerware order-entry strip along the bottom of the order screen: each
/// button is one of the screen's own actions.
void main() {
  late Db db;
  late PosSession session;
  late SettingsStore settings;
  late List<Order> printed;

  const pizza = Product(id: 10, name: 'Pizza', price: 100, categoryId: 1);
  const salad = Product(id: 11, name: 'Salad', price: 50, categoryId: 1);

  setUpAll(useSystemSqlite);
  setUp(() {
    db = Db.open(':memory:');
    final cat = CatalogueStore(db);
    cat.replaceAll(
      categories: const [Category(id: 1, name: 'Food')],
      products: const [pizza, salad],
      groups: const [],
      productGroupIds: const {},
      refreshedAt: DateTime.now().toUtc(),
    );
    settings = SettingsStore(db);
    printed = [];
    session = PosSession(
      catalogue: cat,
      orders: OrderStore(db),
      outbox: Outbox(store: SqliteOutboxStore(db), senders: const {}),
      audit: AuditLog(db),
      deviceId: 'till-1',
      cashierId: 'sara',
    );
  });
  tearDown(() => db.close());

  Future<void> open(WidgetTester t, {VoidCallback? onNewOrder}) async {
    t.view.physicalSize = const Size(1366, 768);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(
      home: SellScreen(
        session: session,
        settings: settings,
        formatAmount: (v) => v.toStringAsFixed(2),
        onPrintBill: printed.add,
        onNewOrder: onNewOrder,
        onEmployeeTransfer: () async {},
        onOpenRefunds: () {},
      ),
    ));
    await t.pumpAndSettle();
  }

  Finder tile(String id) => find.byKey(Key('order-action-$id'));

  testWidgets('the bar shows every button, line buttons idle on an empty order',
      (t) async {
    await open(t);
    expect(find.byKey(const Key('order-action-bar')), findsOneWidget);
    for (final id in [
      'delete', 'quantity', 'send', 'timed-send', 'print', 'settle',
      'reference', 'misc', 'exit',
    ]) {
      expect(tile(id), findsOneWidget, reason: id);
    }
    expect(t.widget<InkWell>(tile('delete')).onTap, isNull);
    expect(t.widget<InkWell>(tile('settle')).onTap, isNull);
  });

  testWidgets('Delete asks which line when there are several, then drops it',
      (t) async {
    session.addProduct(pizza);
    session.addProduct(salad);
    await open(t);

    await t.tap(tile('delete'));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('bar-pick-line')), findsOneWidget);
    final saladLine =
        session.current.lines.firstWhere((l) => l.name == 'Salad');
    await t.tap(find.byKey(Key('bar-line-${saladLine.uuid}')));
    await t.pumpAndSettle();

    expect(session.current.lines.map((l) => l.name), ['Pizza']);
  });

  testWidgets('Quantity on the only line sets it from the keypad', (t) async {
    session.addProduct(pizza);
    await open(t);

    await t.tap(tile('quantity'));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('key-⌫')));
    await t.tap(find.byKey(const Key('key-3')));
    await t.pump();
    await t.tap(find.byKey(const Key('keypad-ok')));
    await t.pumpAndSettle();

    expect(session.current.lines.single.quantity, 3);
  });

  testWidgets('raising a sent line puts only the difference up to send',
      (t) async {
    session.addProduct(pizza);
    final sent = session.current.lines.single..printedToKitchen = true;
    session.orders.save(session.current);
    await open(t);

    await t.tap(tile('quantity'));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('key-⌫')));
    await t.tap(find.byKey(const Key('key-3')));
    await t.pump();
    await t.tap(find.byKey(const Key('keypad-ok')));
    await t.pumpAndSettle();

    // The kitchen's line is untouched; two more wait, unsent, right under it.
    expect(sent.quantity, 1);
    final extra = session.current.lines.where((l) => !l.printedToKitchen);
    expect(extra.single.quantity, 2);
    expect(extra.single.name, 'Pizza');
    expect(t.widget<InkWell>(tile('send')).onTap, isNull,
        reason: 'no kitchen sender wired in this test');

    // The inline + on the sent row adds to the same waiting copy.
    await t.tap(find.byKey(Key('line-more-${sent.uuid}')));
    await t.pumpAndSettle();
    expect(session.current.lines, hasLength(2));
    expect(extra.single.quantity, 3);
  });

  testWidgets('Print hands the order to the bill printer; Exit goes to the floor',
      (t) async {
    session.addProduct(pizza);
    var home = false;
    await open(t, onNewOrder: () => home = true);

    await t.tap(tile('print'));
    await t.pumpAndSettle();
    expect(printed, hasLength(1));

    await t.tap(tile('exit'));
    await t.pumpAndSettle();
    expect(home, isTrue);
  });

  testWidgets('Misc opens the pad, greys what does not apply, and pages',
      (t) async {
    session.setOrderType(OrderType.takeaway);
    session.addProduct(pizza);
    await open(t);

    await t.tap(tile('misc'));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('misc-pad')), findsOneWidget);
    // A takeaway order: table moves do not apply, discounts do.
    expect(t.widget<InkWell>(find.byKey(const Key('bill-move'))).onTap, isNull);
    expect(t.widget<InkWell>(find.byKey(const Key('misc-discount-check'))).onTap,
        isNotNull);

    expect(find.byKey(const Key('misc-customer')), findsNothing);
    await t.tap(find.byKey(const Key('misc-next')));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('misc-customer')), findsOneWidget);

    await t.tap(find.byKey(const Key('misc-cancel')));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('misc-pad')), findsNothing);
  });

  testWidgets('Item Hold on times a line, Item Hold off releases it', (t) async {
    session.addProduct(pizza);
    await open(t);
    final line = session.current.lines.single;

    await t.tap(tile('misc'));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('misc-hold-on')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('fire-in-15')));
    await t.pumpAndSettle();
    expect(line.fireAt, isNotNull);

    await t.tap(tile('misc'));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('misc-hold-off')));
    await t.pumpAndSettle();
    expect(line.fireAt, isNull);
  });

  testWidgets('settings switch buttons off, or the whole bar', (t) async {
    settings.orderActionsHidden = {'reference', 'misc'};
    await open(t);
    expect(tile('reference'), findsNothing);
    expect(tile('misc'), findsNothing);
    expect(tile('settle'), findsOneWidget);

    settings.orderActionBarEnabled = false;
    await open(t);
    expect(find.byKey(const Key('order-action-bar')), findsNothing);
  });

  testWidgets('an item discount is counted in the Discount row', (t) async {
    session.addProduct(pizza);
    session.setLineDiscount(session.current.lines.single.uuid, 20);
    await open(t);

    // Subtotal before discounts: the menu tile and the Subtotal row read 100.
    expect(find.text('100.00'), findsNWidgets(2));
    expect(find.text('-20.00'), findsOneWidget);
  });

  testWidgets('with the bar up, the buttons under the bill step aside',
      (t) async {
    session.addProduct(pizza);
    await open(t);
    for (final k in ['pay', 'hold', 'send-kitchen', 'bill-options', 'discount']) {
      expect(find.byKey(Key(k)), findsNothing, reason: k);
    }

    settings.orderActionBarEnabled = false;
    await open(t);
    for (final k in ['pay', 'hold', 'send-kitchen', 'bill-options', 'discount']) {
      expect(find.byKey(Key(k)), findsOneWidget, reason: k);
    }
  });
}
