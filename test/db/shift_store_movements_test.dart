import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/db/database.dart';
import 'package:offline_pos/core/db/shift_store.dart';

import 'sqlite_loader.dart';

/// Paid-outs only ever lived inside the shift that recorded them. The range read
/// is what lets a manager ask "what did we spend this week" across closed shifts.
void main() {
  late Db db;
  late ShiftStore shifts;

  setUpAll(useSystemSqlite);
  setUp(() {
    db = Db.open(':memory:');
    shifts = ShiftStore(db);
  });
  tearDown(() => db.close());

  /// A closed shift with the movements it recorded, opened and closed around
  /// [at] so the movements fall inside its own window.
  void closedShift(String cashier, DateTime at, List<(String, double, String)> ms) {
    shifts.openShift(openingFloat: 0, cashierId: cashier, at: at);
    for (final m in ms) {
      shifts.addMovement(m.$1, m.$2, reason: m.$3, category: m.$3);
    }
    shifts.closeShift(countedCash: 0, at: at.add(const Duration(hours: 8)));
  }

  test('movements read across several closed shifts', () {
    final now = DateTime.now().toUtc();
    closedShift('sara', now.subtract(const Duration(days: 2)),
        [('out', 20, 'Transport')]);
    closedShift('omar', now.subtract(const Duration(days: 1)),
        [('out', 30, 'Supplies'), ('in', 100, 'Float top-up')]);

    final all = shifts.movements();
    expect(all.length, 3);
    expect(all.map((m) => m.cashierId).toList(), ['sara', 'omar', 'omar']);
    expect(all.first.movement.amount, 20);
  });

  test('a movement outside the window is left out', () {
    final now = DateTime.now().toUtc();
    closedShift('sara', now.subtract(const Duration(days: 5)), [('out', 20, 'Old')]);
    closedShift('sara', now.subtract(const Duration(hours: 2)), [('out', 5, 'New')]);

    final recent = shifts.movements(from: now.subtract(const Duration(days: 1)));
    expect(recent.map((m) => m.movement.reason).toList(), ['New']);
  });

  test('the cashier filter narrows the read to one drawer', () {
    final now = DateTime.now().toUtc();
    closedShift('sara', now.subtract(const Duration(hours: 6)), [('out', 20, 'Taxi')]);
    closedShift('omar', now.subtract(const Duration(hours: 3)), [('out', 40, 'Ice')]);

    expect(shifts.movements(cashierId: 'omar').single.movement.amount, 40);
  });

  test('an open shift still reports what it has paid out', () {
    shifts.openShift(openingFloat: 0, cashierId: 'sara');
    shifts.addMovement('out', 12, reason: 'Bread', category: 'Food');

    final m = shifts.movements(from: DateTime.now().toUtc().subtract(const Duration(days: 1))).single;
    expect(m.movement.category, 'Food');
    expect(m.shiftId, shifts.currentOpenShift()!.id);
  });

  test('a till that has never opened a shift reads as no movements', () {
    expect(shifts.movements(), isEmpty);
  });
}
