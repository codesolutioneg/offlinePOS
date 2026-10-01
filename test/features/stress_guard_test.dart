import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/db/stress_purge.dart';
import 'package:offline_pos/core/sync/batch_merge.dart';
import 'package:offline_pos/core/sync/dishflow_mirror.dart';
import 'package:offline_pos/core/sync/outbox.dart';
import 'package:offline_pos/core/sync/stress_firebase_purge.dart';
import 'package:offline_pos/domain/order.dart';

import '../db/sqlite_loader.dart';
import '../stress/stress_day_deps.dart';
import '../stress/stress_till.dart';

void main() {
  setUpAll(useSystemSqlite);

  late StressTill till;
  setUp(() {
    till = StressTill();
    till.settings
      ..dishflowMirrorEnabled = true
      ..dishflowProjectId = 'odc-chat'
      ..dishflowApiKey = 'key'
      ..dishflowOdooConnectionId = 'conn1';
  });
  tearDown(() => till.close());

  Order paidLabOrder({int seed = 0}) {
    final s = labSession(till, 'stress-1');
    till.ring(s, lines: 2, seed: seed);
    return till.payCash(s);
  }

  List<OutboxEntry> rawSales() => [
    for (final r in till.db.raw.select(
      "SELECT id, kind, payload_uuid, payload FROM outbox WHERE kind = 'order.push'",
    ))
      OutboxEntry(
        id: r['id'] as int,
        kind: r['kind'] as String,
        payloadUuid: r['payload_uuid'] as String,
        payload: jsonDecode(r['payload'] as String) as Map<String, dynamic>,
      ),
  ];

  test('a lab sale is never queued for Dishflow', () async {
    paidLabOrder();
    await Future<void>.delayed(Duration.zero);
    expect(till.outboxStore.pendingDishflowCount, 0);
  });

  test('a lab sale sits in the queue but is never handed to a sender', () async {
    final o = paidLabOrder();
    expect(rawSales().single.payloadUuid, o.uuid);
    expect(await till.outboxStore.pending(), isEmpty);
  });

  test('the shift-close merge leaves lab sales out', () {
    paidLabOrder();
    paidLabOrder(seed: 3);
    final outcome = mergeOrderPushes(rawSales(), batchUuid: 'shift-1');
    expect(outcome.batch, isNull);
  });

  test('a check split off a lab bill is a lab order too', () {
    final s = labSession(till, 'stress-1');
    till.ring(s, lines: 3);
    final line = s.current.lines.first;
    final check = s.payCheck(
      [line.uuid],
      payments: [OrderPayment(methodId: kStressCash.id, amount: 1000)],
      cashReceived: 1000,
    );
    expect(check?.note, kStressNote);
    expect(s.current.note, kStressNote);
  });

  test('the close counts what the lab left behind', () {
    paidLabOrder();
    paidLabOrder(seed: 2);
    expect(stressOrderCount(till.db), 2);
    purgeStressOrders(till.db);
    expect(stressOrderCount(till.db), 0);
  });

  group('Clean up reaches past the till', () {
    late Order sale;

    void sent(String kind, String key, Map<String, Object?> payload) {
      till.db.raw.execute(
        'INSERT INTO outbox (kind, payload_uuid, payload, created_at, sent_at) '
        'VALUES (?, ?, ?, ?, ?)',
        [kind, key, jsonEncode(payload), '2026-10-01', '2026-10-01'],
      );
    }

    setUp(() {
      sale = paidLabOrder();
      const fb = {'project_id': 'odc-chat', 'api_key': 'key'};
      sent(DishflowMirror.kind, sale.uuid, {...fb, 'doc_id': 'sale-1'});
      sent(DishflowMirror.driverOrderKind, '${sale.uuid}|d1', {
        ...fb,
        'doc_path': 'drivers/d1/orders/sale-1',
      });
      till.db.raw.execute(
        "UPDATE outbox SET sent_at = '2026-10-01' "
        "WHERE kind = 'order.push' AND payload_uuid = ?",
        [sale.uuid],
      );
    });

    test('deletes every Dishflow copy and names what Odoo booked', () async {
      final asked = <String>[];
      final result = await StressFirebasePurge(
        delete: (url) async {
          asked.add(url.path);
          return url.path.contains('drivers') ? 500 : 204;
        },
      ).purgeEverywhere(till.db);

      expect(asked, hasLength(2));
      expect(asked, contains(endsWith('/documents/sales/sale-1')));
      expect(result.firebaseDeleted, 1);
      expect(result.firebaseFailed, 1);
      expect(result.inOdoo, ['#${sale.orderNo}']);
      expect(result.removed, 1);
      expect(stressOrderCount(till.db), 0);
      expect(till.db.raw.select('SELECT 1 FROM outbox'), isEmpty);
    });

    test('the till is purged even when Firebase never answers', () async {
      final result = await StressFirebasePurge(
        delete: (_) => throw StateError('offline'),
      ).purgeEverywhere(till.db);

      expect(result.firebaseFailed, 2);
      expect(stressOrderCount(till.db), 0);
    });
  });
}
