import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/db/table_store.dart';
import 'package:offline_pos/core/lan/lan_event.dart';

import '../db/sqlite_loader.dart';
import 'shop.dart';

/// Sharing the room out reaches the handhelds.
///
/// The manager hands the tables out on one device and the waiters read them on
/// others, so an assignment that does not replicate is worse than none: a handheld
/// that never heard it would refuse its own waiter their own section.
void main() {
  setUpAll(useSystemSqlite);

  late TestShop shop;
  setUp(() => shop = TestShop());
  tearDown(() => shop.close());

  test('a table assigned on the manager till is that waiter\'s on the handheld',
      () async {
    final a = shop.add('till-a', name: 'Counter');
    final b = shop.add('till-b', name: 'Handheld');
    shop.introduceAll();

    final t = a.tables.add(name: 'T1');
    a.assignments.assign(t.id, 'ana', by: 'boss');
    await shop.settle();

    expect(b.assignments.cashierFor(t.id), 'ana');
    expect(b.refusals.where((r) => r.startsWith('lan.event.refused')), isEmpty);
  });

  test('moving a section to another waiter reaches the other till', () async {
    final a = shop.add('till-a');
    final b = shop.add('till-b');
    shop.introduceAll();

    final t = a.tables.add(name: 'T1');
    a.assignments.assign(t.id, 'ana', by: 'boss');
    await shop.settle();
    expect(b.assignments.cashierFor(t.id), 'ana');

    a.assignments.assign(t.id, 'omar', by: 'boss');
    await shop.settle();

    expect(b.assignments.cashierFor(t.id), 'omar');
  });

  test('handing the room back at the Z empties it on every device', () async {
    final a = shop.add('till-a');
    final b = shop.add('till-b');
    shop.introduceAll();

    final one = a.tables.add(name: 'T1');
    final two = a.tables.add(name: 'T2');
    a.assignments.assign(one.id, 'ana', by: 'boss');
    a.assignments.assign(two.id, 'omar', by: 'boss');
    await shop.settle();
    expect(b.assignments.byTable().length, 2);

    a.assignments.clearAll();
    await shop.settle();

    expect(b.assignments.isEmpty, isTrue);
  });

  test('a handheld that was off the LAN catches up on who has what', () async {
    final a = shop.add('till-a');
    final b = shop.add('till-b');
    shop.introduceAll();

    shop.unreachable.add('till-b');
    final t = a.tables.add(name: 'T1');
    a.assignments.assign(t.id, 'ana', by: 'boss');
    await shop.settle();
    expect(b.assignments.isEmpty, isTrue);

    shop.unreachable.remove('till-b');
    await shop.settle();

    expect(b.assignments.cashierFor(t.id), 'ana');
  });

  test('an assignment for a table this till has not seen yet waits for it', () async {
    final a = shop.add('till-a');
    final b = shop.add('till-b');

    // The assignment on its own, with the table it names never served: this is the
    // ordering hazard, and the answer is to hold the cursor rather than write a row
    // pointing at nothing.
    final t = PosTable(id: 'table-nobody-has', name: 'T9');
    a.tables.upsert(t);
    a.assignments.assign(t.id, 'ana', by: 'boss');
    final page = a.log.since(0);
    final assignment = page
        .where((e) => e.kind == LanEventKind.tableAssignment)
        .toList();
    expect(assignment, hasLength(1));

    b.applier.applyAll('till-a', assignment, highSeq: assignment.first.seq);

    expect(b.assignments.isEmpty, isTrue);
    // Held below the event, so the next pass asks for it again once the table lands.
    expect(b.log.cursorFor('till-a'), lessThan(assignment.first.seq));

    // And once the table is there, the same event lands.
    b.tables.upsert(t, announce: false);
    b.applier.applyAll('till-a', assignment, highSeq: assignment.first.seq);
    expect(b.assignments.cashierFor(t.id), 'ana');
  });

  test('the floor plan and the assignment do not overwrite each other', () async {
    final a = shop.add('till-a');
    final b = shop.add('till-b');
    shop.introduceAll();

    final t = a.tables.add(name: 'T1');
    await shop.settle();

    // Assigned on the handheld, dragged on the counter. Two records, so the later
    // write of one cannot roll the other back: that is the reason this is not a
    // column on the table row.
    b.assignments.assign(t.id, 'ana', by: 'boss');
    a.tables.upsert(t.copyWith(x: 4, y: 2));
    await shop.settle();

    expect(a.assignments.cashierFor(t.id), 'ana');
    expect(b.assignments.cashierFor(t.id), 'ana');
    expect(a.tables.byId(t.id)?.x, 4);
    expect(b.tables.byId(t.id)?.x, 4);
  });
}
