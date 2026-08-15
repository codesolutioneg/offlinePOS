import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/lan/lan_event.dart';
import 'package:offline_pos/core/lan/lan_shift_board.dart';

import '../db/sqlite_loader.dart';
import 'shop.dart';

/// One till closing its trading day, told to the rest of the shop.
///
/// Advisory in both directions: the notice crosses, and nothing about it can stop
/// the till that hears it from selling. What it does about it is the device's own
/// policy, tested where that policy is read.
void main() {
  setUpAll(useSystemSqlite);

  late TestShop shop;
  setUp(() => shop = TestShop());
  tearDown(() => shop.close());

  /// The event a till publishes when its drawer is counted.
  void closeTheDay(TestTill till, {required String date, String? cashier}) =>
      till.fabric.publish(
        LanEventKind.shiftLifecycle,
        'day-close-${till.deviceId}',
        LanShiftNotice(
          deviceId: till.deviceId,
          deviceName: till.name,
          businessDate: date,
          at: DateTime.utc(2026, 3, 1, 23),
          cashierId: cashier,
        ).toMap(),
      );

  test('the other till learns the day was closed, and by which device', () async {
    final a = shop.add('till-a', name: 'Front');
    final b = shop.add('till-b', name: 'Bar');
    shop.introduceAll();

    closeTheDay(a, date: '2026-03-01', cashier: 'sara');
    await shop.settle();

    final notice = LanShiftBoard(b.settings).closedOn('2026-03-01')!;
    expect(notice.deviceName, 'Front');
    expect(notice.deviceId, 'till-a');
    expect(notice.cashierId, 'sara');
  });

  test('yesterday\'s close is not today\'s business', () async {
    final a = shop.add('till-a');
    final b = shop.add('till-b');
    shop.introduceAll();

    closeTheDay(a, date: '2026-02-28');
    await shop.settle();

    // The notice is kept, and it is simply not about today, so the nudge expires
    // at the cutover on its own rather than needing to be cleared.
    expect(LanShiftBoard(b.settings).closedOn('2026-03-01'), isNull);
    expect(LanShiftBoard(b.settings).notices(), hasLength(1));
  });

  test('a till that was off the LAN learns of the close when it rejoins', () async {
    final a = shop.add('till-a', name: 'Front');
    final b = shop.add('till-b');
    shop.introduceAll();
    shop.unreachable.add('till-b');

    closeTheDay(a, date: '2026-03-01');
    await shop.settle();
    expect(LanShiftBoard(b.settings).notices(), isEmpty);

    shop.unreachable.remove('till-b');
    await shop.settle();
    expect(LanShiftBoard(b.settings).closedOn('2026-03-01')!.deviceName, 'Front');
  });

  test('a second close from the same till replaces its notice', () async {
    final a = shop.add('till-a');
    final b = shop.add('till-b');
    shop.introduceAll();

    closeTheDay(a, date: '2026-03-01', cashier: 'sara');
    await shop.settle();
    closeTheDay(a, date: '2026-03-02', cashier: 'ana');
    await shop.settle();

    final board = LanShiftBoard(b.settings);
    expect(board.notices(), hasLength(1));
    expect(board.closedOn('2026-03-01'), isNull);
    expect(board.closedOn('2026-03-02')!.cashierId, 'ana');
  });

  test('hearing a close never stops the till that heard it selling', () async {
    final a = shop.add('till-a');
    final b = shop.add('till-b');
    shop.introduceAll();

    closeTheDay(a, date: '2026-03-01');
    await shop.settle();

    // The applier writes a notice on a board and touches nothing else: no order,
    // no shift, nothing a sale on this till passes through.
    final tab = heldOrder('till-b', table: '7');
    b.orders.save(tab);
    expect(b.orders.held().map((o) => o.uuid), [tab.uuid]);
    expect(b.refusals.where((r) => r.startsWith('lan.event.refused')), isEmpty);
  });
}
