import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/sync/odoo_sender.dart';
import 'package:offline_pos/core/sync/outbox.dart';
import 'package:offline_pos/domain/order.dart';

OdooSender sender(HttpPost post) =>
    OdooSender(baseUrl: Uri.parse('https://odoo.example'), db: 'prod', post: post);

OutboxEntry entry() =>
    OutboxEntry(id: 1, kind: 'order.push', payloadUuid: 'u1', payload: {'uuid': 'u1'});

/// Minimal durable-ish store so the sender can be driven through a real Outbox.
class FakeStore implements OutboxStore {
  final List<OutboxEntry> entries = [];
  final Set<int> sent = {};
  final Map<int, String> deadReasons = {};
  int _n = 1;
  @override
  Future<void> append(String k, String u, Map<String, dynamic> p) async =>
      entries.add(OutboxEntry(id: _n++, kind: k, payloadUuid: u, payload: p));
  @override
  Future<List<OutboxEntry>> pending({int limit = 20}) async => entries
      .where((e) => !sent.contains(e.id) && !deadReasons.containsKey(e.id))
      .take(limit)
      .toList();
  @override
  Future<void> markSent(int id) async => sent.add(id);
  @override
  Future<void> markFailed(int id, String e) async {}
  @override
  Future<void> markDead(int id, String reason) async => deadReasons[id] = reason;
}

void main() {
  test('authenticates and remembers the session', () async {
    final s = sender((u, h, b) async =>
        HttpReply(200, jsonEncode({'result': {'uid': 2}})));
    await s.authenticate('admin', 'pw');
    expect(s.isAuthenticated, isTrue);
  });

  test('wrong credentials are permanent, not retried forever', () async {
    final s = sender((u, h, b) async => HttpReply(200, jsonEncode({'result': {}})));
    expect(() => s.authenticate('admin', 'bad'), throwsA(isA<PermanentSyncError>()));
  });

  test('a dead socket is transient so the sale is never dropped', () async {
    final s = sender((u, h, b) async => throw Exception('connection refused'));
    expect(() => s.authenticate('a', 'b'), throwsA(isA<TransientSyncError>()));
  });

  test('5xx and 429 are transient, 4xx is permanent', () async {
    for (final code in [500, 503, 429]) {
      final s = sender((u, h, b) async => HttpReply(code, ''));
      expect(() => s.authenticate('a', 'b'), throwsA(isA<TransientSyncError>()),
          reason: 'HTTP $code');
    }
    final s = sender((u, h, b) async => HttpReply(400, ''));
    expect(() => s.authenticate('a', 'b'), throwsA(isA<PermanentSyncError>()));
  });

  test('an HTML body from a captive portal is transient, not a bad request', () async {
    final s = sender((u, h, b) async => HttpReply(200, '<html>Sign in to wifi</html>'));
    expect(() => s.authenticate('a', 'b'), throwsA(isA<TransientSyncError>()));
  });

  test('the order push carries the client uuid so a repeat is recognisable', () async {
    String? seen;
    final s = sender((u, h, b) async {
      final decoded = jsonDecode(b) as Map<String, dynamic>;
      if (u.path.contains('authenticate')) {
        return HttpReply(200, jsonEncode({'result': {'uid': 2}}));
      }
      final args = (decoded['params'] as Map)['args'] as List;
      seen = ((args.first as List).first as Map)['uuid'] as String;
      return HttpReply(200, jsonEncode({'result': 7}));
    });
    await s.authenticate('a', 'b');
    await s.orderSender(entry());
    expect(seen, 'u1');
  });

  test('pushing before authentication is transient, so it waits rather than fails', () async {
    final s = sender((u, h, b) async => HttpReply(200, jsonEncode({'result': 1})));
    expect(() => s.orderSender(entry()), throwsA(isA<TransientSyncError>()));
  });

  test('an expired session is transient and clears the login', () async {
    var calls = 0;
    final s = sender((u, h, b) async {
      calls++;
      if (calls == 1) return HttpReply(200, jsonEncode({'result': {'uid': 2}}));
      return HttpReply(200, jsonEncode({'error': {'message': 'Session expired'}}));
    });
    await s.authenticate('a', 'b');
    expect(() => s.orderSender(entry()), throwsA(isA<TransientSyncError>()));
    await Future<void>.delayed(Duration.zero);
    expect(s.isAuthenticated, isFalse);
  });

  test('a business rejection parks that one sale, freeing the queue', () async {
    // The outbox keys off this type: PermanentlyRejected parks one entry and lets
    // the rest of the week's takings through.
    var calls = 0;
    final s = sender((u, h, b) async {
      calls++;
      if (calls == 1) return HttpReply(200, jsonEncode({'result': {'uid': 2}}));
      return HttpReply(200, jsonEncode({'error': {'message': 'session already closed'}}));
    });
    await s.authenticate('a', 'b');
    expect(() => s.orderSender(entry()), throwsA(isA<PermanentlyRejected>()));
  });

  test('a rejected order parks while the rest of the backlog still drains', () async {
    var calls = 0;
    final s = sender((u, h, b) async {
      calls++;
      if (calls == 1) return HttpReply(200, jsonEncode({'result': {'uid': 2}}));
      final decoded = jsonDecode(b) as Map<String, dynamic>;
      final args = (decoded['params'] as Map)['args'] as List;
      final uuid = ((args.first as List).first as Map)['uuid'];
      if (uuid == 'poison') {
        return HttpReply(200, jsonEncode({'error': {'message': 'product deleted'}}));
      }
      return HttpReply(200, jsonEncode({'result': 1}));
    });
    await s.authenticate('a', 'b');

    final store = FakeStore();
    final outbox = Outbox(store: store, senders: {'order.push': s.orderSender});
    await outbox.enqueue('order.push', 'poison', {'uuid': 'poison'});
    for (final u in ['a', 'b']) {
      await outbox.enqueue('order.push', u, {'uuid': u});
    }
    expect(await outbox.drain(), 2);
    expect(store.deadReasons.values.single, contains('product deleted'));
  });

  test('a created status from the sale.order module is an ack, not a park', () async {
    final s = sender((u, h, b) async {
      if (u.path.contains('authenticate')) {
        return HttpReply(200, jsonEncode({'result': {'uid': 2}}));
      }
      // The module returns one status dict per order.
      return HttpReply(200, jsonEncode({
        'result': [{'uuid': 'u1', 'status': 'created', 'sale_order_id': 3230}]
      }));
    });
    await s.authenticate('a', 'b');
    // No throw means the outbox marks it sent.
    await s.orderSender(entry());
  });

  test('a duplicate status is a safe repeat, still an ack', () async {
    final s = sender((u, h, b) async {
      if (u.path.contains('authenticate')) {
        return HttpReply(200, jsonEncode({'result': {'uid': 2}}));
      }
      return HttpReply(200, jsonEncode({
        'result': [{'uuid': 'u1', 'status': 'duplicate', 'sale_order_id': 3230}]
      }));
    });
    await s.authenticate('a', 'b');
    await s.orderSender(entry());
  });

  test('a rejected status from the module parks the sale', () async {
    final s = sender((u, h, b) async {
      if (u.path.contains('authenticate')) {
        return HttpReply(200, jsonEncode({'result': {'uid': 2}}));
      }
      return HttpReply(200, jsonEncode({
        'result': [
          {'uuid': 'u1', 'status': 'rejected', 'message': 'Product 9 no longer exists.'}
        ]
      }));
    });
    await s.authenticate('a', 'b');
    expect(() => s.orderSender(entry()), throwsA(isA<PermanentlyRejected>()));
  });

  test('the payload carries what the server needs to place the sale', () async {
    Map<String, dynamic>? seen;
    final s = sender((u, h, b) async {
      if (u.path.contains('authenticate')) {
        return HttpReply(200, jsonEncode({'result': {'uid': 2}}));
      }
      final args = ((jsonDecode(b) as Map)['params'] as Map)['args'] as List;
      seen = ((args.first as List).first as Map).cast<String, dynamic>();
      return HttpReply(200, jsonEncode({'result': 7}));
    });
    await s.authenticate('a', 'b');
    final order = Order(
      deviceId: 'till-1', cashierId: 'sara',
      createdAt: DateTime(2026, 3, 11, 1, 0).toUtc(),
    );
    await s.orderSender(OutboxEntry(
        id: 1, kind: 'order.push', payloadUuid: order.uuid, payload: order.toMap()));
    // Without these the server cannot place the sale in the right day's session
    // and every daily report after a long outage is wrong.
    expect(seen!['uuid'], order.uuid);
    expect(seen!['business_date'], isNotNull);
    expect(seen!['created_at'], order.createdAt.toIso8601String());
    expect(seen!['cashier_id'], 'sara');
  });
}
