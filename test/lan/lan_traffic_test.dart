import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/lan/lan_event.dart';
import 'package:offline_pos/core/lan/lan_fabric.dart';
import 'package:offline_pos/core/lan/lan_traffic.dart';

import '../db/sqlite_loader.dart';
import 'shop.dart';

LanEvent eventAt(String origin, DateTime at) => LanEvent(
      kind: LanEventKind.orderUpsert,
      originDeviceId: origin,
      seq: 1,
      recordUuid: 'o-1',
      payload: const {},
      at: at,
    );

/// The till's own fabric, rebuilt with [traffic] fed, the way the shipped wiring
/// builds it.
LanFabric withTraffic(TestTill till, LanTraffic traffic) => LanFabric(
      deviceId: till.deviceId,
      log: till.log,
      applier: till.applier,
      peers: till.peers,
      fetch: (peer, since) => till.shop.fetch(till.deviceId, peer, since),
      notify: (peer, events) => till.shop.notify(till.deviceId, peer, events),
      traffic: traffic,
    );

/// The per-device figures the shop network screen shows: what went each way, how
/// long a round trip took, and how late a change landed.
void main() {
  setUpAll(useSystemSqlite);

  late TestShop shop;
  setUp(() => shop = TestShop());
  tearDown(() => shop.close());

  test('a pull counts what it read from the peer', () async {
    final traffic = LanTraffic();
    shop.add('till-a');
    final b = shop.add('till-b');
    shop.introduceAll();
    b.orders.save(heldOrder('till-b'));
    b.orders.save(heldOrder('till-b', table: '6'));

    final events = await shop.fetch('till-a', shop.peerFor(b), 0);
    traffic.pulled('till-b', events.events, const Duration(milliseconds: 12));

    final t = traffic.of('till-b');
    expect(t.pulled, events.events.length);
    expect(t.pulled, greaterThan(0));
    expect(t.lastPullTook, const Duration(milliseconds: 12));
    expect(t.lastPullAt, isNotNull);
  });

  test('the arrival delay is read on this device\'s clock', () async {
    final b = shop.add('till-b');
    shop.add('till-a');
    shop.introduceAll();
    b.orders.save(heldOrder('till-b'));
    final events = (await shop.fetch('till-a', shop.peerFor(b), 0)).events;
    final madeAt = events.first.at.toUtc();

    // The peer's clock runs 30 s ahead, and the change lands 2 s after it was
    // made by this device's clock.
    final traffic = LanTraffic(
      clockOffsetOf: (_) => const Duration(seconds: 30),
      now: () => madeAt.subtract(const Duration(seconds: 28)),
    );
    traffic.received('till-b', events.take(1).toList());

    expect(traffic.of('till-b').lastDelay, const Duration(seconds: 2));
    expect(traffic.of('till-b').received, 1);
  });

  test('a change relayed from a third till does not count toward the delay',
      () async {
    final c = shop.add('till-c');
    shop.add('till-a');
    shop.introduceAll();
    c.orders.save(heldOrder('till-c'));
    final events = (await shop.fetch('till-a', shop.peerFor(c), 0)).events;

    final traffic = LanTraffic();
    traffic.received('till-b', events);

    expect(traffic.of('till-b').received, events.length);
    expect(traffic.of('till-b').lastDelay, isNull);
  });

  test('average and worst are over the recent window only', () {
    final at = DateTime.utc(2026, 3, 1, 12);
    var now = at;
    final traffic = LanTraffic(now: () => now, delayWindow: 2);
    final shopEvents = <Duration>[
      const Duration(seconds: 9),
      const Duration(seconds: 1),
      const Duration(seconds: 3),
    ];
    for (final d in shopEvents) {
      now = at.add(d);
      traffic.received('till-b', [eventAt('till-b', at)]);
    }

    final t = traffic.of('till-b');
    expect(t.worstDelay, const Duration(seconds: 3));
    expect(t.averageDelay, const Duration(seconds: 2));
  });

  test('the fabric feeds the figures as it pulls and pushes', () async {
    final a = shop.add('till-a');
    final b = shop.add('till-b');
    final traffic = LanTraffic();
    shop.introduceAll();
    final fabric = withTraffic(a, traffic);
    b.orders.save(heldOrder('till-b'));
    a.orders.save(heldOrder('till-a', table: '9'));

    await fabric.pass();

    final t = traffic.of('till-b');
    expect(t.pulled, greaterThan(0));
    expect(t.pushed, greaterThan(0));
    expect(t.lastPullTook, isNotNull);
    expect(t.lastPushTook, isNotNull);
  });

  test('a failed pull is kept as the last problem', () async {
    final a = shop.add('till-a');
    shop.add('till-b');
    final traffic = LanTraffic();
    shop.introduceAll();
    shop.unreachable.add('till-b');

    await withTraffic(a, traffic).pass();

    expect(traffic.of('till-b').lastError, contains('unreachable'));
    expect(traffic.of('till-b').lastErrorAt, isNotNull);
  });
}
