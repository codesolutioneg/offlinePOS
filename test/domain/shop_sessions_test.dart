import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/domain/shift.dart';
import 'package:offline_pos/domain/shop_sessions.dart';

void main() {
  Shift shift(
    String id,
    DateTime at, {
    double float = 0,
    String cashier = 'emad',
    DateTime? closedAt,
  }) =>
      Shift(
        id: id,
        openedAt: at,
        closedAt: closedAt ?? at.add(const Duration(hours: 8)),
        openingFloat: float,
        cashierId: cashier,
      );

  test('quiet peer opens for the same cashier collapse to one session', () {
    final t = DateTime.utc(2026, 10, 15, 8, 35);
    final collapsed = collapseShopShiftClones([
      shift('a', t, float: 0),
      shift('b', t.add(const Duration(minutes: 1)), float: 500),
      shift('c', t.add(const Duration(minutes: 2)), float: 0),
      // Real reopen after the first day closed.
      shift('d', t.add(const Duration(hours: 9)), float: 0),
    ]);
    expect(collapsed, hasLength(2));
    expect(collapsed.map((s) => s.id), containsAll(['b', 'd']));
    expect(collapsed.firstWhere((s) => s.id == 'b').openingFloat, 500);
  });

  test('peer open twelve minutes later while still open collapses', () {
    final t = DateTime.utc(2026, 10, 15, 8, 35);
    final collapsed = collapseShopShiftClones([
      shift('a', t, float: 200,
          closedAt: DateTime.utc(2026, 10, 16, 0, 42)),
      shift('b', t, float: 0,
          closedAt: DateTime.utc(2026, 10, 16, 0, 42)),
      shift('c', t.add(const Duration(minutes: 12)), float: 0,
          closedAt: DateTime.utc(2026, 10, 16, 0, 40)),
    ]);
    expect(collapsed, hasLength(1));
    expect(collapsed.single.id, 'a');
    expect(collapsed.single.openingFloat, 200);
  });

  test('abandoned open from a prior day is dropped', () {
    final now = DateTime.utc(2026, 10, 17, 0, 15);
    final ghost = Shift(
      id: 'ghost',
      openedAt: DateTime.utc(2026, 10, 14, 11, 30),
      openingFloat: 0,
      cashierId: 'eazz',
    );
    final real = shift('real', DateTime.utc(2026, 10, 15, 8, 35), float: 200);
    expect(isAbandonedOpenShift(ghost, now: now), isTrue);
    final collapsed = collapseShopShiftClones([ghost, real], now: now);
    expect(collapsed.map((s) => s.id), ['real']);
  });
}
