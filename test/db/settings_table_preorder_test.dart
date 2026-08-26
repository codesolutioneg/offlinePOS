import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/db/database.dart';
import 'package:offline_pos/core/db/settings_store.dart';
import 'package:offline_pos/domain/table_preorder.dart';

import 'sqlite_loader.dart';

/// What a table opens with, and which list wins.
///
/// The rule a restaurant needs is "the room, unless this table says otherwise", and
/// the awkward case is the table that must open with NOTHING while the room around it
/// charges a cover. That is a different answer from "follow the room", so the two have
/// to survive being written and read back.
void main() {
  setUpAll(useSystemSqlite);

  late Db db;
  late SettingsStore settings;

  setUp(() {
    db = Db.open(':memory:');
    settings = SettingsStore(db);
  });
  tearDown(() => db.close());

  test('nothing is set up until somebody sets it up', () {
    expect(settings.hasPreorders, isFalse);
    expect(settings.sectionPreorders('Main'), isEmpty);
    expect(settings.tablePreorders('t1'), isNull);
    expect(settings.preordersFor(tableId: 't1', section: 'Main'), isEmpty);
  });

  test('a section list reaches every table in the room', () {
    settings.setSectionPreorders(
        'Main', const [TablePreorder(productId: 7, perGuest: true)]);

    expect(settings.hasPreorders, isTrue);
    final lines = settings.preordersFor(tableId: 't1', section: 'Main');
    expect(lines, hasLength(1));
    expect(lines.single.productId, 7);
    expect(lines.single.perGuest, isTrue);
    // And not to a different room.
    expect(settings.preordersFor(tableId: 't9', section: 'Terrace'), isEmpty);
  });

  test('a table with its own list ignores the room, it does not add to it', () {
    settings.setSectionPreorders('Main', const [TablePreorder(productId: 7)]);
    settings.setTablePreorders('t1', const [TablePreorder(productId: 12, quantity: 2)]);

    final lines = settings.preordersFor(tableId: 't1', section: 'Main');
    expect(lines, hasLength(1));
    expect(lines.single.productId, 12);
    expect(lines.single.quantity, 2);
    // The rest of the room is untouched.
    expect(settings.preordersFor(tableId: 't2', section: 'Main').single.productId, 7);
  });

  test('a table can be told to open with nothing while the room charges a cover', () {
    settings.setSectionPreorders('Main', const [TablePreorder(productId: 7)]);
    settings.setTablePreorders('t1', const []);

    // Not the same as following the room: this table opens empty on purpose.
    expect(settings.tablePreorders('t1'), isEmpty);
    expect(settings.preordersFor(tableId: 't1', section: 'Main'), isEmpty);
    expect(settings.preordersFor(tableId: 't2', section: 'Main'), hasLength(1));
  });

  test('putting a table back on the room clears the override', () {
    settings.setSectionPreorders('Main', const [TablePreorder(productId: 7)]);
    settings.setTablePreorders('t1', const []);
    settings.setTablePreorders('t1', null);

    expect(settings.tablePreorders('t1'), isNull);
    expect(settings.preordersFor(tableId: 't1', section: 'Main'), hasLength(1));
  });

  test('a per-guest line is multiplied by the covers, and never by zero', () {
    const cover = TablePreorder(productId: 7, perGuest: true);
    expect(cover.quantityFor(4), 4);
    expect(cover.quantityFor(1), 1);
    // A table seated without a count still charges one, never nothing: a line worth
    // zero on a bill reads as a broken till.
    expect(cover.quantityFor(0), 1);

    const bottle = TablePreorder(productId: 8, quantity: 2);
    expect(bottle.quantityFor(6), 2);
  });

  test('a garbled stored value costs the pre-orders, never a seating', () {
    settings.setString('table_preorders', 'not json at all');

    expect(settings.sectionPreorders('Main'), isEmpty);
    expect(settings.preordersFor(tableId: 't1', section: 'Main'), isEmpty);
  });

  test('an unreadable line is skipped and the rest of the list survives', () {
    settings.setString('table_preorders',
        '{"sections":{"Main":[{"product":"seven"},{"product":8,"qty":2}]}}');

    final lines = settings.sectionPreorders('Main');
    expect(lines, hasLength(1));
    expect(lines.single.productId, 8);
  });

  test('the lists survive a round trip through storage', () {
    settings.setSectionPreorders('Terrace', const [
      TablePreorder(productId: 7, perGuest: true),
      TablePreorder(productId: 8, quantity: 2),
    ]);
    settings.setTablePreorders('t1', const [TablePreorder(productId: 9, quantity: 3)]);

    final fresh = SettingsStore(db);
    final section = fresh.sectionPreorders('Terrace');
    expect(section.map((l) => l.productId), [7, 8]);
    expect(section.first.perGuest, isTrue);
    expect(section.last.quantity, 2);
    expect(fresh.tablePreorders('t1')!.single.quantity, 3);
  });

  test('a product typed on this till is not dropped from the list', () {
    // CatalogueStore mints NEGATIVE ids for a product a manager types here, so any
    // "id below zero" sentinel or filter would silently drop a shop's own cover
    // charge from every bill. Nothing in this class may treat an id as a marker.
    settings.setSectionPreorders('Main', const [
      TablePreorder(productId: -1, perGuest: true),
      TablePreorder(productId: -2, quantity: 2),
    ]);

    final lines = settings.preordersFor(tableId: 't1', section: 'Main');
    expect(lines.map((l) => l.productId), [-1, -2]);
    expect(lines.first.perGuest, isTrue);
  });

  test('an empty override survives storage without standing in for a product', () {
    settings.setSectionPreorders('Main', const [TablePreorder(productId: -1)]);
    settings.setTablePreorders('t1', const []);

    final fresh = SettingsStore(db);
    expect(fresh.tablePreorders('t1'), isEmpty);
    expect(fresh.preordersFor(tableId: 't1', section: 'Main'), isEmpty);
    // And the local-id product on the room's list is still there.
    expect(fresh.preordersFor(tableId: 't2', section: 'Main').single.productId, -1);
  });

  test('every table with a list of its own is readable in one go', () {
    settings.setTablePreorders('t1', const [TablePreorder(productId: 11)]);
    settings.setTablePreorders('t2', const []);

    // What a screen drawing a whole room reads, instead of asking per tile.
    final overrides = settings.tablePreorderOverrides();
    expect(overrides.keys.toSet(), {'t1', 't2'});
    expect(overrides['t1']!.single.productId, 11);
    expect(overrides['t2'], isEmpty);
  });
}
