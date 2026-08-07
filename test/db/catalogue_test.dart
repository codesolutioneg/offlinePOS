import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/db/catalogue_store.dart';
import 'package:offline_pos/core/db/database.dart';
import 'package:offline_pos/domain/catalogue.dart';

import 'sqlite_loader.dart';

void seed(CatalogueStore s, {DateTime? at}) => s.replaceAll(
      refreshedAt: at,
      categories: const [Category(id: 1, name: 'Pizza', sequence: 1)],
      products: const [
        Product(id: 10, name: 'Margherita', price: 250, categoryId: 1, barcode: '111'),
        Product(id: 11, name: 'Pepperoni', price: 300, categoryId: 1),
        Product(id: 12, name: 'Retired', price: 5, categoryId: 1, active: false),
      ],
      groups: const [
        ModifierGroup(id: 100, name: 'Toppings', maxSelection: 3, modifiers: [
          Modifier(id: 1000, groupId: 100, name: 'Cheese', price: 7, productId: 99),
          Modifier(id: 1001, groupId: 100, name: 'Ten Percent',
              price: 10, priceType: ModifierPriceType.percentage),
          Modifier(id: 1002, groupId: 100, name: 'Tomato',
              price: 0, priceType: ModifierPriceType.free),
        ]),
      ],
      productGroupIds: const {10: [100]},
    );

void main() {
  late Db db;
  late CatalogueStore store;
  setUpAll(useSystemSqlite);
  setUp(() {
    db = Db.open(':memory:');
    store = CatalogueStore(db);
  });
  tearDown(() => db.close());

  test('a fresh till has no catalogue and says so', () {
    expect(store.isEmpty, isTrue);
    expect(store.refreshedAt, isNull);
  });

  test('the catalogue persists and is readable with no network', () {
    seed(store);
    expect(store.isEmpty, isFalse);
    expect(store.categories().single.name, 'Pizza');
    expect(store.products().map((p) => p.name), ['Margherita', 'Pepperoni']);
  });

  test('inactive products are not sellable', () {
    seed(store);
    expect(store.products().any((p) => p.name == 'Retired'), isFalse);
  });

  test('barcode scan resolves locally', () {
    seed(store);
    expect(store.byBarcode('111')!.id, 10);
    expect(store.byBarcode('nope'), isNull);
  });

  test('search matches name or exact barcode', () {
    seed(store);
    expect(store.products(search: 'pepp').single.name, 'Pepperoni');
    expect(store.products(search: '111').single.name, 'Margherita');
  });

  test('modifier groups resolve for a product without a round trip', () {
    seed(store);
    final groups = store.modifierGroupsFor(10);
    expect(groups.single.name, 'Toppings');
    expect(groups.single.modifiers.map((m) => m.name),
        ['Cheese', 'Ten Percent', 'Tomato']);
    expect(store.hasModifiers(10), isTrue);
    expect(store.hasModifiers(11), isFalse);
  });

  test('a percentage modifier is a share of the parent, not a flat amount', () {
    seed(store);
    final mods = store.modifierGroupsFor(10).single.modifiers;
    final pct = mods.firstWhere((m) => m.name == 'Ten Percent');
    expect(pct.priceFor(250), 25);
    final fixed = mods.firstWhere((m) => m.name == 'Cheese');
    expect(fixed.priceFor(250), 7);
    final free = mods.firstWhere((m) => m.name == 'Tomato');
    expect(free.priceFor(250), 0);
  });

  test('a refresh replaces rather than accumulates', () {
    seed(store);
    seed(store);
    expect(store.products().length, 2);
    expect(store.modifierGroupsFor(10).single.modifiers.length, 3);
  });

  test('a failed refresh leaves the previous catalogue intact', () {
    seed(store);
    // A duplicate product id inside one batch violates the primary key.
    expect(
      () => store.replaceAll(
        categories: const [],
        products: const [
          Product(id: 5, name: 'A', price: 1),
          Product(id: 5, name: 'B', price: 1),
        ],
        groups: const [],
        productGroupIds: const {},
      ),
      throwsA(anything),
    );
    // Still sellable from what it had.
    expect(store.products().length, 2);
    expect(store.byBarcode('111'), isNotNull);
  });

  test('staleness is reported so the till can warn instead of pretending', () {
    final at = DateTime.utc(2026, 1, 1);
    seed(store, at: at);
    expect(store.refreshedAt, at);
    expect(store.stalenessAt(at.add(const Duration(days: 3)))!.inDays, 3);
  });

  test('group selection rules are enforced on the device', () {
    const optional = ModifierGroup(id: 1, name: 'g', maxSelection: 2);
    expect(optional.isSatisfiedBy(0), isTrue);
    expect(optional.isSatisfiedBy(2), isTrue);
    expect(optional.isSatisfiedBy(3), isFalse);

    const mandatory = ModifierGroup(id: 2, name: 'g', required: true, maxSelection: 1);
    expect(mandatory.isSatisfiedBy(0), isFalse);
    expect(mandatory.isSatisfiedBy(1), isTrue);

    const unlimited = ModifierGroup(id: 3, name: 'g');
    expect(unlimited.isSatisfiedBy(99), isTrue);
  });
}
