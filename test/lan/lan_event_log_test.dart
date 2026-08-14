import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/db/database.dart';
import 'package:offline_pos/core/lan/lan_event.dart';
import 'package:offline_pos/core/lan/lan_event_log.dart';

import '../db/sqlite_loader.dart';

void main() {
  setUpAll(useSystemSqlite);

  late Db db;
  late LanEventLog log;
  setUp(() {
    db = Db.open(':memory:');
    log = LanEventLog(db, deviceId: 'till-a');
  });
  tearDown(() => db.close());

  test('appends in order and serves everything after a cursor', () {
    final first = log.append(LanEventKind.orderUpsert, 'order-1', {'uuid': 'order-1'});
    final second = log.append(LanEventKind.kitchenStatus, 'order-1', {'status': 'ready'});

    expect(second.seq, greaterThan(first.seq));
    expect(log.lastSeq, second.seq);
    expect(log.since(0).map((e) => e.seq), [first.seq, second.seq]);
    expect(log.since(first.seq).single.seq, second.seq);
    expect(log.since(second.seq), isEmpty);
  });

  test('an event survives the round trip through its own wire format', () {
    final event = log.append(LanEventKind.orderUpsert, 'order-1', {
      'uuid': 'order-1',
      'total': 12.5,
      'lines': [
        {'name': 'Pizza'}
      ],
    });
    final back = LanEvent.fromMap(event.toMap());

    expect(back.kind, LanEventKind.orderUpsert);
    expect(back.originDeviceId, 'till-a');
    expect(back.seq, event.seq);
    expect(back.recordUuid, 'order-1');
    expect(back.at, event.at);
    expect((back.payload['lines'] as List).single, {'name': 'Pizza'});
  });

  test('an unreadable event is refused rather than half-applied', () {
    expect(() => LanEvent.fromMap({'kind': 'order.invented', 'seq': 1}),
        throwsA(isA<FormatException>()));
    expect(
        () => LanEvent.fromMap({
              'kind': LanEventKind.orderUpsert.wire,
              'origin': 'till-b',
              'seq': 1,
              'uuid': 'order-1',
            }),
        throwsA(isA<FormatException>()),
        reason: 'an event with no payload describes nothing');
  });

  test('a cursor only ever moves forward', () {
    expect(log.cursorFor('till-b'), 0);
    log.setCursor('till-b', 12);
    expect(log.cursorFor('till-b'), 12);
    // A reply that arrives out of order must not make this till re-read what it
    // has already applied.
    log.setCursor('till-b', 5);
    expect(log.cursorFor('till-b'), 12);
    expect(log.cursors(), {'till-b': 12});
  });

  test('appending stamps the clock the conflict rule reads', () {
    expect(log.clockFor('order-1'), isNull);
    final event = log.append(LanEventKind.orderUpsert, 'order-1', const {});

    expect(log.clockFor('order-1')!.origin, 'till-a');
    expect(log.clockFor('order-1')!.at, event.at);

    // A peer's change to the same record replaces the stamp, so the next event
    // about it is judged against whoever really wrote last.
    log.stampClock(
        'order-1', LanEventKind.orderUpsert, event.at.add(const Duration(seconds: 1)), 'till-b');
    expect(log.clockFor('order-1')!.origin, 'till-b');
  });
}
