import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/db/database.dart';
import 'package:offline_pos/core/db/settings_store.dart';
import 'package:offline_pos/core/db/table_store.dart';
import 'package:offline_pos/core/printing/printer_discovery.dart';
import 'package:offline_pos/core/printing/printer_registry.dart';
import 'package:offline_pos/core/sync/dishflow_config_client.dart';
import 'package:offline_pos/core/sync/dishflow_floor_import.dart';
import 'package:offline_pos/domain/order.dart';
import 'package:offline_pos/domain/table_section_config.dart';

class _NoPrinters extends PrinterDiscovery {
  @override
  Future<bool> probe(String host, {int? port}) async => false;

  @override
  Future<List<DiscoveredPrinter>> scan({int? port, Duration? budget}) async =>
      const [];
}

DishflowDoc _table(
  String id,
  int number,
  String section, {
  int? row,
  int? col,
  String shape = 'rectangle',
  String type = 'table',
  String? label,
}) =>
    (
      id: id,
      fields: {
        'number': number,
        'seats': 4,
        'section': section,
        'branchId': 'nasr',
        'shape': shape,
        'type': type,
        'gridRow': row,
        'gridCol': col,
        'label': label,
        // Live state Dishflow keeps on the table; never part of the plan.
        'status': 'occupied',
        'currentOrderId': 'order-1',
      },
    );

DishflowFloorSnapshot _snapshot() => DishflowFloorSnapshot(
      tables: [
        _table('t1', 1, 'Table', row: 0, col: 0),
        _table('t2', 2, 'Table', row: 0, col: 1, shape: 'circle'),
        _table('sp', 3, 'Table', row: 0, col: 2, type: 'spacer'),
        _table('g1', 1, 'TO Go', row: 0, col: 0, shape: 'square'),
        _table('o1', 1, 'Officer', row: 1, col: 3, label: 'Ahmed'),
        _table('o2', 2, 'Officer'),
      ],
      sections: [
        {'name': 'Table', 'gridCols': 6, 'requireGuestCount': true},
        {'name': 'TO Go', 'defaultOrderType': 'TO GO'},
        {
          'name': 'Officer',
          'gridCols': 4,
          'isStaffSection': true,
          'allowedCategoryIds': ['catA', 'catGone'],
          'allowedPaymentMethodIds': ['7', '9'],
          'employeeAllowedCategories': {
            'Ahmed': ['catB'],
            'Sara': ['__ALL__'],
          },
        },
      ],
      printerDocs: [
        (
          id: 'global',
          fields: {
            'printers': [
              {'id': 'p-k', 'name': 'Kitchen', 'ip_address': '10.0.0.5', 'port': 9100},
              {'id': 'p-b', 'name': 'Bar', 'ip_address': '10.0.0.6', 'fallback_printer_id': 'p-k'},
              {'id': 'p-r', 'name': 'Cashier', 'ip_address': '10.0.0.7'},
            ],
            'settings': [
              {'category_id': 11, 'kitchen_printers': ['p-k']},
              {'category_id': 12, 'kitchen_printers': ['p-b', 'p-deleted']},
              {'category_id': 13, 'kitchen_printer': 'p-k', 'kitchen_printers': []},
            ],
            'productSettings': [
              {'category_id': 501, 'kitchen_printers': ['p-b']},
            ],
            'defaultReceiptPrinterId': 'p-r',
          },
        ),
      ],
      customCategories: [
        (id: 'catA', fields: {'name': 'Food', 'odooId': 11}),
        (id: 'catB', fields: {'name': 'Drinks', 'odooId': 12}),
        (id: 'catGone', fields: {'name': 'Old'}),
      ],
    );

void main() {
  group('DishflowFloorMapper', () {
    late FloorImportPlan plan;

    setUp(() {
      plan = DishflowFloorMapper.plan(
        _snapshot(),
        categoryOfProduct: (id) => id == 501 ? 11 : null,
      );
    });

    PosTable byId(String id) => plan.tables.firstWhere((t) => t.id == id);

    test('keeps the grid position, shape and document id of each table', () {
      expect(byId('t2').x, 1);
      expect(byId('t2').y, 0);
      expect(byId('t2').shape, TableShape.round);
      expect(byId('g1').shape, TableShape.square);
      expect(byId('o1').x, 3);
      expect(byId('o1').y, 1);
    });

    test('spacers are layout only and do not become tables', () {
      expect(plan.tables.any((t) => t.id == 'sp'), isFalse);
      expect(plan.tables, hasLength(5));
    });

    test('names are unique across sections that each number from 1', () {
      expect(byId('t1').name, 'Table 1');
      expect(byId('g1').name, 'TO Go 1');
      expect(byId('o1').name, 'Officer 1');
      expect({for (final t in plan.tables) t.name}, hasLength(5));
    });

    test('a staff table keeps the employee name as its label', () {
      expect(byId('o1').displayLabel, 'Ahmed');
      expect(byId('o1').shownName, 'Ahmed');
      expect(byId('t1').displayLabel, isEmpty);
    });

    test('a table Dishflow never placed takes the next free cell', () {
      expect(byId('o2').x, 0);
      expect(byId('o2').y, 0);
      expect(plan.notes.join('\n'), contains('1 table(s) had no free grid'));
    });

    test('sections keep the order the manager arranged them in', () {
      expect(plan.sections, ['Table', 'TO Go', 'Officer']);
    });

    test('section rules map category document ids to Odoo ids', () {
      final officer =
          plan.sectionConfigs.firstWhere((c) => c.name == 'Officer');
      expect(officer.isStaffSection, isTrue);
      expect(officer.allowedCategoryIds, [11]);
      expect(officer.allowedPaymentMethodIds, [7, 9]);
      expect(officer.employeeAllowedCategories['Ahmed'], ['12']);
      expect(officer.employeeAllowedCategories['Sara'],
          [TableSectionConfig.allCategoriesSentinel]);
      expect(plan.notes.join('\n'), contains('Section "Officer"'));
    });

    test('default order type and guest count carry over per section', () {
      final toGo = plan.sectionConfigs.firstWhere((c) => c.name == 'TO Go');
      expect(toGo.defaultOrderType, OrderType.toGo);
      expect(toGo.requireGuestCount, isNull);
      final table = plan.sectionConfigs.firstWhere((c) => c.name == 'Table');
      expect(table.requireGuestCount, isTrue);
      expect(table.defaultOrderType, isNull);
    });

    test('a section whose categories all fail to match is called out', () {
      final p = DishflowFloorMapper.plan(DishflowFloorSnapshot(sections: [
        {
          'name': 'VIP',
          'allowedCategoryIds': ['unknown'],
        },
      ]));
      expect(p.sectionConfigs.single.allowedCategoryIds, isEmpty);
      expect(p.notes.join('\n'), contains('would show the whole menu'));
    });

    test('a branch id that matches nothing names the ones that do', () {
      final p = DishflowFloorMapper.plan(const DishflowFloorSnapshot(
        branchId: 'typo',
        otherBranches: {'uYL4': 'Nasr St'},
      ));
      expect(p.tables, isEmpty);
      expect(p.notes.single, contains('"typo"'));
      expect(p.notes.single, contains('uYL4 (Nasr St)'));
    });

    test('printers keep their names, and the default receipt one is marked', () {
      expect([for (final p in plan.printers) p.name],
          ['Kitchen', 'Bar', 'Cashier']);
      expect([for (final p in plan.printers) p.localRole],
          [null, null, 'receipt']);
      final bar = plan.printers.firstWhere((p) => p.name == 'Bar');
      expect(bar.host, '10.0.0.6');
      expect(bar.backup, 'Kitchen');
    });

    test('category routing follows printer ids to names', () {
      expect(plan.categoryStations[11], ['Kitchen']);
      expect(plan.categoryStations[12], ['Bar']);
      expect(plan.categoryStations[13], ['Kitchen']);
      expect(plan.notes.join('\n'), contains('no longer exists'));
    });

    test('a routed product also prints at its category printers', () {
      expect(plan.productStations[501], ['Bar', 'Kitchen']);
    });

    test('warns when nothing is called kitchen', () {
      expect(plan.notes.join('\n'), contains('No printer is named "kitchen"'));
    });

    test('without a global document, user documents are merged', () {
      final p = DishflowFloorMapper.plan(DishflowFloorSnapshot(printerDocs: [
        (
          id: 'user-1',
          fields: {
            'printers': [
              {'id': 'a', 'name': 'kitchen', 'ip_address': '10.0.0.1'},
            ],
            'settings': [
              {'category_id': 1, 'kitchen_printers': ['a']},
            ],
          },
        ),
        (
          id: 'user-2',
          fields: {
            'printers': [
              {'id': 'a', 'name': 'kitchen', 'ip_address': '10.0.0.1'},
              {'id': 'b', 'name': 'Grill', 'ip_address': '10.0.0.2'},
            ],
            'settings': [
              {'category_id': 2, 'kitchen_printers': ['b']},
            ],
          },
        ),
      ]));
      expect([for (final x in p.printers) x.name], ['kitchen', 'Grill']);
      expect(p.categoryStations, {
        1: ['kitchen'],
        2: ['Grill'],
      });
      expect(p.notes, isEmpty);
    });
  });

  group('DishflowFloorImporter', () {
    late Db db;
    late TableStore tables;
    late SettingsStore settings;
    late PrinterRegistry printers;
    late DishflowFloorImporter importer;
    late FloorImportPlan plan;

    setUp(() {
      db = Db.open(':memory:');
      tables = TableStore(db);
      settings = SettingsStore(db);
      printers = PrinterRegistry(discovery: _NoPrinters());
      importer = DishflowFloorImporter(
          tables: tables, settings: settings, printers: printers);
      plan = DishflowFloorMapper.plan(_snapshot());
    });

    tearDown(() => db.close());

    test('writes the floor, the rules, the printers and the routing', () {
      importer.apply(plan, replaceFloor: true);

      expect(tables.all(), hasLength(5));
      expect(tables.sections(), ['Table', 'TO Go', 'Officer']);
      expect(tables.byName('Officer 1')?.displayLabel, 'Ahmed');
      expect(settings.sectionConfig('Officer').isStaffSection, isTrue);
      expect(settings.sectionConfig('TO Go').defaultOrderType, OrderType.toGo);
      expect(printers['Kitchen']?.host, '10.0.0.5');
      expect(printers['Bar']?.backup, 'Kitchen');
      expect(printers['Cashier']?.host, '10.0.0.7');
      expect(printers['receipt']?.host, '10.0.0.7');
      expect(settings.categoryStations[12], ['Bar']);
      expect(settings.productStations[501], ['Bar']);
    });

    test('importing twice changes nothing the second time', () {
      importer.apply(plan, replaceFloor: true);
      final first = [for (final t in tables.all()) t.toMap().toString()];
      importer.apply(plan, replaceFloor: true);
      expect([for (final t in tables.all()) t.toMap().toString()], first);
    });

    test('replacing the floor removes tables Dishflow does not have', () {
      tables.add(name: 'Old 1', section: 'Old');
      importer.apply(plan, replaceFloor: true);
      expect(tables.byName('Old 1'), isNull);
    });

    test('keeping the floor renames an incoming table on a name clash', () {
      final mine = tables.add(name: 'Table 1', section: 'Table');
      importer.apply(plan, replaceFloor: false);
      expect(tables.byId(mine.id)?.name, 'Table 1');
      expect(tables.byId('t1')?.name, 'Table 1-2');
      expect(tables.all(), hasLength(6));
    });

    test("this till's own receipt printer is left alone once set", () {
      printers.remember('receipt', host: '192.168.1.50');
      importer.apply(plan, replaceFloor: true);
      expect(printers['receipt']?.host, '192.168.1.50');
      expect(printers['Cashier']?.host, '10.0.0.7');
    });

    test('routing set by hand for other categories survives', () {
      settings.categoryStations = {
        99: ['Grill'],
      };
      importer.apply(plan, replaceFloor: true);
      expect(settings.categoryStations[99], ['Grill']);
      expect(settings.categoryStations[11], ['Kitchen']);
    });
  });
}
