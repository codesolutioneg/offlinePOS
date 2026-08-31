import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/db/database.dart';
import 'package:offline_pos/core/db/settings_store.dart';
import 'package:offline_pos/core/sync/odoo_endpoint.dart';
import 'package:offline_pos/core/sync/odoo_site.dart';
import 'package:offline_pos/features/settings/server_settings_screen.dart';

import '../db/sqlite_loader.dart';

/// The branch, the point of sale and the warehouse are picked from what Odoo has,
/// because nobody knows their warehouse's database id and a guessed number books a
/// till into the wrong place without saying so.
///
/// The rule the whole screen turns on is the offline one: a till with no line keeps
/// the ids it already has, keeps them selectable, and never blanks them because a
/// list could not be fetched.
void main() {
  late Db db;
  late OdooEndpointStore endpoints;
  late SettingsStore settings;

  const fromOdoo = OdooSiteChoices(
    branches: [
      OdooSiteOption(id: 1, name: 'Downtown'),
      OdooSiteOption(id: 2, name: 'Riverside'),
    ],
    pointsOfSale: [
      OdooSiteOption(id: 7, name: 'Counter', companyId: 1),
      OdooSiteOption(id: 8, name: 'Terrace', companyId: 2),
    ],
    warehouses: [
      OdooSiteOption(id: 2, name: 'Main', companyId: 1),
      OdooSiteOption(id: 3, name: 'Cold store', companyId: 2),
    ],
  );

  setUpAll(useSystemSqlite);
  setUp(() {
    db = Db.open(':memory:');
    endpoints = OdooEndpointStore(db);
    settings = SettingsStore(db);
  });
  tearDown(() {
    OdooSite.shared = const OdooSite();
    db.close();
  });

  /// A screen tall enough that the whole form is built, so a picker near the
  /// bottom can be opened without scrolling it into a menu overlay first.
  Future<void> open(WidgetTester t,
      {Future<OdooSiteChoices> Function()? load}) async {
    await t.binding.setSurfaceSize(const Size(1000, 2400));
    addTearDown(() => t.binding.setSurfaceSize(null));
    await t.pumpWidget(MaterialApp(
      home: ServerSettingsScreen(
        store: endpoints,
        settings: settings,
        onSaved: (_) {},
        loadChoices: load,
      ),
    ));
    await t.pumpAndSettle();
  }

  Future<void> pick(WidgetTester t, String picker, String option) async {
    await t.ensureVisible(find.byKey(Key('pick-$picker')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(Key('pick-$picker')));
    await t.pumpAndSettle();
    // The chosen item is drawn in the field as well as in the open menu, so the
    // one to press is the last.
    await t.tap(find.text(option).last);
    await t.pumpAndSettle();
  }

  /// The labels a picker is currently offering, menu open.
  Future<List<String>> optionsOf(WidgetTester t, String picker) async {
    await t.ensureVisible(find.byKey(Key('pick-$picker')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(Key('pick-$picker')));
    await t.pumpAndSettle();
    final labels = t
        .widgetList<Text>(find.descendant(
            of: find.byType(ListView), matching: find.byType(Text)))
        .map((w) => w.data ?? '')
        .toList();
    await t.tapAt(const Offset(5, 5));
    await t.pumpAndSettle();
    return labels;
  }

  Future<void> save(WidgetTester t) async {
    await t.enterText(find.byKey(const Key('field-url')), 'https://shop.example.com');
    await t.enterText(find.byKey(const Key('field-db')), 'shop');
    await t.enterText(find.byKey(const Key('field-login')), 'till@example.com');
    await t.ensureVisible(find.byKey(const Key('save-server')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('save-server')));
    await t.pumpAndSettle();
  }

  testWidgets('a picker lists what Odoo returned', (t) async {
    await open(t, load: () async => fromOdoo);

    final branches = await optionsOf(t, 'branch');
    expect(branches, contains('Downtown (1)'));
    expect(branches, contains('Riverside (2)'));

    await pick(t, 'branch', 'Riverside (2)');
    await pick(t, 'warehouse', 'Cold store (3)');
    await save(t);

    expect(settings.odooBranchId, 2);
    expect(settings.odooWarehouseId, 3);
  });

  testWidgets('what Odoo returned is cached for the next time', (t) async {
    await open(t, load: () async => fromOdoo);

    expect(settings.odooSiteChoices.warehouses.map((o) => o.name),
        ['Main', 'Cold store']);
  });

  testWidgets('a cached list still names the records with the server down',
      (t) async {
    settings.odooSiteChoices = fromOdoo;
    settings.odooWarehouseId = 3;

    await open(t, load: () async => throw Exception('no route to host'));

    expect(await optionsOf(t, 'warehouse'), contains('Cold store (3)'),
        reason: 'one successful fetch is what buys a manager names on a till '
            'that cannot reach anything today');
    expect(find.byKey(const Key('choices-unavailable')), findsOneWidget);
  });

  testWidgets('an unreachable server leaves a configured id alone and selectable',
      (t) async {
    settings.odooBranchId = 4;
    settings.odooRestaurantId = 9;
    settings.odooWarehouseId = 5;

    await open(t, load: () async => throw Exception('no route to host'));

    // Nothing was fetched and nothing was cached, so each id shows as itself and
    // is still the chosen row.
    expect(await optionsOf(t, 'warehouse'), contains('5 (not in the list)'));

    await save(t);
    expect(settings.odooBranchId, 4,
        reason: 'a shop must not lose its configuration because a list could not '
            'be fetched');
    expect(settings.odooRestaurantId, 9);
    expect(settings.odooWarehouseId, 5);
  });

  testWidgets('a saved id nobody listed survives a good fetch too', (t) async {
    settings.odooWarehouseId = 99;

    await open(t, load: () async => fromOdoo);

    expect(await optionsOf(t, 'warehouse'), contains('99 (not in the list)'));
    await save(t);
    expect(settings.odooWarehouseId, 99,
        reason: 'a warehouse that moved company, or an id typed before this '
            'screen had pickers, must not be dropped on the way through');
  });

  testWidgets('the branch narrows the warehouses without hiding the saved one',
      (t) async {
    settings.odooWarehouseId = 3;
    await open(t, load: () async => fromOdoo);

    await pick(t, 'branch', 'Downtown (1)');

    final warehouses = await optionsOf(t, 'warehouse');
    expect(warehouses, contains('Main (2)'),
        reason: 'the warehouses of the chosen branch are the point of narrowing');
    expect(warehouses, contains('Cold store (3)'),
        reason: 'and the one already configured stays selectable whatever branch '
            'is chosen, or picking a branch would silently unset it');
  });

  testWidgets('a build with no way to ask still shows and keeps the ids',
      (t) async {
    settings.odooRestaurantId = 7;
    await open(t);

    expect(find.byKey(const Key('pick-restaurant')), findsOneWidget);
    await save(t);
    expect(settings.odooRestaurantId, 7);
  });

  testWidgets('one refused list does not report the other two as gone', (t) async {
    // The puller reads the three models separately and lets each fail on its own,
    // so a login that may not read stock.warehouse still gets its branches and its
    // points of sale. Saying all three are unavailable sends a manager hunting a
    // fault in two lists that are sitting right there.
    await open(t, load: () async => const OdooSiteChoices(
          branches: [OdooSiteOption(id: 1, name: 'Downtown')],
          pointsOfSale: [OdooSiteOption(id: 7, name: 'Counter')],
        ));

    expect(find.byKey(const Key('unread-warehouse')), findsOneWidget);
    expect(find.byKey(const Key('unread-branch')), findsNothing);
    expect(find.byKey(const Key('unread-restaurant')), findsNothing);
    expect(find.byKey(const Key('choices-unavailable')), findsNothing,
        reason: 'two of the three lists are right there on the screen');
  });

  testWidgets('a fetch that answered everything reports nothing unavailable',
      (t) async {
    await open(t, load: () async => fromOdoo);
    for (final picker in ['branch', 'restaurant', 'warehouse']) {
      expect(find.byKey(Key('unread-$picker')), findsNothing);
    }
    expect(find.byKey(const Key('choices-unavailable')), findsNothing);
  });

  testWidgets('all three gone is still said once, not three times', (t) async {
    await open(t, load: () async => throw Exception('no route to host'));
    expect(find.byKey(const Key('choices-unavailable')), findsOneWidget);
    for (final picker in ['branch', 'restaurant', 'warehouse']) {
      expect(find.byKey(Key('unread-$picker')), findsNothing);
    }
  });
}
