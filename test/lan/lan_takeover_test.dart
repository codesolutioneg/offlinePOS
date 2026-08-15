import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/domain/order.dart';

import '../db/sqlite_loader.dart';
import 'shop.dart';

/// A tab changing hands between two tills.
///
/// The property every one of these protects is the same: at no instant may two
/// devices both be able to settle one bill. The interesting cases are all the ones
/// where the handover does NOT happen.
void main() {
  setUpAll(useSystemSqlite);

  late TestShop shop;
  setUp(() => shop = TestShop());
  tearDown(() => shop.close());

  test('the counter takes a tab the handheld parked, and only one till owns it',
      () async {
    final a = shop.add('till-a', name: 'Handheld');
    final b = shop.add('till-b', name: 'Counter');
    shop.introduceAll();
    a.settings.lanAllowTakeover = true;

    final tab = heldOrder('till-a', table: '5');
    a.orders.save(tab);
    await shop.settle();
    expect(b.orders.held(), isEmpty, reason: 'not settleable here before the ask');

    final taken = await shop.claim('till-b', a, tab.uuid, cashier: 'omar');
    expect(taken, isNotNull);

    // The counter can settle it now, and the handheld cannot.
    expect(b.orders.held().map((o) => o.uuid), [tab.uuid]);
    expect(a.orders.held(), isEmpty);
    expect(a.orders.heldElsewhere().map((o) => o.uuid), [tab.uuid]);
    // The bill crossed whole, not just its ownership.
    expect(b.orders.byUuid(tab.uuid)!.lines.single.name, 'Pizza');
    expect(b.orders.byUuid(tab.uuid)!.tableLabel, '5');
    // Both sides can explain it the morning after.
    expect(a.audited.any((e) => e.startsWith('order.claim.granted')), isTrue);
    expect(b.audited.any((e) => e.startsWith('order.claim.taken')), isTrue);
  });

  test('a third till follows the handover, so the floor sends the waiter right',
      () async {
    final a = shop.add('till-a');
    shop.add('till-b');
    final c = shop.add('till-c');
    shop.introduceAll();
    a.settings.lanAllowTakeover = true;

    final tab = heldOrder('till-a', table: '5');
    a.orders.save(tab);
    await shop.settle();
    await shop.claim('till-b', a, tab.uuid);
    await shop.settle();

    expect(c.orders.byUuid(tab.uuid)!.deviceId, 'till-b');
    expect(c.orders.held(), isEmpty);
    // And the tab is still on the floor exactly once.
    expect(c.orders.heldAnywhere().map((o) => o.uuid), [tab.uuid]);
  });

  test('a claim while the owner is unreachable is refused, not queued', () async {
    final a = shop.add('till-a');
    final b = shop.add('till-b');
    shop.introduceAll();
    a.settings.lanAllowTakeover = true;

    final tab = heldOrder('till-a', table: '5');
    a.orders.save(tab);
    await shop.settle();
    shop.unreachable.add('till-a');

    // The ask itself fails, which is the answer: a till that cannot be asked
    // cannot let go, and taking the tab anyway is how one bill is settled twice.
    await expectLater(
        shop.claim('till-b', a, tab.uuid), throwsA(isA<StateError>()));
    expect(b.orders.held(), isEmpty);
    expect(a.orders.held().map((o) => o.uuid), [tab.uuid],
        reason: 'the owner keeps a tab it never agreed to give up');
  });

  test('a till with takeovers switched off keeps its tab', () async {
    final a = shop.add('till-a');
    final b = shop.add('till-b');
    shop.introduceAll();

    final tab = heldOrder('till-a', table: '5');
    a.orders.save(tab);
    await shop.settle();

    expect(await shop.claim('till-b', a, tab.uuid), isNull);
    expect(a.orders.held().map((o) => o.uuid), [tab.uuid]);
    expect(b.orders.held(), isEmpty);
    expect(a.audited.any((e) => e.contains('switched off')), isTrue);
  });

  test('the second claimer is refused, so two tills never own one tab', () async {
    final a = shop.add('till-a');
    final b = shop.add('till-b');
    final c = shop.add('till-c');
    shop.introduceAll();
    a.settings.lanAllowTakeover = true;

    final tab = heldOrder('till-a', table: '5');
    a.orders.save(tab);
    await shop.settle();

    expect(await shop.claim('till-b', a, tab.uuid), isNotNull);
    expect(await shop.claim('till-c', a, tab.uuid), isNull,
        reason: 'the owner has already let go, so it has nothing to give');
    expect(c.orders.held(), isEmpty);
    expect(b.orders.held().map((o) => o.uuid), [tab.uuid]);
  });

  test('a paid sale is never handed over', () async {
    final a = shop.add('till-a');
    final b = shop.add('till-b');
    shop.introduceAll();
    a.settings.lanAllowTakeover = true;

    final sale = heldOrder('till-a', table: '5')..state = OrderState.paid;
    a.orders.save(sale);
    await shop.settle();

    expect(await shop.claim('till-b', a, sale.uuid), isNull);
    // The till that took the money is the one that books it, whatever anyone asks.
    expect(a.orders.awaitingSync().map((o) => o.uuid), [sale.uuid]);
    expect(b.orders.awaitingSync(), isEmpty);
  });

  test('an older copy still crossing the LAN cannot hand the tab back', () async {
    final a = shop.add('till-a');
    final b = shop.add('till-b');
    shop.introduceAll();
    a.settings.lanAllowTakeover = true;

    final tab = heldOrder('till-a', table: '5');
    a.orders.save(tab);
    // Deliberately NOT settled first: the original upsert is still sitting in the
    // owner's log unread when the tab is taken, which is the race this guards.
    await shop.claim('till-b', a, tab.uuid);
    await shop.settle();

    expect(b.orders.held().map((o) => o.uuid), [tab.uuid]);
    expect(b.orders.byUuid(tab.uuid)!.deviceId, 'till-b');
    expect(a.orders.held(), isEmpty);
  });

  test('a claim for a tab this till has never seen is deferred, then dropped',
      () async {
    final a = shop.add('till-a');
    shop.add('till-b');
    final c = shop.add('till-c');
    shop.introduceAll();
    a.settings.lanAllowTakeover = true;

    final tab = heldOrder('till-a', table: '5');
    a.orders.save(tab);
    // Nothing is settled first, so when the handover event reaches C the tab is a
    // record it has never seen: the deferral rule holds C's cursor below it rather
    // than dropping an ownership change on the floor.
    await shop.claim('till-b', a, tab.uuid);
    await shop.settle(rounds: 6);
    expect(c.orders.byUuid(tab.uuid)!.deviceId, 'till-b');
  });
}
