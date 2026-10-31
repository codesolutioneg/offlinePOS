import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/domain/order.dart';
import 'package:offline_pos/web_reports/shift_days.dart';
import 'package:offline_pos/web_reports/site_api.dart';

SiteRecord shift(String till, String id, DateTime opened, {DateTime? closed}) => SiteRecord(
      kind: 'shift',
      key: '$till:$id',
      branchId: 'b1',
      at: opened.toUtc(),
      payload: {
        'id': id,
        'uuid': 'u-$id',
        'opened_at': opened.toUtc().toIso8601String(),
        'closed_at': closed?.toUtc().toIso8601String(),
        'opening_float': 0,
        'cashier_id': 'sara',
        'closing_counted': null,
        'movements': '[]',
      },
    );

Order sale(String till, DateTime at) =>
    Order(deviceId: till, cashierId: 'sara', createdAt: at.toUtc());

void main() {
  final d14 = DateTime(2026, 10, 14);
  final d15 = DateTime(2026, 10, 15);

  test('a sale after midnight counts under the day its shift opened', () {
    final days = ShiftDays([shift('t1', 'SH1', DateTime(2026, 10, 14, 14, 30))]);
    expect(days.dayOf(sale('t1', DateTime(2026, 10, 15, 0, 55))), d14);
    expect(days.dayOf(sale('t1', DateTime(2026, 10, 14, 18))), d14);
  });

  test('another till\'s shift does not claim a sale', () {
    final days = ShiftDays([shift('t1', 'SH1', DateTime(2026, 10, 14, 14, 30))]);
    expect(days.shiftOf(sale('t2', DateTime(2026, 10, 15, 0, 55))), isNull);
    expect(days.dayOf(sale('t2', DateTime(2026, 10, 15, 0, 55))), d15);
  });

  test('a sale after its shift closed falls back to its own day', () {
    final days = ShiftDays([
      shift('t1', 'SH1', DateTime(2026, 10, 14, 14), closed: DateTime(2026, 10, 14, 23, 50)),
    ]);
    expect(days.dayOf(sale('t1', DateTime(2026, 10, 15, 0, 10))), d15);
  });

  test('the next shift on the till ends one whose close never arrived', () {
    final days = ShiftDays([
      shift('t1', 'SH1', DateTime(2026, 10, 14, 14)),
      shift('t1', 'SH2', DateTime(2026, 10, 15, 8, 35)),
    ]);
    expect(days.dayOf(sale('t1', DateTime(2026, 10, 15, 0, 59))), d14);
    expect(days.dayOf(sale('t1', DateTime(2026, 10, 15, 9))), d15);
    expect(days.shiftOf(sale('t1', DateTime(2026, 10, 15, 9)))!.id, 'SH2');
  });

  test('a shift left open claims no more than a day of sales', () {
    final days = ShiftDays([shift('t1', 'SH1', DateTime(2026, 10, 14, 14))]);
    expect(days.dayOf(sale('t1', DateTime(2026, 10, 16, 10))), DateTime(2026, 10, 16));
  });

  test('a sale before any shift counts under its own day', () {
    final days = ShiftDays([shift('t1', 'SH1', DateTime(2026, 10, 15, 8))]);
    expect(days.dayOf(sale('t1', DateTime(2026, 10, 15, 7))), d15);
  });
}
