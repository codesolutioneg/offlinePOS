import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/db/database.dart';
import 'package:offline_pos/core/db/settings_store.dart';
import 'package:offline_pos/core/printing/escpos.dart';
import 'package:offline_pos/core/printing/printer_discovery.dart';
import 'package:offline_pos/core/printing/printer_registry.dart';
import 'package:offline_pos/domain/catalogue.dart';
import 'package:offline_pos/features/settings/printers_screen.dart';

import '../db/sqlite_loader.dart';

/// Nothing answers a probe or a sweep. What this screen has to get right is the
/// name-in, name-out plumbing to [PrinterRegistry] and [SettingsStore]; whether a
/// sweep actually finds a printer on the wire is covered in
/// printer_registry_test.dart and printer_discovery_test.dart.
class _NoPrintersOnTheWire extends PrinterDiscovery {
  @override
  Future<bool> probe(String host, {int? port}) async => false;

  @override
  Future<List<DiscoveredPrinter>> scan({int? port, Duration? budget}) async => const [];
}

void main() {
  late Db db;
  late SettingsStore settings;
  late PrinterRegistry printers;
  final categories = const [
    Category(id: 1, name: 'Mains'),
    Category(id: 2, name: 'Drinks'),
  ];
  final products = const [
    Product(id: 10, name: 'Burger', price: 8, categoryId: 1),
    Product(id: 11, name: 'Cola', price: 2, categoryId: 2),
  ];
  int changedCount = 0;

  setUpAll(useSystemSqlite);
  setUp(() {
    db = Db.open(':memory:');
    settings = SettingsStore(db);
    printers = PrinterRegistry(discovery: _NoPrintersOnTheWire());
    changedCount = 0;
  });
  tearDown(() => db.close());

  Widget app({List<Product> withProducts = const []}) => MaterialApp(
        home: PrintersScreen(
          printers: printers,
          settings: settings,
          categories: categories,
          products: withProducts,
          onChanged: () => changedCount++,
        ),
      );

  Future<void> tall(WidgetTester t) async {
    await t.binding.setSurfaceSize(const Size(1200, 3600));
    addTearDown(() => t.binding.setSurfaceSize(null));
  }

  group('printers', () {
    testWidgets('both sections render with nothing configured yet', (t) async {
      await tall(t);
      await t.pumpWidget(app());

      expect(find.text('Printers & routing'), findsOneWidget);
      expect(find.text('Printers'), findsOneWidget);
      expect(find.text('Kitchen routing'), findsOneWidget);
      expect(find.byKey(const Key('add-printer')), findsOneWidget);
      expect(find.byKey(const Key('route-1')), findsOneWidget);
      expect(find.byKey(const Key('route-2')), findsOneWidget);
    });

    testWidgets('item routing is hidden when no products are supplied', (t) async {
      await tall(t);
      await t.pumpWidget(app());
      expect(find.text('Item routing'), findsNothing);
    });

    testWidgets('item routing appears once products are supplied', (t) async {
      await tall(t);
      await t.pumpWidget(app(withProducts: products));
      expect(find.text('Item routing'), findsOneWidget);
    });

    testWidgets('adding a printer remembers it in the registry and shows a row',
        (t) async {
      await t.pumpWidget(app());

      await t.tap(find.byKey(const Key('add-printer')));
      await t.pumpAndSettle();

      await t.enterText(find.byKey(const Key('printer-name')), 'kitchen');
      await t.enterText(find.byKey(const Key('printer-host')), '192.168.1.50');
      await t.tap(find.byKey(const Key('save-add-printer')));
      await t.pumpAndSettle();

      expect(printers['kitchen'], isNotNull);
      expect(printers['kitchen']!.host, '192.168.1.50');
      expect(find.byKey(const Key('printer-kitchen')), findsOneWidget);
      expect(changedCount, 1);
    });

    testWidgets('a name suggestion chip fills the name field', (t) async {
      await t.pumpWidget(app());

      await t.tap(find.byKey(const Key('add-printer')));
      await t.pumpAndSettle();

      await t.tap(find.byKey(const Key('suggest-printer-name-bar')));
      await t.pumpAndSettle();

      final field = t.widget<TextField>(find.byKey(const Key('printer-name')));
      expect(field.controller!.text, 'bar');
    });

    testWidgets('removing a printer forgets it from the registry', (t) async {
      printers.remember('kitchen', host: '192.168.1.50');
      await t.pumpWidget(app());
      expect(find.byKey(const Key('printer-kitchen')), findsOneWidget);

      await t.tap(find.byKey(const Key('remove-kitchen')));
      await t.pumpAndSettle();

      expect(printers['kitchen'], isNull);
      expect(find.byKey(const Key('printer-kitchen')), findsNothing);
      expect(changedCount, 1);
    });
  });

  group('editing a printer', () {
    testWidgets('opens pre-filled with the current name, host and port', (t) async {
      printers.remember('kitchen', host: '192.168.1.50', port: 9100);
      await t.pumpWidget(app());

      await t.tap(find.byKey(const Key('edit-kitchen')));
      await t.pumpAndSettle();

      expect(t.widget<TextField>(find.byKey(const Key('printer-name'))).controller!.text,
          'kitchen');
      expect(t.widget<TextField>(find.byKey(const Key('printer-host'))).controller!.text,
          '192.168.1.50');
      expect(t.widget<TextField>(find.byKey(const Key('printer-port'))).controller!.text,
          '9100');
    });

    testWidgets('saving a new host under the same name re-remembers it there', (t) async {
      printers.remember('kitchen', host: '192.168.1.50', port: 9100);
      await t.pumpWidget(app());

      await t.tap(find.byKey(const Key('edit-kitchen')));
      await t.pumpAndSettle();
      await t.enterText(find.byKey(const Key('printer-host')), '192.168.1.99');
      await t.tap(find.byKey(const Key('save-add-printer')));
      await t.pumpAndSettle();

      expect(printers['kitchen'], isNotNull);
      expect(printers['kitchen']!.host, '192.168.1.99');
      expect(changedCount, 1);
    });

    testWidgets('renaming forgets the old name and remembers the new one', (t) async {
      printers.remember('kitchen', host: '192.168.1.50', port: 9100);
      await t.pumpWidget(app());

      await t.tap(find.byKey(const Key('edit-kitchen')));
      await t.pumpAndSettle();
      await t.enterText(find.byKey(const Key('printer-name')), 'grill');
      await t.tap(find.byKey(const Key('save-add-printer')));
      await t.pumpAndSettle();

      expect(printers['kitchen'], isNull);
      expect(printers['grill'], isNotNull);
      expect(printers['grill']!.host, '192.168.1.50');
      expect(printers['grill']!.port, 9100);
      expect(find.byKey(const Key('printer-grill')), findsOneWidget);
    });
  });

  group('category routing', () {
    testWidgets('toggling a station chip on adds it to that category alone', (t) async {
      printers.remember('kitchen', host: '10.0.0.1');
      printers.remember('bar', host: '10.0.0.2');
      await tall(t);
      await t.pumpWidget(app());

      await t.tap(find.byKey(const Key('route-station-1-bar')));
      await t.pumpAndSettle();

      expect(settings.categoryStations[1], ['bar']);
      expect(settings.categoryStations.containsKey(2), isFalse);
      expect(changedCount, 1);
    });

    testWidgets('a category can be routed to more than one station at once', (t) async {
      printers.remember('kitchen', host: '10.0.0.1');
      printers.remember('bar', host: '10.0.0.2');
      await tall(t);
      await t.pumpWidget(app());

      await t.tap(find.byKey(const Key('route-station-1-kitchen')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('route-station-1-bar')));
      await t.pumpAndSettle();

      expect(settings.categoryStations[1], unorderedEquals(['kitchen', 'bar']));
      expect(changedCount, 2);
    });

    testWidgets('toggling a selected chip off removes just that station', (t) async {
      settings.setCategoryStation(1, 'kitchen', true);
      settings.setCategoryStation(1, 'bar', true);
      printers.remember('kitchen', host: '10.0.0.1');
      printers.remember('bar', host: '10.0.0.2');
      await tall(t);
      await t.pumpWidget(app());

      await t.tap(find.byKey(const Key('route-station-1-bar')));
      await t.pumpAndSettle();

      expect(settings.categoryStations[1], ['kitchen']);
      expect(changedCount, 1);
    });

    testWidgets('a stale station assignment still shows its chip', (t) async {
      settings.setCategoryStation(1, 'long-gone', true);
      await tall(t);
      await t.pumpWidget(app());

      expect(find.byKey(const Key('route-station-1-long-gone')), findsOneWidget);
    });
  });

  group('per-product routing', () {
    testWidgets('ticking a product under the picked printer overrides its category',
        (t) async {
      printers.remember('kitchen', host: '10.0.0.1');
      printers.remember('bar', host: '10.0.0.2');
      await tall(t);
      await t.pumpWidget(app(withProducts: products));

      await t.tap(find.byKey(const Key('product-station-pick-bar')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('product-route-10')));
      await t.pumpAndSettle();

      expect(settings.productStations[10], ['bar']);
      expect(changedCount, 1);
    });

    testWidgets('unticking a product removes it from that station only', (t) async {
      settings.setProductStation(10, 'bar', true);
      settings.setProductStation(10, 'kitchen', true);
      printers.remember('kitchen', host: '10.0.0.1');
      printers.remember('bar', host: '10.0.0.2');
      await tall(t);
      await t.pumpWidget(app(withProducts: products));

      await t.tap(find.byKey(const Key('product-station-pick-bar')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('product-route-10')));
      await t.pumpAndSettle();

      expect(settings.productStations[10], ['kitchen']);
    });

    testWidgets('the category filter narrows the checklist', (t) async {
      await tall(t);
      await t.pumpWidget(app(withProducts: products));

      expect(find.byKey(const Key('product-route-10')), findsOneWidget);
      expect(find.byKey(const Key('product-route-11')), findsOneWidget);

      await t.tap(find.byKey(const Key('product-category-2')));
      await t.pumpAndSettle();

      expect(find.byKey(const Key('product-route-10')), findsNothing);
      expect(find.byKey(const Key('product-route-11')), findsOneWidget);
    });

    testWidgets('the search box narrows the checklist by name', (t) async {
      await tall(t);
      await t.pumpWidget(app(withProducts: products));

      await t.enterText(find.byKey(const Key('product-search')), 'cola');
      await t.pumpAndSettle();

      expect(find.byKey(const Key('product-route-10')), findsNothing);
      expect(find.byKey(const Key('product-route-11')), findsOneWidget);
    });
  });

  group('what the printer can spell', () {
    testWidgets('the character table is stored and reaches the print profile',
        (t) async {
      await tall(t);
      await t.pumpWidget(app());

      await t.tap(find.text('Arabic'));
      await t.pumpAndSettle();

      expect(settings.receiptCodePage, 'wpc1256');
      expect(EscPosPrintProfile.shared.codePage.id, 49);
      expect(changedCount, 1);

      await t.tap(find.text('Latin'));
      await t.pumpAndSettle();
      expect(settings.receiptCodePage, 'wpc1252');
      expect(EscPosPrintProfile.shared.codePage.id, 16);
    });

    testWidgets('rendering missing letters is a switch a manager owns', (t) async {
      await tall(t);
      settings.language = 'ar';
      await t.pumpWidget(app());

      // On already for an Arabic till, so the meaningful action here is turning it
      // off, which is what a shop with an Arabic-capable printer wants.
      expect(
          t.widget<SwitchListTile>(find.byKey(const Key('arabic-raster'))).value,
          isTrue);

      await t.tap(find.byKey(const Key('arabic-raster')));
      await t.pumpAndSettle();

      expect(settings.receiptArabicRaster, isFalse);
      expect(EscPosPrintProfile.shared.rasterUnmappable, isFalse);
      expect(changedCount, 1);
    });
  });
}
