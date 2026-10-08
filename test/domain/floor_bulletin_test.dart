import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/domain/floor_bulletin.dart';
import 'package:offline_pos/domain/order.dart';

void main() {
  OrderLine line({bool fired = false}) => OrderLine(
        productId: 1,
        name: 'Burger',
        quantity: 1,
        unitPrice: 50,
        printedToKitchen: fired,
      );

  Order tab(String? table,
          {bool fired = false,
          bool billed = false,
          OrderType type = OrderType.dineIn}) =>
      Order(
        deviceId: 'till-1',
        cashierId: 'ana',
        type: type,
        tableLabel: table,
        lines: [line(fired: fired)],
        billPrintedAt: billed ? DateTime.now().toUtc() : null,
      );

  test('counts open, free, fired, billed and the orders outside the room', () {
    final t1 = tab('1', fired: true);
    final t2 = tab('2', fired: true, billed: true);
    final t3 = tab('3');
    final delivery = tab(null, type: OrderType.storeDelivery);
    final takeaway = tab(null, type: OrderType.takeaway);

    final b = FloorBulletin.from(
      tableNames: {'1', '2', '3', '4', '5'},
      // The same tab reported twice (held here and seen over the LAN) counts once.
      open: [t1, t2, t3, t1],
      held: [t1, t2, t3, delivery, takeaway, delivery],
      paidToday: 7,
      salesToday: 900,
    );

    expect(b.tables, 5);
    expect(b.openTables, 3);
    expect(b.freeTables, 2);
    expect(b.sentToKitchen, 2);
    expect(b.notSent, 1);
    expect(b.billPrinted, 1);
    expect(b.delivery, 1);
    expect(b.takeaway, 1);
    expect(b.openAmount, 150);
    expect(b.paidToday, 7);
    expect(b.salesToday, 900);
  });

  test('an empty room is all free', () {
    final b = FloorBulletin.from(tableNames: {'1', '2'}, open: [], held: []);
    expect(b.openTables, 0);
    expect(b.freeTables, 2);
    expect(b.openAmount, 0);
  });
}
