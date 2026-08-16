import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/db/database.dart';
import 'package:offline_pos/core/db/table_store.dart';
import 'package:offline_pos/core/printing/kitchen_ticket.dart';
import 'package:offline_pos/core/printing/receipt_builder.dart';
import 'package:offline_pos/domain/order.dart';

import '../db/sqlite_loader.dart';
import 'strip_escpos.dart';

/// Which part of the floor the sale was sat in, on the paper.
///
/// A shop with a terrace and a first floor can have a "5" on each, and a slip that
/// says only "Table 5" sends the runner to the wrong one.
void main() {
  Order dineIn({String? table, int? guests}) => Order(
        deviceId: 'till-1',
        cashierId: 'sara',
        type: OrderType.dineIn,
        tableLabel: table,
        guestCount: guests,
      )..lines.add(
          OrderLine(productId: 1, name: 'Pizza', quantity: 1, unitPrice: 100));

  String render(Order o, {String? Function(String)? sectionOf}) =>
      strippedText(ReceiptBuilder(
        shopName: 'JOUMA',
        formatAmount: (v) => v.toStringAsFixed(2),
        sectionOf: sectionOf,
      ).build(o));

  test('the section leads the table', () {
    expect(
      render(dineIn(table: '5'), sectionOf: (_) => 'Terrace'),
      contains('Terrace - Table 5'),
    );
  });

  test('the covers still follow both', () {
    expect(
      render(dineIn(table: '5', guests: 4), sectionOf: (_) => 'Terrace'),
      contains('Terrace - Table 5 - 4 guests'),
    );
  });

  test('a shop with no floor plan prints what it always printed', () {
    expect(render(dineIn(table: 'A3', guests: 4)), contains('Table A3 - 4 guests'));
  });

  test('a table the floor does not know grows no empty separator', () {
    final text = render(dineIn(table: '9'), sectionOf: (_) => null);
    expect(text, contains('Table 9'));
    expect(text, isNot(contains(' - Table 9')));
  });

  test('a section named nothing is not printed as nothing', () {
    // A shop that blanked a section name would otherwise get a slip starting with a
    // dash, which reads as a missing value rather than as an absent one.
    final text = render(dineIn(table: '9'), sectionOf: (_) => '');
    expect(text, contains('Table 9'));
    expect(text, isNot(contains(' - Table 9')));
  });

  test('a counter sale is never asked where it sat', () {
    var asked = 0;
    final o = Order(deviceId: 'till-1', cashierId: 'sara', type: OrderType.takeaway)
      ..lines.add(
          OrderLine(productId: 1, name: 'Pizza', quantity: 1, unitPrice: 100));
    render(o, sectionOf: (_) {
      asked++;
      return 'Terrace';
    });
    expect(asked, 0);
  });

  group('the ticket the runner carries', () {
    test('names the section above the table', () {
      final text = strippedText(
          KitchenTicketBuilder(sectionOf: (_) => 'Terrace').build(dineIn(table: '5')));
      expect(text, contains('Section: Terrace'));
      expect(text.indexOf('Section: Terrace'), lessThan(text.indexOf('Table: 5')));
    });

    test('a shop with no floor plan prints what it always printed', () {
      final text = strippedText(KitchenTicketBuilder().build(dineIn(table: '5')));
      expect(text, contains('Table: 5'));
      expect(text, isNot(contains('Section:')));
    });

    test('a cancel slip goes to the same part of the floor', () {
      final order = dineIn(table: '5');
      final text = strippedText(KitchenTicketBuilder(sectionOf: (_) => 'Terrace')
          .buildVoid(order, order.lines.single, 'wrong table'));
      expect(text, contains('Section: Terrace'));
      expect(text, contains('Table: 5'));
    });
  });

  group('the floor answers by table name', () {
    late Db db;
    setUpAll(useSystemSqlite);
    setUp(() => db = Db.open(':memory:'));
    tearDown(() => db.close());

    test('the section a table was laid out in comes back', () {
      final tables = TableStore(db);
      tables.add(name: '5', section: 'Terrace');
      tables.add(name: '6');
      expect(tables.sectionFor('5'), 'Terrace');
      expect(tables.sectionFor('6'), 'Main');
      expect(tables.sectionFor('nowhere'), isNull);
    });
  });
}
