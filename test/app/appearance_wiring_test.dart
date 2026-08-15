import 'dart:typed_data';

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
import 'package:offline_pos/core/theme/table_palette.dart';
import 'package:offline_pos/domain/catalogue.dart';
import 'package:offline_pos/features/sell/sell_screen.dart';
import 'package:offline_pos/features/settings/appearance_settings_screen.dart';
import 'package:offline_pos/features/tables/table_floor_screen.dart';

import '../db/sqlite_loader.dart';
import '../ui/fake_pin_hasher.dart';

class _NoPrinters extends PrinterDiscovery {
  @override
  Future<bool> probe(String host, {int? port}) async => false;

  @override
  Future<List<DiscoveredPrinter>> scan({int? port, Duration? budget}) async => const [];
}

/// A one-pixel PNG, so a tile has something real to decode.
final _png = Uint8List.fromList(const [
  0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d,
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1f, 0x15, 0xc4, 0x89, 0x00, 0x00, 0x00,
  0x0a, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9c, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0d, 0x0a, 0x2d, 0xb4, 0x00, 0x00, 0x00, 0x00, 0x49,
  0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82,
]);

/// How the till looks, as the shop actually gets it: chosen in settings on a real
/// app shell and read back off the screens a cashier stands in front of.
///
/// A theme nothing applies and a picture the grid never asks for both pass every
/// unit test there is, so each of these drives the shell.
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
    TableStore(db).add(name: '5', seats: 4);
  });
  tearDown(() => db.close());

  void seedMenu({Map<int, Uint8List> images = const {}}) => CatalogueStore(db).replaceAll(
        categories: const [Category(id: 1, name: 'Pizza'), Category(id: 2, name: 'Drinks')],
        products: const [
          Product(id: 10, name: 'Margherita', price: 250, categoryId: 1),
          Product(id: 11, name: 'Water', price: 20, categoryId: 2),
        ],
        groups: const [],
        productGroupIds: const {},
        productImages: images,
        refreshedAt: DateTime.now().toUtc(),
      );

  Widget app() {
    final outbox = Outbox(store: SqliteOutboxStore(db), senders: {});
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

  Future<void> boot(WidgetTester t) async {
    await t.binding.setSurfaceSize(const Size(1280, 1600));
    addTearDown(() => t.binding.setSurfaceSize(null));
    await t.pumpWidget(app());
    await t.tap(find.byKey(const Key('user-sara')));
    await t.pump();
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
    if (find.byType(TableFloorScreen).evaluate().isNotEmpty) {
      await t.pageBack();
      await t.pumpAndSettle();
    }
  }

  Future<void> openAppearance(WidgetTester t) async {
    await t.tap(find.byType(DrawerButton));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('nav-settings')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('set-appearance')));
    await t.pumpAndSettle();
    expect(find.byType(AppearanceSettingsScreen), findsOneWidget);
  }

  /// Settings are two routes deep (hub, then the screen), so getting back to where
  /// a cashier stands means popping both.
  Future<void> backToSell(WidgetTester t) async {
    await t.pageBack();
    await t.pumpAndSettle();
    await t.pageBack();
    await t.pumpAndSettle();
    expect(find.byType(SellScreen), findsOneWidget);
  }

  Future<void> openFloor(WidgetTester t) async {
    await t.tap(find.byType(DrawerButton));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('nav-tables')));
    await t.pumpAndSettle();
    expect(find.byType(TableFloorScreen), findsOneWidget);
  }

  /// The brightness the sell screen is actually being drawn in, which is the only
  /// answer that proves the theme reached anything.
  Brightness brightnessOnScreen(WidgetTester t) =>
      Theme.of(t.element(find.byType(SellScreen))).brightness;

  group('dark mode', () {
    testWidgets('a till set to dark comes up dark', (t) async {
      settings.themeMode = 'dark';
      seedMenu();

      await boot(t);

      expect(brightnessOnScreen(t), Brightness.dark,
          reason: 'the shell must hand MaterialApp the stored mode');
    });

    testWidgets('switching it in settings darkens the till without a restart',
        (t) async {
      seedMenu();
      await boot(t);
      expect(brightnessOnScreen(t), Brightness.light);

      await openAppearance(t);
      await t.tap(find.byKey(const Key('theme-dark')));
      await t.pumpAndSettle();
      await backToSell(t);

      expect(settings.themeMode, 'dark');
      expect(brightnessOnScreen(t), Brightness.dark,
          reason: 'the toggle must rebuild the shell, not just write a row');
    });
  });

  group('pictures on the grid', () {
    testWidgets('the switch off leaves every tile as it was', (t) async {
      seedMenu(images: {10: _png});

      await boot(t);

      expect(find.byKey(const Key('product-10')), findsOneWidget);
      expect(find.byKey(const Key('product-image-10')), findsNothing,
          reason: 'a shop that did not ask for pictures must not get them');
    });

    testWidgets('the switch on draws the picture on the tile that has one',
        (t) async {
      settings.showProductImages = true;
      seedMenu(images: {10: _png});

      await boot(t);

      expect(find.byKey(const Key('product-image-10')), findsOneWidget,
          reason: 'the shell must read the pictures, or the toggle is dead');
      // A product with no picture keeps the coloured tile it has today.
      expect(find.byKey(const Key('product-image-11')), findsNothing);
      expect(find.byKey(const Key('product-11')), findsOneWidget);
    });

    testWidgets('turning it on in settings puts pictures on the grid at once',
        (t) async {
      seedMenu(images: {10: _png});
      await boot(t);
      expect(find.byKey(const Key('product-image-10')), findsNothing);

      await openAppearance(t);
      await t.tap(find.byKey(const Key('t-product-images')));
      await t.pumpAndSettle();
      await backToSell(t);

      expect(settings.showProductImages, isTrue);
      expect(find.byKey(const Key('product-image-10')), findsOneWidget);
    });

    testWidgets('a tile with a picture is still the button that rings it up',
        (t) async {
      settings.showProductImages = true;
      seedMenu(images: {10: _png});

      await boot(t);
      await t.tap(find.byKey(const Key('product-10')));
      await t.pumpAndSettle();

      expect(find.text('Margherita'), findsWidgets);
      expect(find.textContaining('250'), findsWidgets);
    });
  });

  group('category chips', () {
    testWidgets('a chip carries its category colour and still filters the grid',
        (t) async {
      settings.setCategoryColor(2, Colors.purple.toARGB32());
      seedMenu();

      await boot(t);
      final chip = t.widget<ChoiceChip>(find.byKey(const Key('cat-chip-2')));
      expect(chip.side, isNotNull, reason: 'the chip must wear the shop colour');

      await t.tap(find.byKey(const Key('cat-chip-2')));
      await t.pumpAndSettle();

      expect(find.byKey(const Key('product-11')), findsOneWidget);
      expect(find.byKey(const Key('product-10')), findsNothing);
      expect(
          t.widget<ChoiceChip>(find.byKey(const Key('cat-chip-2'))).selectedColor,
          isNotNull);
    });
  });

  group('table colours', () {
    testWidgets('the floor is drawn in the colours the shop picked', (t) async {
      settings.setTableColor(free: Colors.indigo.toARGB32());
      seedMenu();

      await boot(t);
      await openFloor(t);

      final painted = t
          .widgetList<Container>(find.descendant(
              of: find.byType(TableFloorScreen), matching: find.byType(Container)))
          .map((c) => c.decoration)
          .whereType<BoxDecoration>()
          .where((d) => d.border != null)
          .toList();
      expect(
          painted.any((d) =>
              (d.border as Border?)?.top.color.toARGB32() ==
              Colors.indigo.toARGB32()),
          isTrue,
          reason: 'the floor must read the shop palette, or the setting is dead');
    });

    testWidgets('picking a colour in settings repaints the floor', (t) async {
      seedMenu();
      await boot(t);

      await openAppearance(t);
      await t.tap(find.byKey(const Key('table-colour-occupied')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(Key('swatch-${Colors.indigo.toARGB32()}')));
      await t.pumpAndSettle();

      expect(settings.tableColorOccupied, Colors.indigo.toARGB32());
      // Published on the spot rather than at the next start-up, which is what the
      // floor reads when it draws.
      expect(TablePalette.shared.occupied.toARGB32(), Colors.indigo.toARGB32());
      await backToSell(t);
      await openFloor(t);
    });
  });
}
