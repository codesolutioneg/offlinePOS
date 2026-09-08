import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/db/catalogue_store.dart';
import 'package:offline_pos/core/db/database.dart';
import 'package:offline_pos/domain/catalogue.dart';

import 'sqlite_loader.dart';

void main() {
  setUpAll(useSystemSqlite);

  test('expandCategoryAllowList includes children of a selected parent', () {
    final db = Db.open(':memory:');
    final cat = CatalogueStore(db);
    cat.replaceAll(
      categories: const [
        Category(id: 1, name: 'Meals'),
        Category(id: 2, name: 'Beef', parentId: 1),
        Category(id: 3, name: 'Chicken', parentId: 1),
        Category(id: 4, name: 'Drinks'),
      ],
      products: const [
        Product(id: 10, name: 'Steak', price: 100, categoryId: 2),
        Product(id: 11, name: 'Cola', price: 20, categoryId: 4),
      ],
      groups: const [],
      productGroupIds: const {},
      refreshedAt: DateTime.utc(2026, 1, 1),
    );
    expect(cat.expandCategoryAllowList([1]), {1, 2, 3});
    expect(cat.expandCategoryAllowList([4]), {4});
    expect(cat.expandCategoryAllowList(const []), isEmpty);
  });
}
