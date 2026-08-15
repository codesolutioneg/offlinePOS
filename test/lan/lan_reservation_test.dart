import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/db/reservation_store.dart';

import '../db/sqlite_loader.dart';
import 'shop.dart';

/// A booking taken at the counter, reaching the handheld the waiter is holding.
void main() {
  setUpAll(useSystemSqlite);

  late TestShop shop;
  setUp(() => shop = TestShop());
  tearDown(() => shop.close());

  Reservation booking({String name = 'Ahmed', String table = '5'}) => Reservation(
        name: name,
        tableLabel: table,
        covers: 4,
        at: DateTime.utc(2026, 3, 1, 19, 30),
      );

  test('a booking taken on one device is on the other', () async {
    final a = shop.add('till-a');
    final b = shop.add('till-b');
    shop.introduceAll();

    final made = booking();
    a.reservations.save(made);
    await shop.settle();

    final there = b.reservations.byUuid(made.uuid)!;
    expect(there.name, 'Ahmed');
    expect(there.tableLabel, '5');
    expect(there.covers, 4);
    expect(there.at, made.at);
  });

  test('seating them, and calling it off, both cross', () async {
    final a = shop.add('till-a');
    final b = shop.add('till-b');
    shop.introduceAll();

    final made = booking();
    a.reservations.save(made);
    await shop.settle();

    a.reservations.setState(made.uuid, ReservationState.seated);
    await shop.settle();
    expect(b.reservations.byUuid(made.uuid)!.state, ReservationState.seated);

    a.reservations.remove(made.uuid);
    await shop.settle();
    expect(b.reservations.byUuid(made.uuid), isNull);
  });

  test('a device that was off the LAN catches up on the evening\'s book',
      () async {
    final a = shop.add('till-a');
    final b = shop.add('till-b');
    shop.introduceAll();
    shop.unreachable.add('till-b');

    a.reservations.save(booking(name: 'Seven', table: '5'));
    a.reservations.save(booking(name: 'Eight', table: '6'));
    await shop.settle();
    expect(b.reservations.all(), isEmpty);

    shop.unreachable.remove('till-b');
    await shop.settle();
    expect(b.reservations.all().map((r) => r.name).toSet(), {'Seven', 'Eight'});
  });

  test('the last change wins, so two devices agree on where they sit', () async {
    final a = shop.add('till-a');
    final b = shop.add('till-b');
    shop.introduceAll();

    final made = booking();
    a.reservations.save(made);
    await shop.settle();
    // The counter moves them to a bigger table after the handheld took the call.
    b.reservations.save(made.copyWith(tableLabel: '9', covers: 6));
    await shop.settle();

    expect(a.reservations.byUuid(made.uuid)!.tableLabel, '9');
    expect(a.reservations.byUuid(made.uuid)!.covers, 6);
    expect(b.reservations.byUuid(made.uuid)!.tableLabel, '9');
  });
}
