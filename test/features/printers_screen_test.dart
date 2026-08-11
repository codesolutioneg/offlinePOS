import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/db/database.dart';
import 'package:offline_pos/core/db/settings_store.dart';
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
  int changedCount = 0;

  setUpAll(useSystemSqlite);
  setUp(() {
    db = Db.open(':memory:');
    settings = SettingsStore(db);
    printers = PrinterRegistry(discovery: _NoPrintersOnTheWire());
    changedCount = 0;
  });
  tearDown(() => db.close());

  Widget app() => MaterialApp(
        home: PrintersScreen(
          printers: printers,
          settings: settings,
          categories: categories,
          onChanged: () => changedCount++,
        ),
      );

  testWidgets('both sections render with nothing configured yet', (t) async {
    await t.pumpWidget(app());

    expect(find.text('Printers & routing'), findsOneWidget);
    expect(find.text('Printers'), findsOneWidget);
    expect(find.text('Kitchen routing'), findsOneWidget);
    expect(find.byKey(const Key('add-printer')), findsOneWidget);
    expect(find.byKey(const Key('route-1')), findsOneWidget);
    expect(find.byKey(const Key('route-2')), findsOneWidget);
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

  testWidgets('routing a category to a station persists it to the settings store',
      (t) async {
    printers.remember('kitchen', host: '192.168.1.50');
    await t.pumpWidget(app());

    // Driven directly through the callback rather than opening the overlay
    // menu: the closed selector and the printer row above it can both show
    // the text 'kitchen', which makes a tap-by-text finder ambiguous. The
    // callback is what setState and the settings write actually depend on.
    final dropdown =
        t.widget<DropdownButton<String?>>(find.byKey(const Key('route-station-1')));
    dropdown.onChanged!('kitchen');
    await t.pumpAndSettle();

    expect(settings.categoryStations[1], 'kitchen');
    expect(changedCount, 1);
  });

  testWidgets('routing a category back to auto clears the station', (t) async {
    settings.setCategoryStation(1, 'kitchen');
    await t.pumpWidget(app());

    final dropdown =
        t.widget<DropdownButton<String?>>(find.byKey(const Key('route-station-1')));
    dropdown.onChanged!(null);
    await t.pumpAndSettle();

    expect(settings.categoryStations.containsKey(1), isFalse);
    expect(changedCount, 1);
  });
}
