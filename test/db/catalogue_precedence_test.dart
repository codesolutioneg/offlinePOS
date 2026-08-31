import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/db/catalogue_store.dart';
import 'package:offline_pos/core/db/database.dart';
import 'package:offline_pos/core/db/sqlite_outbox_store.dart';
import 'package:offline_pos/core/sync/odoo_puller.dart';
import 'package:offline_pos/core/sync/outbox.dart';
import 'package:offline_pos/core/sync/sync_service.dart';
import 'package:offline_pos/domain/catalogue.dart';

import 'sqlite_loader.dart';

/// Who wins when a pull meets a menu somebody typed here.
///
/// The rule is one word: `source`. A pull may create, replace and remove the rows it
/// owns and must never touch the rows the till owns. The app-level proof that a
/// manager's edit survives a refresh lives in test/app/menu_editor_wiring_test.dart;
/// these are the edges that are cheaper to state directly against the store.
void main() {
  late Db db;
  late CatalogueStore store;

  setUpAll(useSystemSqlite);
  setUp(() {
    db = Db.open(':memory:');
    store = CatalogueStore(db);
  });
  tearDown(() => db.close());

  /// One product and one category, as a pull leaves them.
  void pull({
    List<Product> products = const [Product(id: 1, name: 'Pizza', price: 10)],
    List<Category> categories = const [Category(id: 3, name: 'Grill')],
    List<ModifierGroup> groups = const [],
    Map<int, List<int>> productGroupIds = const {},
  }) =>
      store.replaceAll(
        categories: categories,
        products: products,
        groups: groups,
        productGroupIds: productGroupIds,
      );

  test('a pull seeds a till nobody has edited', () {
    pull();
    expect(store.byId(1)!.price, 10);
    expect(store.byId(1)!.source, CatalogueSource.odoo);
    expect(store.byId(1)!.odooId, 1, reason: 'a pulled row books against itself');

    pull(products: const [Product(id: 1, name: 'Pizza', price: 30)]);
    expect(store.byId(1)!.price, 30);
  });

  test('a pull removes a pulled row the server stopped sending', () {
    pull(products: const [
      Product(id: 1, name: 'Pizza', price: 10),
      Product(id: 2, name: 'Gone tomorrow', price: 5),
    ]);
    expect(store.products(), hasLength(2));

    pull();
    expect(store.products().map((p) => p.id), [1]);
  });

  test('a pull never removes a row typed on the till', () {
    final mine = store.addProduct(name: 'Double apple', price: 45);
    pull();
    expect(store.byId(mine.id), isNotNull);
    expect(store.byId(mine.id)!.source, CatalogueSource.local);
  });

  test('editing a pulled row claims it, and the next pull leaves it alone', () {
    pull();
    store.saveProduct(store.byId(1)!.copyWith(price: 12.5));
    expect(store.byId(1)!.source, CatalogueSource.local);

    pull(products: const [Product(id: 1, name: 'Pizza', price: 30)]);
    expect(store.byId(1)!.price, 12.5);
    expect(store.byId(1)!.odooId, 1, reason: 'it still books against the same product');
  });

  test('a claimed Odoo product does not come back as a second row', () {
    pull();
    // The manager decides the shop's own row is the real one and links it.
    final mine = store.addProduct(name: 'Our pizza', price: 80, odooId: 1);
    // Which leaves the pulled row behind; removing it is the manager's next move.
    store.archiveProduct(1);

    pull(products: const [Product(id: 1, name: 'Pizza', price: 30)]);

    expect(store.products().map((p) => p.id), [mine.id]);
  });

  test('clearing the link on an edited pulled row does not break the next pull', () {
    pull();
    // Edited here, then unlinked: the row keeps sitting on id 1 with no claim on
    // Odoo product 1, which is exactly the collision a plain insert would hit.
    store.saveProduct(store.byId(1)!.copyWith(price: 12.5, odooId: null));

    pull(products: const [Product(id: 1, name: 'Pizza', price: 30)]);

    expect(store.byId(1)!.price, 12.5);
    expect(store.byId(1)!.odooId, isNull);
    expect(store.products(), hasLength(1), reason: 'and nothing was duplicated');
  });

  test('a category typed here survives, and an archived one leaves the strip', () {
    pull();
    final mine = store.addCategory(name: 'Shisha');
    store.archiveCategory(3);

    pull();

    expect(store.categories().map((c) => c.name), ['Shisha']);
    expect(store.categories(includeArchived: true).map((c) => c.name),
        containsAll(['Shisha', 'Grill']));
    expect(store.categoryById(mine.id)!.source, CatalogueSource.local);
  });

  test('a modifier group typed here survives a pull that carries none', () {
    pull();
    final group = store.addModifierGroup(
        productId: 1, name: 'Extras', maxSelection: 0);
    store.addModifier(groupId: group.id, name: 'Cheese', price: 5);

    pull();

    final after = store.modifierGroupsFor(1);
    expect(after.single.name, 'Extras',
        reason: 'the link to a product the server owns is the till\'s, not the server\'s');
    expect(after.single.modifiers.single.name, 'Cheese');
    expect(after.single.source, CatalogueSource.local);
  });

  test('a pulled modifier group is still replaced by the pull', () {
    const group = ModifierGroup(
      id: 100,
      name: 'Sauce',
      maxSelection: 1,
      modifiers: [Modifier(id: 1000, groupId: 100, name: 'Tomato', price: 0)],
    );
    pull(groups: const [group], productGroupIds: const {
      1: [100]
    });
    expect(store.modifierGroupsFor(1).single.name, 'Sauce');

    pull();
    expect(store.modifierGroupsFor(1), isEmpty);
  });

  /// The test above states the store's rule: what a pull carries is what the till
  /// holds. It cannot say anything about the case that matters, because it hands
  /// the store an empty pull directly and a store cannot tell a shop with no
  /// modifiers from a server that refused to say. That distinction is made one
  /// level up, so it is proved there: through a real refresh against a server that
  /// answers about the menu and not about the modifiers.
  ///
  /// Which is the failure that shipped: the refused read arrived as no groups, and
  /// every refresh deleted the options the shop was selling with.
  SyncService syncAgainst({required bool modifiersReadable}) {
    final outbox = Outbox(store: SqliteOutboxStore(db), senders: {});
    return SyncService(
      outbox: outbox,
      catalogue: store,
      outboxStore: SqliteOutboxStore(db),
      deviceId: 'till-1',
      appVersion: 'test',
      puller: OdooPuller(
        call: (model, method, args, kwargs) async {
          // What an integration user without the Point of Sale group looks like:
          // the menu comes down, the modifier models do not.
          if (model.contains('modifier')) {
            if (!modifiersReadable) throw Exception('Access denied');
            return const [];
          }
          return switch (model) {
            'product.product' => [
                {'id': 1, 'display_name': 'Pizza', 'lst_price': 10,
                 'pos_categ_ids': const <int>[], 'active': true,
                 'to_weight': false, 'product_tmpl_id': [90, 'Pizza']},
              ],
            _ => const [],
          };
        },
      ),
    );
  }

  void aGroupOnTheTill() {
    pull(groups: const [
      ModifierGroup(
        id: 100,
        name: 'Sauce',
        maxSelection: 1,
        modifiers: [Modifier(id: 1000, groupId: 100, name: 'Tomato', price: 0)],
      )
    ], productGroupIds: const {
      1: [100]
    });
    expect(store.modifierGroupsFor(1), hasLength(1));
  }

  test('a refresh whose modifier read is refused keeps the groups the till had',
      () async {
    aGroupOnTheTill();
    final sync = syncAgainst(modifiersReadable: false);

    await sync.refresh(force: true);

    final after = store.modifierGroupsFor(1).single;
    expect(after.name, 'Sauce',
        reason: 'the server said nothing about modifiers, so nothing about them '
            'changed on the till');
    expect(after.modifiers.single.name, 'Tomato');
    expect(sync.modifiersUnavailable, isTrue,
        reason: 'and support can see why the shop\'s new options never arrived');
  });

  test('a refresh of a shop that genuinely has no modifiers clears them',
      () async {
    aGroupOnTheTill();
    final sync = syncAgainst(modifiersReadable: true);

    await sync.refresh(force: true);

    expect(store.modifierGroupsFor(1), isEmpty,
        reason: 'an answered question is a licence to remove what it no longer '
            'names');
    expect(sync.modifiersUnavailable, isFalse);
  });

  test('the grid marks come from one read and say whether a group must be answered',
      () {
    pull(products: const [
      Product(id: 1, name: 'Pizza', price: 10),
      Product(id: 2, name: 'Water', price: 5),
    ]);
    final optional =
        store.addModifierGroup(productId: 1, name: 'Extras', maxSelection: 0);
    store.addModifier(groupId: optional.id, name: 'Cheese', price: 5);

    var marks = store.modifierMarks();
    expect(marks[2], isNull, reason: 'an item with no choices carries no mark');
    expect(marks[1]!.groups, 1);
    expect(marks[1]!.required, isFalse);

    store.addModifierGroup(
        productId: 1, name: 'Size', minSelection: 1, maxSelection: 1, required: true);
    marks = store.modifierMarks();
    expect(marks[1]!.groups, 2);
    expect(marks[1]!.required, isTrue);
  });

  test('ids created here are negative, so they can never be an Odoo id', () {
    final first = store.addProduct(name: 'A', price: 1);
    final second = store.addProduct(name: 'B', price: 1);
    expect(first.id, -1);
    expect(second.id, -2);
    expect(store.addCategory(name: 'C').id, -1);
  });
}
