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
  Future<List<OutboxEntry>> pending({int limit = 20}) async =>
      entries.where((e) => !sent.contains(e.id)).take(limit).toList();

  @override
  Future<void> markSent(int id) async => sent.add(id);

  @override
  Future<void> markFailed(int id, String error) async {
    entries.firstWhere((e) => e.id == id)
      ..attempts += 1
      ..lastError = error;
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
    expect(store.entries.single.lastError, contains('no sender'));
  });
}
