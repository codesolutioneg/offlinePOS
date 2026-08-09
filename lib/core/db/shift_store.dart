import 'dart:convert';

import '../../domain/shift.dart';
import 'database.dart';

/// Shifts and their cash movements, plus the X/Z totals for a shift.
///
/// Entirely local: a shift is the cashier's own accounting of the drawer and does
/// not depend on the server, so it works through an outage like everything else.
class ShiftStore {
  ShiftStore(this._db);

  final Db _db;

  Shift? currentOpenShift() {
    final rows = _db.raw.select(
        'SELECT * FROM shifts WHERE closed_at IS NULL ORDER BY opened_at DESC LIMIT 1');
    return rows.isEmpty ? null : _row(rows.first);
  }

  /// Open a shift. Refuses if one is already open, because two open drawers make
  /// the cash count meaningless.
  Shift openShift({
    required double openingFloat,
    required String cashierId,
    String? id,
    DateTime? at,
  }) {
    if (currentOpenShift() != null) {
      throw StateError('A shift is already open.');
    }
    final opened = (at ?? DateTime.now().toUtc());
    final shiftId = id ?? 'SH${opened.microsecondsSinceEpoch}';
    _db.raw.execute(
      'INSERT INTO shifts (id, opened_at, closed_at, opening_float, cashier_id, movements, closing_counted) '
      'VALUES (?, ?, NULL, ?, ?, ?, NULL)',
      [shiftId, opened.toIso8601String(), openingFloat, cashierId, '[]'],
    );
    return Shift(
        id: shiftId, openedAt: opened, openingFloat: openingFloat, cashierId: cashierId);
  }

  void addMovement(String type, double amount, {String reason = ''}) {
    final s = currentOpenShift();
    if (s == null) throw StateError('No open shift.');
    s.movements.add(CashMovement(
        type: type, amount: amount, reason: reason, at: DateTime.now().toUtc()));
    _db.raw.execute('UPDATE shifts SET movements = ? WHERE id = ?',
        [jsonEncode(s.movements.map((m) => m.toMap()).toList()), s.id]);
  }

  Shift closeShift({required double countedCash, DateTime? at}) {
    final s = currentOpenShift();
    if (s == null) throw StateError('No open shift to close.');
    s.closedAt = at ?? DateTime.now().toUtc();
    s.closingCounted = countedCash;
    _db.raw.execute('UPDATE shifts SET closed_at = ?, closing_counted = ? WHERE id = ?',
        [s.closedAt!.toIso8601String(), countedCash, s.id]);
    return s;
  }

  /// The X/Z figures for [shift], with sales read from the orders taken in its
  /// window (paid or already synced, so a close after a sync still counts them).
  ///
  /// [cashMethodIds] are the tenders that land in the drawer. Only the cash
  /// portion of each sale counts toward the expected drawer total; card and
  /// other non-cash tenders are takings but never cash on hand.
  ShiftSummary summary(Shift shift, {Set<int> cashMethodIds = const {}}) {
    final from = shift.openedAt.toIso8601String();
    final to = (shift.closedAt ?? DateTime.now().toUtc()).toIso8601String();
    final rows = _db.raw.select(
      "SELECT total, payload FROM orders "
      "WHERE state IN ('paid', 'synced') AND created_at >= ? AND created_at <= ?",
      [from, to],
    );
    var salesTotal = 0.0;
    var cashSales = 0.0;
    for (final r in rows) {
      final total = (r['total'] as num).toDouble();
      salesTotal += total;
      cashSales += _cashPortion(r['payload'] as String, total, cashMethodIds);
    }
    return ShiftSummary(
      openingFloat: shift.openingFloat,
      cashIn: shift.cashIn,
      cashOut: shift.cashOut,
      salesCount: rows.length,
      salesTotal: salesTotal,
      cashSales: cashSales,
      countedCash: shift.closingCounted,
    );
  }

  /// The cash tendered on one order: the sum of its cash-method payments, or the
  /// whole total when no tender was recorded (an implicit cash sale, matching how
  /// the server books an order with no payments).
  double _cashPortion(String payload, double total, Set<int> cashMethodIds) {
    final payments = (jsonDecode(payload) as Map)['payments'] as List? ?? const [];
    if (payments.isEmpty) return total;
    var cash = 0.0;
    for (final p in payments) {
      final m = p as Map;
      if (cashMethodIds.contains(m['method_id'] as int)) {
        cash += (m['amount'] as num).toDouble();
      }
    }
    return cash;
  }

  Shift _row(Map<String, dynamic> r) => Shift(
        id: r['id'] as String,
        openedAt: DateTime.parse(r['opened_at'] as String),
        closedAt: r['closed_at'] == null
            ? null
            : DateTime.parse(r['closed_at'] as String),
        openingFloat: (r['opening_float'] as num).toDouble(),
        cashierId: r['cashier_id'] as String,
        closingCounted: (r['closing_counted'] as num?)?.toDouble(),
        movements: ((jsonDecode((r['movements'] ?? '[]') as String)) as List)
            .map((e) => CashMovement.fromMap((e as Map).cast<String, dynamic>()))
            .toList(),
      );
}
