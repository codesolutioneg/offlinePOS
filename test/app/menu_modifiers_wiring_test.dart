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
import 'package:offline_pos/core/sync/odoo_wiring.dart';
import 'package:offline_pos/core/sync/outbox.dart';
import 'package:offline_pos/core/sync/sync_service.dart';
import 'package:offline_pos/domain/catalogue.dart';
import 'package:offline_pos/domain/order.dart';
import 'package:offline_pos/features/sell/modifier_sheet.dart';
import 'package:offline_pos/features/sell/sell_screen.dart';

import '../db/sqlite_loader.dart';
import '../ui/fake_pin_hasher.dart';

class _NoPrinters extends PrinterDiscovery {
  @override
  Future<bool> probe(String host, {int? port}) async => false;

  @override
  Future<List<DiscoveredPrinter>> scan({int? port, Duration? budget}) async => const [];
}

/// The shop owner's second note: "modifiers are not there I cannot choose them
/// while doing order! I don't know which item has modifier, need some symbol on the
/// item to find out".
///
/// Three things have to hold at once for that to be answered: a manager can create
/// the choices on the device, the grid marks the items that carry them, and the
/// cashier is actually asked. All three are driven through the app here.
void main() {
  late Db db;
  late OrderStore orders;
  late SettingsStore settings;
  late AuditLog audit;

  setUpAll(useSystemSqlite);
  setUp(() async {
    db = Db.open(':memory:');
    orders = OrderStore(db);
    settings = SettingsStore(db);
    audit = AuditLog(db);
    await AuthService(users: UserStore(db), hasher: FakePinHasher(), audit: audit)
        .enrol(id: 'sara', name: 'Sara', pin: '1234', role: 'manager');
    WizardStore(db).dismiss(WizardId.firstSale, 'sara');
    ShiftStore(db).openShift(openingFloat: 100, cashierId: 'sara');
  });
  tearDown(() => db.close());

  /// A menu already on the till, as a pull would have left it.
  void seed({List<ModifierGroup> groups = const []}) {
    CatalogueStore(db).replaceAll(
      categories: const [Category(id: 1, name: 'Pizza')],
      products: const [Product(id: 10, name: 'Margherita', price: 100, categoryId: 1)],
      groups: groups,
      productGroupIds: {10: groups.map((g) => g.id).toList()},
      refreshedAt: DateTime.now().toUtc(),
    );
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
        // No puller: nothing here needs a server, which is the point.
      ),
      outboxStore: SqliteOutboxStore(db),
      printers: PrinterRegistry(discovery: _NoPrinters()),
      wizards: WizardStore(db),
      shifts: ShiftStore(db),
      deviceId: 'till-1',
      endpoints: OdooEndpointStore(db),
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
      ..lines.add(OrderLine(
          productId: 10, name: 'Margherita', quantity: 1, unitPrice: 100));
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

  Future<void> openMenuEditor(WidgetTester t) async {
    t.state<ScaffoldState>(find
            .descendant(of: find.byType(SellScreen), matching: find.byType(Scaffold))
            .first)
        .openDrawer();
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('nav-settings')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('set-menu')));
    await t.pumpAndSettle();
  }

  Future<void> backToSelling(WidgetTester t) async {
    for (var i = 0; i < 5 && find.byKey(const Key('search')).evaluate().isEmpty; i++) {
      await t.pageBack();
      await t.pumpAndSettle();
    }
    expect(find.byKey(const Key('search')), findsOneWidget);
  }

  testWidgets(
      'a manager adds choices on the device, the grid marks the item, and the cashier is asked',
      (t) async {
    tallWindow(t);
    seed();
    draftOnTheTill();
    await t.pumpWidget(app());
    await signIn(t);
    await t.pumpAndSettle();

    // Nothing to choose yet, so nothing on the tile: the mark has to mean something.
    expect(find.byKey(const Key('product-mods-10')), findsNothing);

    await openMenuEditor(t);
    await t.tap(find.byKey(const Key('edit-item-10')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('add-mod-group')));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const Key('mod-group-name')), 'Size');
    await t.enterText(find.byKey(const Key('mod-group-min')), '1');
    await t.enterText(find.byKey(const Key('mod-group-max')), '1');
    await t.tap(find.byKey(const Key('mod-group-required')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('mod-group-save')));
    await t.pumpAndSettle();

    final group = CatalogueStore(db).modifierGroupsFor(10).single;
    expect(group.name, 'Size');
    expect(group.required, isTrue);
    expect(group.source, CatalogueSource.local);

    await t.tap(find.byKey(Key('add-mod-option-${group.id}')));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const Key('mod-option-name')), 'Large');
    await t.enterText(find.byKey(const Key('mod-option-price')), '20');
    await t.tap(find.byKey(const Key('mod-option-save')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(Key('add-mod-option-${group.id}')));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const Key('mod-option-name')), 'Small');
    await t.tap(find.byKey(const Key('mod-option-save')));
    await t.pumpAndSettle();

    await t.tap(find.byKey(const Key('item-save')));
    await t.pumpAndSettle();
    await backToSelling(t);

    // The symbol the owner asked for, on the tile, before anybody taps anything.
    expect(find.byKey(const Key('product-mods-10')), findsOneWidget);

    // And the cashier is asked.
    await t.tap(find.byKey(const Key('product-10')));
    await t.pumpAndSettle();
    expect(find.byType(ModifierSheet), findsOneWidget);
    final large = CatalogueStore(db)
        .modifierGroupsFor(10)
        .single
        .modifiers
        .firstWhere((m) => m.name == 'Large');
    await t.tap(find.byKey(Key('mod-${large.id}')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('confirm-modifiers')));
    await t.pumpAndSettle();

    final line = orders.drafts().first.lines
        .firstWhere((l) => l.modifiers.isNotEmpty);
    expect(line.modifiers.single.name, 'Large');
    expect(line.modifiers.single.unitPrice, 20);
  });

  testWidgets('a brand new item gets its choices without leaving the editor',
      (t) async {
    tallWindow(t);
    seed();
    draftOnTheTill();
    await t.pumpWidget(app());
    await signIn(t);
    await t.pumpAndSettle();

    await openMenuEditor(t);
    await t.tap(find.byKey(const Key('menu-add-item')));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const Key('item-name')), 'Shawarma');
    await t.enterText(find.byKey(const Key('item-price')), '60');
    // A group needs a row to hang off, so the editor saves the item in place
    // rather than sending the manager away and back.
    await t.tap(find.byKey(const Key('mods-need-save')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('add-mod-group')));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const Key('mod-group-name')), 'Bread');
    await t.tap(find.byKey(const Key('mod-group-save')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('item-save')));
    await t.pumpAndSettle();
    await backToSelling(t);

    final created =
        CatalogueStore(db).products().firstWhere((p) => p.name == 'Shawarma');
    expect(CatalogueStore(db).modifierGroupsFor(created.id).single.name, 'Bread');
    expect(find.byKey(Key('product-mods-${created.id}')), findsOneWidget);
  });

  testWidgets('an item with no choices still rings straight through', (t) async {
    tallWindow(t);
    seed();
    draftOnTheTill();
    await t.pumpWidget(app());
    await signIn(t);
    await t.pumpAndSettle();

    await t.tap(find.byKey(const Key('product-10')));
    await t.pumpAndSettle();

    expect(find.byType(ModifierSheet), findsNothing);
    expect(orders.drafts().first.lines.first.name, 'Margherita');
  });

  testWidgets('an auto-add group with room left in it still opens the sheet',
      (t) async {
    tallWindow(t);
    // The bug: "Extras" is marked auto-add and has one default, so the old rule
    // counted it answered and rang the item through. The cashier could not add the
    // second topping and had nothing on screen telling them why.
    seed(groups: const [
      ModifierGroup(
        id: 100,
        name: 'Extras',
        autoAdd: true,
        modifiers: [
          Modifier(id: 1000, groupId: 100, name: 'Cheese', price: 5, isDefault: true),
          Modifier(id: 1001, groupId: 100, name: 'Olives', price: 5),
        ],
      ),
    ]);
    draftOnTheTill();
    await t.pumpWidget(app());
    await signIn(t);
    await t.pumpAndSettle();

    // Optional choices are marked too, in the quieter colour.
    expect(find.byKey(const Key('product-mods-10')), findsOneWidget);

    await t.tap(find.byKey(const Key('product-10')));
    await t.pumpAndSettle();

    expect(find.byType(ModifierSheet), findsOneWidget,
        reason: 'a group with an option left to take must never settle itself');
    await t.tap(find.byKey(const Key('mod-1001')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('confirm-modifiers')));
    await t.pumpAndSettle();

    final line =
        orders.drafts().first.lines.firstWhere((l) => l.modifiers.isNotEmpty);
    expect(line.modifiers.single.name, 'Olives');
  });

  testWidgets('a group the shop has genuinely answered is still not asked about',
      (t) async {
    tallWindow(t);
    // One standard sauce, one slot, and the shop said auto-add. There is nothing a
    // sheet could change, so it must not appear: that was the point of the flag.
    seed(groups: const [
      ModifierGroup(
        id: 100,
        name: 'Sauce',
        required: true,
        minSelection: 1,
        maxSelection: 1,
        autoAdd: true,
        modifiers: [
          Modifier(id: 1000, groupId: 100, name: 'Tomato', price: 0, isDefault: true),
        ],
      ),
    ]);
    draftOnTheTill();
    await t.pumpWidget(app());
    await signIn(t);
    await t.pumpAndSettle();

    await t.tap(find.byKey(const Key('product-10')));
    await t.pumpAndSettle();

    expect(find.byType(ModifierSheet), findsNothing);
    final line =
        orders.drafts().first.lines.firstWhere((l) => l.modifiers.isNotEmpty);
    expect(line.modifiers.single.name, 'Tomato');
  });

  testWidgets('choices typed on the till survive a catalogue refresh', (t) async {
    tallWindow(t);
    seed();
    draftOnTheTill();
    await t.pumpWidget(app());
    await signIn(t);
    await t.pumpAndSettle();

    await openMenuEditor(t);
    await t.tap(find.byKey(const Key('edit-item-10')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('add-mod-group')));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const Key('mod-group-name')), 'Extras');
    await t.enterText(find.byKey(const Key('mod-group-max')), '0');
    await t.tap(find.byKey(const Key('mod-group-save')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('item-save')));
    await t.pumpAndSettle();
    await backToSelling(t);

    // A pull arrives, carrying no modifiers at all, as an Odoo without the add-on
    // would. The group the shop typed here is not the server's to remove, and nor
    // is the link that attaches it to a product the server does own.
    seed();

    final groups = CatalogueStore(db).modifierGroupsFor(10);
    expect(groups.single.name, 'Extras');
    expect(groups.single.source, CatalogueSource.local);
  });
}
