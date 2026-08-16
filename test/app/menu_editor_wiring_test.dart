import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/app/pos_app.dart';
import 'package:offline_pos/core/audit/audit_log.dart';
import 'package:offline_pos/core/auth/auth_service.dart';
import 'package:offline_pos/core/auth/user_store.dart';
import 'package:offline_pos/core/config/till_config.dart';
import 'package:offline_pos/core/db/attendance_store.dart';
import 'package:offline_pos/core/db/catalogue_store.dart';
import 'package:offline_pos/core/db/customer_store.dart';
import 'package:offline_pos/core/db/database.dart';
import 'package:offline_pos/core/db/order_store.dart';
import 'package:offline_pos/core/db/settings_store.dart';
import 'package:offline_pos/core/db/shift_store.dart';
import 'package:offline_pos/core/db/sqlite_outbox_store.dart';
import 'package:offline_pos/core/db/table_store.dart';
import 'package:offline_pos/core/onboarding/wizard_id.dart';
import 'package:offline_pos/core/onboarding/wizard_store.dart';
import 'package:offline_pos/core/printing/printer_discovery.dart';
import 'package:offline_pos/core/printing/printer_registry.dart';
import 'package:offline_pos/core/sync/odoo_endpoint.dart';
import 'package:offline_pos/core/sync/odoo_puller.dart';
import 'package:offline_pos/core/sync/odoo_wiring.dart';
import 'package:offline_pos/core/sync/outbox.dart';
import 'package:offline_pos/core/sync/sync_service.dart';
import 'package:offline_pos/domain/order.dart';
import 'package:offline_pos/features/sell/sell_screen.dart';

import '../db/sqlite_loader.dart';
import '../ui/fake_pin_hasher.dart';

class _NoPrinters extends PrinterDiscovery {
  @override
  Future<bool> probe(String host, {int? port}) async => false;

  @override
  Future<List<DiscoveredPrinter>> scan({int? port, Duration? budget}) async => const [];
}

/// The till owning its own menu, driven through the real app.
///
/// The shop owner's words were "categories and items are not from odoo, they are
/// created at the ui and can be linked to odoo items". Everything below goes through
/// the app shell rather than the store, because a store method nothing calls is not
/// a menu a manager can type.
void main() {
  late Db db;
  late OrderStore orders;
  late SettingsStore settings;
  late AuditLog audit;
  late double pulledPrice;
  late bool serverUp;

  /// Every call_kw the fake server was asked, so a test can prove what the pick
  /// list narrowed itself to rather than trusting that it did.
  late List<({String model, List<dynamic> args})> asked;

  setUpAll(useSystemSqlite);
  setUp(() async {
    db = Db.open(':memory:');
    orders = OrderStore(db);
    settings = SettingsStore(db);
    audit = AuditLog(db);
    pulledPrice = 10;
    serverUp = true;
    asked = [];
    await AuthService(users: UserStore(db), hasher: FakePinHasher(), audit: audit)
        .enrol(id: 'sara', name: 'Sara', pin: '1234', role: 'manager');
    WizardStore(db).dismiss(WizardId.firstSale, 'sara');
    // A till with no shift open refuses to sell, which would hide the grid these
    // tests are about.
    ShiftStore(db).openShift(openingFloat: 100, cashierId: 'sara');
  });
  tearDown(() => db.close());

  /// An Odoo with one point of sale that is limited to one category, and two
  /// products, only one of which is in that category.
  Future<dynamic> call(String model, String method, List<dynamic> args,
      Map<String, dynamic> kwargs) async {
    if (!serverUp) throw Exception('no route to host');
    asked.add((model: model, args: args));
    switch (model) {
      case 'pos.config':
        return [
          {'id': 7, 'limit_categories': true, 'iface_available_categ_ids': [3]}
        ];
      case 'pos.category':
        final domain = args.first as List;
        final scoped = domain.any((c) => c is List && c.first == 'id');
        return [
          {'id': 3, 'name': 'Grill', 'sequence': 0, 'parent_id': false},
          if (!scoped)
            {'id': 4, 'name': 'Other branch', 'sequence': 0, 'parent_id': false},
        ];
      case 'product.product':
        // The scope the pick list asked for, honoured the way Odoo would.
        final domain = args.first as List;
        final scope = domain.firstWhere(
            (c) => c is List && c.first == 'pos_categ_ids',
            orElse: () => null);
        return [
          {
            'id': 1,
            'display_name': 'Pizza',
            'lst_price': pulledPrice,
            'pos_categ_ids': [3],
            'active': true,
            'default_code': 'P-1',
          },
          if (scope == null)
            {
              'id': 2,
              'display_name': 'Sold at the other branch',
              'lst_price': 5,
              'pos_categ_ids': [4],
              'active': true,
            },
        ];
      default:
        return const [];
    }
  }

  Widget app() {
    final outbox = Outbox(store: SqliteOutboxStore(db), senders: const {});
    return PosApp(
      auth: AuthService(users: UserStore(db), hasher: FakePinHasher(), audit: audit),
      users: UserStore(db),
      catalogue: CatalogueStore(db),
      orders: orders,
      outbox: outbox,
      audit: audit,
      sync: SyncService(
        outbox: outbox,
        catalogue: CatalogueStore(db),
        outboxStore: SqliteOutboxStore(db),
        deviceId: 'till-1',
        appVersion: 'test',
        puller: OdooPuller(call: call),
      ),
      outboxStore: SqliteOutboxStore(db),
      printers: PrinterRegistry(discovery: _NoPrinters()),
      wizards: WizardStore(db),
      shifts: ShiftStore(db),
      deviceId: 'till-1',
      endpoints: OdooEndpointStore(db),
      // The picker reads the server through the app's own wiring, which is
      // unconfigured here, so "find in Odoo" is the offline path unless a test
      // configures an endpoint. Typing the id always works.
      odoo: OdooWiring(outbox: outbox),
      tables: TableStore(db),
      settings: settings,
      customers: CustomerStore(db),
      attendance: AttendanceStore(db),
      config: const TillConfig(),
    );
  }

  void draftOnTheTill() {
    final order = Order(deviceId: 'till-1', cashierId: 'sara')
      ..lines.add(OrderLine(productId: 1, name: 'Pizza', quantity: 1, unitPrice: 10));
    orders.save(order, announce: false);
  }

  Future<void> signIn(WidgetTester t) async {
    await t.tap(find.byKey(const Key('user-sara')));
    await t.pumpAndSettle();
    for (final d in '1234'.split('')) {
      await t.tap(find.byKey(Key('key-$d')));
      await t.pump();
    }
    await t.tap(find.byKey(const Key('pin-ok')));
    for (var i = 0; i < 20; i++) {
      await t.pump(const Duration(milliseconds: 50));
      if (find.byType(SellScreen).evaluate().isNotEmpty) break;
    }
    await t.pumpAndSettle();
  }

  void tallWindow(WidgetTester t) {
    t.view.physicalSize = const Size(1000, 2400);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
  }

  Future<void> openSettingsHub(WidgetTester t) async {
    t.state<ScaffoldState>(find
            .descendant(of: find.byType(SellScreen), matching: find.byType(Scaffold))
            .first)
        .openDrawer();
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('nav-settings')));
    await t.pumpAndSettle();
  }

  Future<void> openMenuEditor(WidgetTester t) async {
    await openSettingsHub(t);
    await t.tap(find.byKey(const Key('set-menu')));
    await t.pumpAndSettle();
  }

  /// Back out of the editor and the hub, onto the selling screen the cashier uses.
  ///
  /// Popped until the search box is on screen rather than until a [SellScreen]
  /// exists: the sell screen stays in the tree under every pushed route, so the
  /// latter would stop before anything had been popped at all.
  Future<void> backToSelling(WidgetTester t) async {
    for (var i = 0; i < 5 && find.byKey(const Key('search')).evaluate().isEmpty; i++) {
      await t.pageBack();
      await t.pumpAndSettle();
    }
    expect(find.byKey(const Key('search')), findsOneWidget);
  }

  testWidgets('a manager types an item that was never in Odoo and a cashier rings it',
      (t) async {
    tallWindow(t);
    draftOnTheTill();
    await t.pumpWidget(app());
    await signIn(t);
    await t.pumpAndSettle();

    await openMenuEditor(t);
    // A category of the shop's own first.
    await t.tap(find.byKey(const Key('tab-categories')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('menu-add-category')));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const Key('cat-name')), 'Shisha');
    await t.tap(find.byKey(const Key('cat-save')));
    await t.pumpAndSettle();
    expect(find.text('Shisha'), findsOneWidget);

    // Then the item, filed under it.
    await t.tap(find.byKey(const Key('tab-items')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('menu-add-item')));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const Key('item-name')), 'Double apple');
    await t.enterText(find.byKey(const Key('item-price')), '45');
    await t.tap(find.byKey(const Key('item-category')));
    await t.pumpAndSettle();
    await t.tap(find.text('Shisha').last);
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('item-save')));
    await t.pumpAndSettle();

    final created = CatalogueStore(db)
        .products()
        .firstWhere((p) => p.name == 'Double apple');
    expect(created.id, isNegative, reason: 'a local row must not claim an Odoo id');
    expect(created.odooId, isNull);
    expect(created.price, 45);

    // And the cashier can sell it, with no server anywhere in the path.
    await backToSelling(t);
    expect(find.byKey(Key('product-${created.id}')), findsOneWidget);
    await t.tap(find.byKey(Key('product-${created.id}')));
    await t.pumpAndSettle();
    final draft = orders.drafts().first;
    expect(draft.lines.any((l) => l.name == 'Double apple'), isTrue);
  });

  testWidgets('an unlinked item warns, and the payload says what it books against',
      (t) async {
    tallWindow(t);
    draftOnTheTill();
    await t.pumpWidget(app());
    await signIn(t);
    await t.pumpAndSettle();

    await openMenuEditor(t);
    await t.tap(find.byKey(const Key('menu-add-item')));
    await t.pumpAndSettle();
    // The warning is up before anything is typed, because unlinked is the state a
    // new item starts in.
    expect(find.byKey(const Key('item-unlinked-warning')), findsOneWidget);
    await t.enterText(find.byKey(const Key('item-name')), 'Double apple');
    await t.enterText(find.byKey(const Key('item-price')), '45');
    await t.tap(find.byKey(const Key('item-save')));
    await t.pumpAndSettle();
    await backToSelling(t);

    final created = CatalogueStore(db)
        .products()
        .firstWhere((p) => p.name == 'Double apple');
    await t.tap(find.byKey(Key('product-${created.id}')));
    await t.pumpAndSettle();

    // With no stand-in named, the local id travels: the server rejects it and the
    // till parks the sale in front of a human, which is the stated behaviour.
    LocalProductBooking.productId = null;
    var line = (orders.drafts().first.toServerPayload()['lines'] as List)
        .cast<Map<String, dynamic>>()
        .firstWhere((l) => l['name'] == 'Double apple');
    expect(line['product_id'], created.id);

    // With one named, it books against the stand-in and keeps its own name.
    LocalProductBooking.productId = 99;
    line = (orders.drafts().first.toServerPayload()['lines'] as List)
        .cast<Map<String, dynamic>>()
        .firstWhere((l) => l['name'] == 'Double apple');
    expect(line['product_id'], 99);
    expect(line['odoo_product_id'], isNull,
        reason: 'the wire carries one product id per line');
    LocalProductBooking.productId = null;
  });

  testWidgets('a linked item books against the Odoo product it was linked to',
      (t) async {
    tallWindow(t);
    draftOnTheTill();
    await t.pumpWidget(app());
    await signIn(t);
    await t.pumpAndSettle();

    await openMenuEditor(t);
    await t.tap(find.byKey(const Key('menu-add-item')));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const Key('item-name')), 'House pizza');
    await t.enterText(find.byKey(const Key('item-price')), '80');
    await t.enterText(find.byKey(const Key('item-odoo-id')), '1');
    await t.pumpAndSettle();
    expect(find.byKey(const Key('item-unlinked-warning')), findsNothing);
    await t.tap(find.byKey(const Key('item-save')));
    await t.pumpAndSettle();
    await backToSelling(t);

    final created =
        CatalogueStore(db).products().firstWhere((p) => p.name == 'House pizza');
    expect(created.odooId, 1);
    await t.tap(find.byKey(Key('product-${created.id}')));
    await t.pumpAndSettle();

    final line = (orders.drafts().first.toServerPayload()['lines'] as List)
        .cast<Map<String, dynamic>>()
        .firstWhere((l) => l['name'] == 'House pizza');
    expect(line['product_id'], 1);
  });

  testWidgets('a pull after a local edit leaves the local price alone', (t) async {
    tallWindow(t);
    draftOnTheTill();
    await t.pumpWidget(app());
    // Signing in pulls the menu, so the Odoo pizza is on the till at 10.
    await signIn(t);
    await t.pumpAndSettle();
    expect(CatalogueStore(db).byId(1)!.price, 10);

    // The manager corrects it on the device.
    await openMenuEditor(t);
    await t.tap(find.byKey(const Key('edit-item-1')));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const Key('item-price')), '12.50');
    await t.tap(find.byKey(const Key('item-save')));
    await t.pumpAndSettle();
    expect(CatalogueStore(db).byId(1)!.price, 12.5);
    await t.pageBack();
    await t.pumpAndSettle();

    // Odoo says something else, and a refresh arrives.
    pulledPrice = 30;
    await t.tap(find.byKey(const Key('set-refresh-menu')));
    await t.pumpAndSettle();

    final after = CatalogueStore(db).byId(1)!;
    expect(after.price, 12.5,
        reason: 'a pull is seeding: it must never overwrite what was edited here');
    expect(after.odooId, 1, reason: 'and the row still books against the same product');
  });

  testWidgets('a pull still seeds a shop that never opens the editor', (t) async {
    tallWindow(t);
    draftOnTheTill();
    await t.pumpWidget(app());
    await signIn(t);
    await t.pumpAndSettle();
    expect(CatalogueStore(db).byId(1)!.price, 10);

    pulledPrice = 30;
    await openSettingsHub(t);
    await t.tap(find.byKey(const Key('set-refresh-menu')));
    await t.pumpAndSettle();

    expect(CatalogueStore(db).byId(1)!.price, 30,
        reason: 'an untouched pulled row keeps tracking the server');
  });

  testWidgets('linking a local item to an Odoo product does not double it up',
      (t) async {
    tallWindow(t);
    draftOnTheTill();
    await t.pumpWidget(app());
    await signIn(t);
    await t.pumpAndSettle();

    await openMenuEditor(t);
    await t.tap(find.byKey(const Key('menu-add-item')));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const Key('item-name')), 'Our pizza');
    await t.enterText(find.byKey(const Key('item-price')), '80');
    await t.enterText(find.byKey(const Key('item-odoo-id')), '1');
    await t.tap(find.byKey(const Key('item-save')));
    await t.pumpAndSettle();
    await t.pageBack();
    await t.pumpAndSettle();

    await t.tap(find.byKey(const Key('set-refresh-menu')));
    await t.pumpAndSettle();

    final names = CatalogueStore(db).products().map((p) => p.name).toList();
    expect(names, contains('Our pizza'));
    expect(names, isNot(contains('Pizza')),
        reason: 'the local row claimed Odoo product 1, so the pull must not re-add it');
  });

  testWidgets('removing an item takes it off the grid and can be undone', (t) async {
    tallWindow(t);
    draftOnTheTill();
    await t.pumpWidget(app());
    await signIn(t);
    await t.pumpAndSettle();
    expect(find.byKey(const Key('product-1')), findsOneWidget);

    await openMenuEditor(t);
    await t.tap(find.byKey(const Key('archive-item-1')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('remove-ok')));
    await t.pumpAndSettle();
    await backToSelling(t);
    expect(find.byKey(const Key('product-1')), findsNothing);

    await openMenuEditor(t);
    await t.tap(find.byKey(const Key('menu-show-archived')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('restore-item-1')));
    await t.pumpAndSettle();
    await backToSelling(t);
    expect(find.byKey(const Key('product-1')), findsOneWidget);
  });

  testWidgets('the Odoo pick list is narrowed to this till point of sale',
      (t) async {
    // The pick list goes through the puller the same way the app does; what is
    // under test is that the restaurant id reaches the domain, and that an unset
    // one degrades to the whole catalogue rather than to nothing.
    settings.odooRestaurantId = 7;
    final puller = OdooPuller(call: call);

    final scoped = await puller.searchProducts('');
    expect(scoped.map((r) => r.name), ['Pizza'],
        reason: 'the other branch menu must not be offered here');
    expect(scoped.single.reference, 'P-1');
    expect(
        asked.any((a) =>
            a.model == 'pos.config' &&
            (a.args.first as List).any((c) => c is List && c.last == 7)),
        isTrue,
        reason: 'the narrowing has to ask about this shop point of sale');

    final categories = await puller.searchCategories('');
    expect(categories.map((r) => r.name), ['Grill']);

    settings.odooRestaurantId = null;
    final unscoped = await puller.searchProducts('');
    expect(unscoped, hasLength(2),
        reason: 'no restaurant id means no narrowing, not an empty pick list');
  });

  testWidgets('a server that will not answer leaves the manager the id box',
      (t) async {
    settings.odooRestaurantId = 7;
    serverUp = false;
    final puller = OdooPuller(call: call);
    await expectLater(puller.searchProducts(''), throwsA(isA<Exception>()),
        reason: 'the picker turns this into "type the id instead"');
  });
}
