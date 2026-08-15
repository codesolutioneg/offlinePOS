import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/db/database.dart';
import 'package:offline_pos/core/db/reservation_store.dart';

import 'sqlite_loader.dart';

/// The book on disk: what it keeps, what it hands the floor, and what it refuses to
/// forget.
void main() {
  setUpAll(useSystemSqlite);

  late Db db;
  late ReservationStore store;
  final now = DateTime.utc(2026, 3, 1, 18);

  setUp(() {
    db = Db.open(':memory:');
    store = ReservationStore(db);
  });
  tearDown(() => db.close());

  Reservation booking({
    String name = 'Ahmed',
    String? table = '5',
    int minutesFromNow = 30,
    int covers = 4,
  }) =>
      Reservation(
        name: name,
        phone: '0100',
        tableLabel: table,
        covers: covers,
        at: now.add(Duration(minutes: minutesFromNow)),
      );

  test('a booking survives the round trip whole', () {
    final made = booking();
    store.save(made);

    final read = store.byUuid(made.uuid)!;
    expect(read.name, 'Ahmed');
    expect(read.phone, '0100');
    expect(read.tableLabel, '5');
    expect(read.covers, 4);
    expect(read.at, made.at);
    expect(read.state, ReservationState.booked);
  });

  test('the floor is told what is due, and only what is still coming', () {
    store.save(booking(name: 'Soon', minutesFromNow: 20));
    store.save(booking(name: 'Later', table: '6', minutesFromNow: 240));
    final cancelled = booking(name: 'Off', table: '7', minutesFromNow: 15);
    store.save(cancelled);
    store.setState(cancelled.uuid, ReservationState.cancelled);

    final due = store.dueByTable(now);
    expect(due.keys, ['5']);
    expect(due['5']!.name, 'Soon');
  });

  test('a table whose guests are late still reads as spoken for', () {
    store.save(booking(name: 'Late', minutesFromNow: -20));
    expect(store.dueByTable(now)['5']!.name, 'Late');
  });

  test('a booking with no table yet is nobody\'s tile', () {
    store.save(booking(name: 'Nowhere', table: null, minutesFromNow: 10));
    expect(store.dueByTable(now), isEmpty);
    expect(store.all(), hasLength(1));
  });

  test('the soonest booking wins a table that has two', () {
    store.save(booking(name: 'Second', minutesFromNow: 50));
    store.save(booking(name: 'First', minutesFromNow: 10));
    expect(store.dueByTable(now)['5']!.name, 'First');
  });

  test('seated and no-show are kept, because a shop counts both', () {
    final sat = booking(name: 'Sat');
    final missing = booking(name: 'Missing', table: '6');
    store.save(sat);
    store.save(missing);
    store.setState(sat.uuid, ReservationState.seated);
    store.setState(missing.uuid, ReservationState.noShow);

    expect(store.byUuid(sat.uuid)!.state, ReservationState.seated);
    expect(store.byUuid(missing.uuid)!.state, ReservationState.noShow);
    // Neither is still expected, so neither holds a table on the plan.
    expect(store.dueByTable(now), isEmpty);
  });

  test('a booking can be moved to another table and time', () {
    final made = booking();
    store.save(made);
    store.save(made.copyWith(tableLabel: '9', at: now.add(const Duration(hours: 1))));

    expect(store.all(), hasLength(1), reason: 'moved, not duplicated');
    expect(store.byUuid(made.uuid)!.tableLabel, '9');
    expect(store.dueByTable(now).containsKey('5'), isFalse);
  });

  test('a booking taken off the book is gone', () {
    final made = booking();
    store.save(made);
    store.remove(made.uuid);
    expect(store.byUuid(made.uuid), isNull);
  });

  test('the day reads in time order', () {
    store.save(booking(name: 'Nine', minutesFromNow: 180));
    store.save(booking(name: 'Seven', minutesFromNow: 60));
    store.save(booking(name: 'Eight', minutesFromNow: 120));

    expect(
        store
            .between(now, now.add(const Duration(hours: 6)))
            .map((r) => r.name),
        ['Seven', 'Eight', 'Nine']);
  });
}
