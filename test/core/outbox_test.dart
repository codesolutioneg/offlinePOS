import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/sync/outbox.dart';

/// In-memory stand-in for the SQLite store.
class FakeStore implements OutboxStore {
  final List<OutboxEntry> entries = [];
  final List<int> sent = [];
  int _next = 1;

  @override
  Future<void> append(String kind, String uuid, Map<String, dynamic> payload) async {
    entries.add(OutboxEntry(id: _next++, kind: kind, payloadUuid: uuid, payload: payload));
  }

  @override
  Future<List<OutboxEntry>> pending({int limit = 20}) async => entries
      .where((e) => !sent.contains(e.id) && !deadIds.contains(e.id))
      .take(limit)
      .toList();

  @override
  Future<void> markSent(int id) async => sent.add(id);

  @override
  Future<void> markFailed(int id, String error) async {
    entries.firstWhere((e) => e.id == id)
      ..attempts += 1
      ..lastError = error;
  }

  final List<int> deadIds = [];
  final Map<int, String> deadReasons = {};
  @override
  Future<void> markDead(int id, String reason) async {
    deadIds.add(id);
    deadReasons[id] = reason;
  }
}

void main() {
  test('queued work survives until the server accepts it', () async {
    final store = FakeStore();
    var online = false;
    final outbox = Outbox(store: store, senders: {
      'order.push': (e) async {
        if (!online) throw Exception('offline');
      },
    });

    await outbox.enqueue('order.push', 'u1', {'total': 282});
    await outbox.enqueue('order.push', 'u2', {'total': 100});

    // Offline: nothing is accepted, nothing is lost.
    expect(await outbox.drain(), 0);
    expect((await store.pending()).length, 2);

    online = true;
    expect(await outbox.drain(), 2);
    expect(await store.pending(), isEmpty);
  });

  test('a stuck entry does not let later ones jump the queue', () async {
    final store = FakeStore();
    final seen = <String>[];
    final outbox = Outbox(store: store, senders: {
      'order.push': (e) async {
        if (e.payloadUuid == 'bad') throw Exception('rejected');
        seen.add(e.payloadUuid);
      },
    });

    await outbox.enqueue('order.push', 'bad', {});
    await outbox.enqueue('order.push', 'good', {});

    await outbox.drain();
    // Order is preserved: 'good' must not be sent before 'bad' resolves.
    expect(seen, isEmpty);
  });

  test('replaying the same payload is safe because identity is client-side', () async {
    final store = FakeStore();
    final received = <String>[];
    final outbox = Outbox(store: store, senders: {
      'order.push': (e) async => received.add(e.payloadUuid),
    });

    await outbox.enqueue('order.push', 'u1', {});
    await outbox.drain();
    // Simulate an interrupted drain: the server got it, we never recorded it.
    store.sent.clear();
    await outbox.drain();

    expect(received, ['u1', 'u1']);
    // Both carry the same identity, so the server collapses them into one order.
    expect(received.toSet().length, 1);
  });

  test('an unknown kind is parked, not silently dropped', () async {
    final store = FakeStore();
    final outbox = Outbox(store: store, senders: {});
    await outbox.enqueue('mystery', 'u1', {});
    await outbox.drain();
    expect(store.deadReasons.values.single, contains('no sender'));
  });

  test('a permanent rejection is parked and the queue keeps moving', () async {
    // The week-offline case: one bad order must not strand everything behind it.
    final store = FakeStore();
    final delivered = <String>[];
    final outbox = Outbox(store: store, senders: {
      'order.push': (e) async {
        if (e.payloadUuid == 'poison') throw PermanentlyRejected('deleted product');
        delivered.add(e.payloadUuid);
      },
    });
    await outbox.enqueue('order.push', 'poison', {});
    for (final u in ['a', 'b', 'c']) {
      await outbox.enqueue('order.push', u, {});
    }
    final sent = await outbox.drain();
    expect(sent, 3);
    expect(delivered, ['a', 'b', 'c']);
    expect(store.deadReasons.values.single, 'deleted product');
  });

  test('a transient failure still stops the drain and keeps order', () async {
    final store = FakeStore();
    final delivered = <String>[];
    var online = false;
    final outbox = Outbox(store: store, senders: {
      'order.push': (e) async {
        if (!online) throw Exception('connection refused');
        delivered.add(e.payloadUuid);
      },
    });
    for (final u in ['a', 'b']) {
      await outbox.enqueue('order.push', u, {});
    }
    expect(await outbox.drain(), 0);
    expect(delivered, isEmpty);
    online = true;
    expect(await outbox.drain(), 2);
    expect(delivered, ['a', 'b']);
  });

  test('an entry failing forever is eventually parked rather than blocking', () async {
    final store = FakeStore();
    final outbox = Outbox(store: store, senders: {
      'order.push': (e) async => throw Exception('always fails'),
    }, maxAttempts: 3);
    await outbox.enqueue('order.push', 'bad', {});
    await outbox.enqueue('order.push', 'good', {});
    // Each drain stops on the transient failure, incrementing attempts.
    for (var i = 0; i < 3; i++) {
      await outbox.drain();
    }
    expect(store.deadIds, contains(1));
  });

  test('a big backlog drains in one call, not one batch per tick', () async {
    // A week offline is thousands of entries; one batch per 30s tick would take
    // over an hour of pacing alone.
    final store = FakeStore();
    final outbox = Outbox(store: store, senders: {'order.push': (e) async {}},
        batchSize: 20);
    for (var i = 0; i < 250; i++) {
      await outbox.enqueue('order.push', 'u\$i', {});
    }
    expect(await outbox.drain(), 250);
  });
}
