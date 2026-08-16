import 'dart:convert';

import '../../domain/shift.dart';
import 'database.dart';

/// One cash movement together with the shift it happened in.
///
/// A [CashMovement] carries no actor of its own, so a report that spans several
/// shifts would otherwise not be able to say who paid the money out.
class ShiftMovement {
  const ShiftMovement({
    required this.movement,
    required this.shiftId,
    required this.cashierId,
  });

  final CashMovement movement;
  final String shiftId;

  /// The cashier the shift was opened by.
  final String cashierId;
}

/// Shifts and their cash movements, plus the X/Z totals for a shift.
///
/// Entirely local: a shift is the cashier's own accounting of the drawer and does
/// not depend on the server, so it works through an outage like everything else.
class ShiftStore {
  ShiftStore(this._db);

  final Db _db;

  /// The tender an untendered sale is booked to, matching the payment-mix report.
  static const String _cashLabel = 'Cash';

  Shift? currentOpenShift() {
    final rows = _db.raw.select(
        'SELECT * FROM shifts WHERE closed_at IS NULL ORDER BY opened_at DESC LIMIT 1');
    return rows.isEmpty ? null : _row(rows.first);
  }

  /// The shift the till is on, open or the one it has just closed.
  ///
  /// A shift close pushes the day's sales after the drawer is counted and the
  /// shift is already closed, so a caller that needs the batch it belongs to
  /// cannot ask for the open one.
  Shift? latestShift() {
    final rows = _db.raw
        .select('SELECT * FROM shifts ORDER BY opened_at DESC, id DESC LIMIT 1');
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
    final shift = Shift(
      id: id ?? 'SH${opened.microsecondsSinceEpoch}',
      openedAt: opened,
      openingFloat: openingFloat,
      cashierId: cashierId,
    );
    _db.raw.execute(
      'INSERT INTO shifts (id, uuid, opened_at, closed_at, opening_float, cashier_id, movements, closing_counted) '
      'VALUES (?, ?, ?, NULL, ?, ?, ?, NULL)',
      [shift.id, shift.uuid, opened.toIso8601String(), openingFloat, cashierId, '[]'],
    );
    return shift;
  }

  void addMovement(String type, double amount, {String reason = '', String? category}) {
    final s = currentOpenShift();
    if (s == null) throw StateError('No open shift.');
    s.movements.add(CashMovement(
        type: type,
        amount: amount,
        reason: reason,
        category: category,
        at: DateTime.now().toUtc()));
    _db.raw.execute('UPDATE shifts SET movements = ? WHERE id = ?',
        [jsonEncode(s.movements.map((m) => m.toMap()).toList()), s.id]);
  }

  /// Every cash movement between [from] and [to], across open and closed shifts.
  ///
  /// Paid-outs live inside the shift that recorded them, so a manager asking
  /// "what did we spend this week" has no way to see past the drawer in front of
  /// them without this. The bounds are inclusive of [from] and exclusive of [to],
  /// matching how the reports window orders, and a null bound means unbounded on
  /// that side. Oldest first, so a report reads in the order the money left.
  List<ShiftMovement> movements({DateTime? from, DateTime? to, String? cashierId}) {
    final where = <String>[];
    final args = <Object?>[];
    // A shift only holds movements inside its own window, so shifts that closed
    // before the range or opened after it cannot contribute a single row.
    if (from != null) {
      where.add('(closed_at IS NULL OR closed_at >= ?)');
      args.add(from.toUtc().toIso8601String());
    }
    if (to != null) {
      where.add('opened_at < ?');
      args.add(to.toUtc().toIso8601String());
    }
    if (cashierId != null) {
      where.add('cashier_id = ?');
      args.add(cashierId);
    }
    final clause = where.isEmpty ? '' : 'WHERE ${where.join(' AND ')} ';
    final rows = _db.raw
        .select('SELECT * FROM shifts ${clause}ORDER BY opened_at ASC', args);
    final out = <ShiftMovement>[];
    for (final r in rows) {
      final shift = _row(r);
      for (final m in shift.movements) {
        final at = m.at.toUtc();
        if (from != null && at.isBefore(from.toUtc())) continue;
        if (to != null && !at.isBefore(to.toUtc())) continue;
        out.add(ShiftMovement(
            movement: m, shiftId: shift.id, cashierId: shift.cashierId));
      }
    }
    out.sort((a, b) => a.movement.at.compareTo(b.movement.at));
    return out;
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
    final takings = _Takings();
    for (final r in _salesIn(shift)) {
      _fold(takings, r, cashMethodIds);
    }
    return ShiftSummary(
      openingFloat: shift.openingFloat,
      cashIn: shift.cashIn,
      cashOut: shift.cashOut,
      salesCount: takings.count,
      salesTotal: takings.salesTotal,
      cashSales: takings.cashSales,
      countedCash: shift.closingCounted,
      tenders: _sorted(takings.byTender),
    );
  }

  /// The same figures split by who rang each sale, biggest taker first.
  ///
  /// The drawer belongs to the shift and not to any one cashier, so the float, the
  /// paid-ins and the paid-outs are deliberately left at zero on every row rather
  /// than divided up: what a cashier is answerable for is what they took. The rows
  /// add up to the shift's own sales figures, which is the check a manager runs.
  Map<String, ShiftSummary> summaryByCashier(Shift shift,
      {Set<int> cashMethodIds = const {}}) {
    final byCashier = <String, _Takings>{};
    for (final r in _salesIn(shift)) {
      _fold(byCashier.putIfAbsent(r['cashier_id'] as String, _Takings.new), r,
          cashMethodIds);
    }
    final entries = byCashier.entries.toList()
      ..sort((a, b) {
        final bySize = b.value.salesTotal.compareTo(a.value.salesTotal);
        return bySize != 0 ? bySize : a.key.compareTo(b.key);
      });
    return {
      for (final e in entries)
        e.key: ShiftSummary(
          openingFloat: 0,
          cashIn: 0,
          cashOut: 0,
          salesCount: e.value.count,
          salesTotal: e.value.salesTotal,
          cashSales: e.value.cashSales,
          tenders: _sorted(e.value.byTender),
        ),
    };
  }

  /// The sales taken in [shift]'s window: paid or already synced, so a close after
  /// a sync still counts them.
  List<Map<String, dynamic>> _salesIn(Shift shift) => _db.raw.select(
        "SELECT cashier_id, total, payload FROM orders "
        "WHERE state IN ('paid', 'synced') AND created_at >= ? AND created_at <= ?",
        [
          shift.openedAt.toIso8601String(),
          (shift.closedAt ?? DateTime.now().toUtc()).toIso8601String(),
        ],
      );

  /// The payments recorded on one order payload, empty when none were.
  List<Map<String, Object?>> _payments(String payload) => [
        for (final p in (jsonDecode(payload) as Map)['payments'] as List? ?? const [])
          (p as Map).cast<String, Object?>(),
      ];

  /// The cash tendered on one order: the sum of its cash-method payments, or the
  /// whole total when no tender was recorded (an implicit cash sale, matching how
  /// the server books an order with no payments).
  double _cashPortion(
      List<Map<String, Object?>> payments, double total, Set<int> cashMethodIds) {
    if (payments.isEmpty) return total;
    var cash = 0.0;
    for (final p in payments) {
      if (cashMethodIds.contains(p['method_id'] as int)) {
        cash += (p['amount'] as num).toDouble();
      }
    }
    return cash;
  }

  /// Folds one order's tenders into [into]. A split tender contributes to each
  /// method it was paid on, and an order with no recorded payment is booked to cash
  /// for its whole total the same way [_cashPortion] and the server treat it, so the
  /// tender rows always add up to the takings. A refund carries negative amounts
  /// and therefore reduces the method it is returned on.
  void _addTenders(
    List<Map<String, Object?>> payments,
    double total,
    Set<int> cashMethodIds,
    Map<(String, bool), double> into,
  ) {
    void add(String label, bool isCash, double amount) =>
        into[(label, isCash)] = (into[(label, isCash)] ?? 0) + amount;

    if (payments.isEmpty) {
      add(_cashLabel, true, total);
      return;
    }
    for (final p in payments) {
      final methodId = p['method_id'] as int;
      final isCash = cashMethodIds.contains(methodId);
      // A tender saved without its method name is shown by method id rather than
      // guessed at: naming a card row 'Cash' would put it against the drawer count.
      final label =
          (p['label'] as String?) ?? (isCash ? _cashLabel : 'Method $methodId');
      add(label, isCash, (p['amount'] as num).toDouble());
    }
  }

  /// Cash first, then largest first: a Z read is reconciled against the drawer
  /// count, so the rows being counted lead. Ties break on the label to keep the
  /// order stable between two reads of the same shift.
  List<TenderTotal> _sorted(Map<(String, bool), double> byTender) => [
        for (final e in byTender.entries)
          TenderTotal(label: e.key.$1, amount: e.value, isCash: e.key.$2),
      ]..sort((a, b) {
        if (a.isCash != b.isCash) return a.isCash ? -1 : 1;
        final bySize = b.amount.compareTo(a.amount);
        return bySize != 0 ? bySize : a.label.compareTo(b.label);
      });

  /// Fold one sale row into [into]. One decode per order: the tender split and the
  /// cash portion read the same payments, and the X read runs on every rebuild of
  /// the shift screen.
  void _fold(_Takings into, Map<String, dynamic> row, Set<int> cashMethodIds) {
    final total = (row['total'] as num).toDouble();
    final payments = _payments(row['payload'] as String);
    into.count++;
    into.salesTotal += total;
    into.cashSales += _cashPortion(payments, total, cashMethodIds);
    _addTenders(payments, total, cashMethodIds, into.byTender);
  }

  Shift _row(Map<String, dynamic> r) => Shift(
        id: r['id'] as String,
        uuid: r['uuid'] as String?,
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

/// A running total while a shift's sales are read, before it becomes a
/// [ShiftSummary]. Exists so the whole-shift read and the per-cashier split fold a
/// sale in exactly the same way instead of drifting apart.
class _Takings {
  int count = 0;
  double salesTotal = 0;
  double cashSales = 0;

  /// Keyed on (label, is-cash) rather than on the label alone, so a tender named
  /// like a cash one but not configured as cash cannot be folded into the cash row
  /// and silently break the drawer reconciliation.
  final Map<(String, bool), double> byTender = {};
}
