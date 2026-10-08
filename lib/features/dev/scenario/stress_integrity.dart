import 'dart:convert';

import '../../../core/db/database.dart';
import '../../../core/db/order_store.dart';
import '../../../core/db/stress_purge.dart';
import '../../../core/printing/print_probe.dart';
import '../../../domain/order.dart';
import '../stress_note.dart';
import 'stress_integrity_order.dart';
import 'stress_trace.dart';

/// Reads the till back after a full-day run and says what went wrong, per order
/// (written onto each trace) and for the shop (returned as notes).
///
/// What it looks for is what goes wrong on a busy day with two tills: a number
/// handed out twice, one order written over another, a receipt that names the
/// wrong order, a sale missing from the Odoo queue, a table left showing busy.
class StressIntegrity {
  StressIntegrity({
    required this.db,
    required this.orders,
    required this.deviceId,
    required this.records,
    required this.printing,
    this.slow = const Duration(milliseconds: 500),
  });

  final Db db;
  final OrderStore orders;
  final String deviceId;
  final List<PrintRecord> records;
  final bool printing;
  final Duration slow;

  List<StressNote> check(List<OrderTrace> traces) {
    final perOrder = OrderChecks(
      byUuid: orders.byUuid,
      records: records,
      printing: printing,
      slow: slow,
    );
    for (final t in traces) {
      perOrder.run(t);
    }
    return [..._numbers(traces), ..._queue(traces), ..._openTabs()];
  }

  List<Order> _labOrders() => db.raw
      .select(
        "SELECT payload FROM orders WHERE state IN ('held','paid','synced') "
        'AND payload LIKE ?',
        [kStressNoteMatch],
      )
      .map(
        (r) => Order.fromMap(
          jsonDecode(r['payload'] as String) as Map<String, dynamic>,
        ),
      )
      .toList();

  /// A number on two different orders anywhere in the shop, the other till's
  /// copies included.
  List<StressNote> _numbers(List<OrderTrace> traces) {
    final byNo = <String, List<Order>>{};
    for (final o in _labOrders()) {
      final n = o.orderNo;
      if (n != null) byNo.putIfAbsent(n, () => []).add(o);
    }
    final repeated = byNo.entries.where((e) => e.value.length > 1).toList();
    final owner = {
      for (final t in traces)
        for (final u in t.expected.keys) u: t,
    };
    for (final e in repeated) {
      for (final o in e.value) {
        final others = [
          for (final x in e.value)
            if (x.uuid != o.uuid) '${x.uuid.substring(0, 8)} @${x.deviceId}',
        ];
        owner[o.uuid]?.problems.add(
          StressNote('Number #{no} is also on {others}', {
            'no': e.key,
            'others': others.join(', '),
          }, true),
        );
      }
    }
    return [
      StressNote(
        'Numbers: {distinct} distinct · repeated {repeated} {which}',
        {
          'distinct': byNo.length,
          'repeated': repeated.length,
          'which': repeated.isEmpty
              ? ''
              : '(${repeated.take(8).map((e) => '#${e.key}').join(', ')})',
        },
        repeated.isNotEmpty,
      ),
    ];
  }

  /// Every sale this till took must be waiting in its own Odoo queue.
  List<StressNote> _queue(List<OrderTrace> traces) {
    final queued = db.raw
        .select(
          "SELECT payload_uuid FROM outbox WHERE kind = 'order.push' "
          'AND sent_at IS NULL AND dead_at IS NULL',
        )
        .map((r) => r['payload_uuid'] as String)
        .toSet();
    var paid = 0;
    var missing = 0;
    for (final t in traces) {
      for (final want in t.expected.values) {
        if (want.gone ||
            want.state != OrderState.paid ||
            want.deviceId != deviceId) {
          continue;
        }
        paid++;
        if (queued.contains(want.uuid)) continue;
        missing++;
        t.problems.add(
          const StressNote('Paid but not in the Odoo queue', {}, true),
        );
      }
    }
    return [
      StressNote(
        'Paid on this till, waiting for the shift close: {paid} · not in the queue: {missing}',
        {'paid': paid, 'missing': missing},
        missing > 0,
      ),
    ];
  }

  /// Tabs the run left on tables, and tables with two bills that are not one
  /// table's linked checks.
  List<StressNote> _openTabs() {
    final open = orders
        .occupyingAnywhere()
        .where((o) => o.note == kStressNote && o.tableLabel != null)
        .toList();
    final mine = open.where((o) => o.deviceId == deviceId).toList();
    final byTable = <String, List<Order>>{};
    for (final o in open) {
      byTable.putIfAbsent(o.tableLabel!, () => []).add(o);
    }
    final doubled = byTable.entries.where(
      (e) =>
          e.value.length > 1 &&
          e.value.any(
            (a) => e.value.any(
              (b) => a != b && !a.linkedOrderUuids.contains(b.uuid),
            ),
          ),
    );
    return [
      if (mine.isNotEmpty)
        StressNote(
          'Still open on this till after the run: {n} lab tabs ({tables})',
          {
            'n': mine.length,
            'tables': mine.take(10).map((o) => o.tableLabel).join(', '),
          },
          true,
        ),
      for (final e in doubled)
        StressNote('Table {table} has {n} separate open bills ({tills})', {
          'table': e.key,
          'n': e.value.length,
          'tills': e.value.map((o) => o.deviceId).toSet().join(', '),
        }, true),
    ];
  }
}
