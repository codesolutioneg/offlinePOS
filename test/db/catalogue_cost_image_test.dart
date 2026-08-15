import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/db/catalogue_store.dart';
import 'package:offline_pos/core/db/database.dart';
import 'package:offline_pos/domain/catalogue.dart';

import 'sqlite_loader.dart';

/// The cost and the picture on disk: written by a refresh, read by the margin
/// reports and the grid, and never dragged along by the queries a sale makes.
void main() {
  late Db db;
  late CatalogueStore store;

  setUpAll(useSystemSqlite);
  setUp(() {
    db = Db.open(':memory:');
    store = CatalogueStore(db);
  });
  tearDown(() => db.close());

  final picture = Uint8List.fromList(const [9, 8, 7]);

  void seed({Map<int, Uint8List> images = const {}, DateTime? at}) => store.replaceAll(
        categories: const [Category(id: 1, name: 'Pizza')],
        products: const [
          Product(id: 10, name: 'Margherita', price: 250, categoryId: 1, cost: 90),
          Product(id: 11, name: 'Water', price: 20, categoryId: 1),
        ],
        groups: const [],
        productGroupIds: const {},
        productImages: images,
        refreshedAt: at ?? DateTime.utc(2026, 1, 1),
      );

  test('the cost survives a round trip and reaches the reports', () {
    seed();
    expect(store.byId(10)!.cost, 90);
    expect(store.products().firstWhere((p) => p.id == 11).cost, 0);
    // Only what the server actually costed: an unknown cost is absent, so a report
    // can tell it from a dish that really is free.
    expect(store.costsById(), {10: 90.0});
  });

  test('pictures are held per product and only for the ones that have one', () {
    seed(images: {10: picture});
    expect(store.images(), {10: picture});
  });

  test('a refresh through another handle is picked up rather than cached forever', () {
    seed(images: {10: picture});
    expect(store.images().keys, [10]);
    // The sync service holds its own store over the same database, which is how a
    // grid could end up drawing a picture the menu no longer has.
    CatalogueStore(db).replaceAll(
      categories: const [Category(id: 1, name: 'Pizza')],
      products: const [Product(id: 10, name: 'Margherita', price: 250)],
      groups: const [],
      productGroupIds: const {},
      refreshedAt: DateTime.utc(2026, 1, 2),
    );
    expect(store.images(), isEmpty);
  });

  test('a product with a picture still reads, searches and scans as before', () {
    store.replaceAll(
      categories: const [Category(id: 1, name: 'Pizza')],
      products: const [
        Product(id: 10, name: 'Margherita', price: 250, categoryId: 1, barcode: '111'),
      ],
      groups: const [],
      productGroupIds: const {},
      productImages: {10: Uint8List(64 * 1024)},
      refreshedAt: DateTime.utc(2026, 1, 1),
    );
    expect(store.byBarcode('111')!.name, 'Margherita');
    expect(store.products(search: 'Marg'), hasLength(1));
    expect(store.byId(10)!.price, 250);
  });
}
