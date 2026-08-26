import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/db/table_store.dart';
import 'package:offline_pos/core/lan/lan_event.dart';
import 'package:offline_pos/domain/table_preorder.dart';

import '../db/sqlite_loader.dart';
import 'shop.dart';

/// Sharing the room out, and what a table opens with, reaching the handhelds.
///
/// The manager sets both on one device and the waiters work off others, so either one
/// failing to replicate is worse than not having it: a handheld that never heard the
/// assignment refuses its own waiter their own section, and one that never heard the
/// cover charge opens a bill without the line every other till puts on it.
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

  test('a cover charge set on the counter reaches the handheld', () async {
    final a = shop.add('till-a', name: 'Counter');
    final b = shop.add('till-b', name: 'Handheld');
    shop.introduceAll();

    a.settings.setSectionPreorders(
        'Main', const [TablePreorder(productId: 11, perGuest: true)]);
    await shop.settle();

    // Without this the handheld would seat the same table and open a bill with no
    // cover charge on it, and the shop would find out from a customer.
    final lines = b.settings.sectionPreorders('Main');
    expect(lines, hasLength(1));
    expect(lines.single.productId, 11);
    expect(lines.single.perGuest, isTrue);
    expect(b.refusals.where((r) => r.startsWith('lan.event.refused')), isEmpty);
  });

  test('one table opening with nothing reaches the other till as nothing', () async {
    final a = shop.add('till-a');
    final b = shop.add('till-b');
    shop.introduceAll();

    final t = a.tables.add(name: 'T1');
    a.settings.setSectionPreorders('Main', const [TablePreorder(productId: 11)]);
    a.settings.setTablePreorders(t.id, const []);
    await shop.settle();

    // Emptied on purpose is a different answer from following the room, and it has to
    // survive the wire as that difference.
    expect(b.settings.tablePreorders(t.id), isEmpty);
    expect(b.settings.preordersFor(tableId: t.id, section: 'Main'), isEmpty);
    expect(b.settings.preordersFor(tableId: 'other', section: 'Main'), hasLength(1));
  });

  test('putting a table back on its room reaches the other till too', () async {
    final a = shop.add('till-a');
    final b = shop.add('till-b');
    shop.introduceAll();

    final t = a.tables.add(name: 'T1');
    a.settings.setSectionPreorders('Main', const [TablePreorder(productId: 11)]);
    a.settings.setTablePreorders(t.id, const [TablePreorder(productId: 12)]);
    await shop.settle();
    expect(b.settings.tablePreorders(t.id), hasLength(1));

    a.settings.setTablePreorders(t.id, null);
    await shop.settle();

    expect(b.settings.tablePreorders(t.id), isNull);
    expect(b.settings.preordersFor(tableId: t.id, section: 'Main').single.productId, 11);
  });

  test('two rooms edited on two tills do not overwrite each other', () async {
    final a = shop.add('till-a');
    final b = shop.add('till-b');
    shop.introduceAll();

    a.tables.add(name: 'T1', section: 'Main');
    a.tables.add(name: 'T9', section: 'Terrace');
    await shop.settle();

    // Per-room records, so the conflict rule cannot make one manager's edit roll back
    // the other's: that is why this is not one event for the whole map.
    a.settings.setSectionPreorders('Main', const [TablePreorder(productId: 11)]);
    b.settings.setSectionPreorders('Terrace', const [TablePreorder(productId: 12)]);
    await shop.settle();

    for (final till in [a, b]) {
      expect(till.settings.sectionPreorders('Main').single.productId, 11);
      expect(till.settings.sectionPreorders('Terrace').single.productId, 12);
    }
  });
}
