import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/db/database.dart';
import 'package:offline_pos/core/db/order_store.dart';
import 'package:offline_pos/core/db/shift_store.dart';
import 'package:offline_pos/domain/order.dart';
import 'sqlite_loader.dart';

void main() {
  setUpAll(useSystemSqlite);
  late Db db;
  late ShiftStore shifts;
  late OrderStore orders;
  setUp(() {
    db = Db.open(':memory:');
    shifts = ShiftStore(db);
    orders = OrderStore(db);
  });
  tearDown(() => db.close());

  OrderLine line(double p) => OrderLine(productId: 1, name: 'x', quantity: 1, unitPrice: p);

  test('open, record movements, close, and persist across a reopen', () {
    final s = shifts.openShift(openingFloat: 100, cashierId: 'c1');
    expect(shifts.currentOpenShift()!.id, s.id);
    shifts.addMovement('in', 50, reason: 'topup');
    shifts.addMovement('out', 20, reason: 'petty');
    final reread = ShiftStore(db).currentOpenShift()!;
    expect(reread.cashIn, 50);
    expect(reread.cashOut, 20);
    // The reason round-trips through storage, so a paid-in/out stays auditable.
    expect(reread.movements.map((m) => m.reason), ['topup', 'petty']);
    final closed = shifts.closeShift(countedCash: 130);
    expect(closed.isOpen, isFalse);
    expect(shifts.currentOpenShift(), isNull);
  });

  test('a paid-out carries an expense category that round-trips through storage', () {
    shifts.openShift(openingFloat: 100, cashierId: 'c1');
    shifts.addMovement('out', 30, reason: 'taxi', category: 'Transport');
    final reread = ShiftStore(db).currentOpenShift()!;
    final out = reread.movements.single;
    expect(out.category, 'Transport');
    expect(out.reason, 'taxi');
  });

  test('only one shift can be open at a time', () {
    shifts.openShift(openingFloat: 0, cashierId: 'c1');
    expect(() => shifts.openShift(openingFloat: 0, cashierId: 'c1'), throwsStateError);
  });

  test('X/Z summary counts window sales, expected cash, and variance', () {
    shifts.openShift(openingFloat: 100, cashierId: 'c1');
    orders.save(Order(deviceId: 'd', cashierId: 'c1')
      ..lines.add(line(40))
      ..state = OrderState.paid);
    shifts.addMovement('in', 10);
    shifts.addMovement('out', 5);
    final sum = shifts.summary(shifts.currentOpenShift()!);
    expect(sum.salesCount, 1);
    expect(sum.salesTotal, 40);
    expect(sum.expectedCash, 145); // 100 + 40 + 10 - 5
    final closed = shifts.closeShift(countedCash: 145);
    expect(shifts.summary(closed).variance, 0);
  });

  test('card sales are takings but not drawer cash', () {
    shifts.openShift(openingFloat: 100, cashierId: 'c1');
    // A cash sale, tendered to the cash method (id 1).
    orders.save(Order(deviceId: 'd', cashierId: 'c1')
      ..lines.add(line(40))
      ..payments = [const OrderPayment(methodId: 1, amount: 40)]
      ..state = OrderState.paid);
    // A card sale, tendered to a non-cash method (id 2).
    orders.save(Order(deviceId: 'd', cashierId: 'c1')
      ..lines.add(line(30))
      ..payments = [const OrderPayment(methodId: 2, amount: 30)]
      ..state = OrderState.paid);
    final sum = shifts.summary(shifts.currentOpenShift()!, cashMethodIds: {1});
    expect(sum.salesCount, 2);
    expect(sum.salesTotal, 70); // turnover across both tenders
    expect(sum.cashSales, 40); // only the cash sale reaches the drawer
    expect(sum.expectedCash, 140); // 100 float + 40 cash
  });
}
