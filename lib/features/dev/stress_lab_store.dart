import 'dart:async';
import 'dart:convert';

import '../../core/db/database.dart';
import '../../core/db/order_store.dart';
import '../../core/db/stress_purge.dart';
import '../../core/db/table_store.dart';
import '../../domain/order.dart';
import 'stress_note.dart';

export '../../core/db/stress_purge.dart' show kStressNote;

/// The floor section the lab adds tables to when the floor has none free.
const String kStressSection = 'Stress';

/// Reads and removes Stress Lab data on the till's own database.
class StressLabStore {
  StressLabStore({
    required this.db,
    required this.orders,
    required this.tables,
    this.deviceId,
    this.announceCleanup,
  });

  final Db db;
  final OrderStore orders;
  final TableStore tables;

  /// This till. Only its own sales are queued for Odoo here, so only they are
  /// checked against the queue; null counts every row (a till with no LAN).
  final String? deviceId;

  /// Tells the other tills to drop their copies of the lab's orders.
  final void Function()? announceCleanup;

  static const _noteMatch = '%"note":"$kStressNote"%';

  List<Order> _stressOrders(String stateClause) => db.raw
      .select('SELECT payload FROM orders WHERE $stateClause AND payload LIKE ?',
          [_noteMatch])
      .map((r) => Order.fromMap(jsonDecode(r['payload'] as String) as Map<String, dynamic>))
      .toList();

  /// Tables with no open tab on them anywhere in the shop.
  List<PosTable> freeTables() {
    final busy = orders.occupyingAnywhere().map((o) => o.tableLabel).toSet();
    return tables.all().where((t) => !busy.contains(t.name)).toList();
  }

  /// Open tabs the lab parked on tables.
  List<Order> stressTabs() => _stressOrders("state = 'held'");

  int totalSales() => db.raw
      .select("SELECT COUNT(*) c FROM orders WHERE state IN ('paid','synced')")
      .first['c'] as int;

  /// What a manager checks after a run: numbers repeated anywhere in the shop,
  /// and this till's sales left unqueued.
  List<StressNote> auditNumbers() {
    final live = _stressOrders("state IN ('held','paid','synced')");
    final seen = <String, int>{};
    for (final o in live) {
      final n = o.orderNo;
      if (n != null) seen[n] = (seen[n] ?? 0) + 1;
    }
    final repeated = seen.entries.where((e) => e.value > 1).map((e) => '#${e.key}').toList();
    final unnumbered = live.where((o) => o.orderNo == null).length;
    final paid = live
        .where((o) => o.state == OrderState.paid)
        .where((o) => deviceId == null || o.deviceId == deviceId)
        .map((o) => o.uuid)
        .toSet();
    final queued = db.raw
        .select("SELECT payload_uuid FROM outbox WHERE kind = 'order.push' "
            'AND sent_at IS NULL AND dead_at IS NULL')
        .map((r) => r['payload_uuid'] as String)
        .toSet();
    final missing = paid.difference(queued).length;
    return [
      StressNote(
        'Numbers: {distinct} distinct · repeated {repeated} {which}· without a number {none}',
        {
          'distinct': seen.length,
          'repeated': repeated.length,
          'which': repeated.isEmpty ? '' : '(${repeated.take(8).join(', ')}) ',
          'none': unnumbered,
        },
        repeated.isNotEmpty || unnumbered > 0,
      ),
      StressNote(
        'Paid on this till, waiting for the shift close: {paid} · not in the queue: {missing}',
        {'paid': paid.length, 'missing': missing},
        missing > 0,
      ),
    ];
  }

  /// Write [count] old synced sales straight to the table, in batches so the
  /// screen keeps drawing. Synced, so none of them is queued for Odoo.
  Future<void> seedHistory(int count, StressProgress onProgress) async {
    final base = DateTime.now().toUtc().subtract(const Duration(days: 7));
    const batch = 500;
    for (var start = 0; start < count; start += batch) {
      db.raw.execute('BEGIN');
      for (var i = start; i < start + batch && i < count; i++) {
        final o = Order(
          deviceId: 'stress-history',
          cashierId: 'stress',
          createdAt: base.add(Duration(seconds: i * 20)),
          note: kStressNote,
          lines: [
            OrderLine(productId: 1, name: 'Stress item', quantity: 2, unitPrice: 25),
            OrderLine(productId: 2, name: 'Stress drink', quantity: 1, unitPrice: 15),
          ],
        )..state = OrderState.synced;
        orders.save(o, announce: false);
      }
      db.raw.execute('COMMIT');
      onProgress((start + batch).clamp(0, count), count);
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
  }

  /// Remove every lab order on this till (the other tills' copies included), its
  /// queued deliveries and the lab's tables, and have the other tills do the same.
  /// Returns how many orders went here.
  int cleanup() {
    final removed = purgeStressOrders(db);
    tables.deleteSection(kStressSection);
    announceCleanup?.call();
    return removed;
  }
}

typedef StressProgress = void Function(int done, int total);
