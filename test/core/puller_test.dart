import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/sync/odoo_puller.dart';
import 'package:offline_pos/domain/catalogue.dart';

/// Odoo-shaped responses, including the awkward parts: many2one as [id, label],
/// `false` for unset, and groups linked to templates rather than variants.
OdooPuller puller({List<Map<String, dynamic>>? products}) => OdooPuller(
      call: (model, method, args, kwargs) async => switch (model) {
        'pos.category' => [
            {'id': 1, 'name': 'Pizza', 'sequence': 1, 'parent_id': false},
          ],
        'product.product' => products ??
            [
              {'id': 10, 'display_name': 'Margherita', 'lst_price': 250,
               'pos_categ_ids': [1], 'barcode': '111', 'active': true,
               'to_weight': false, 'product_tmpl_id': [90, 'Margherita']},
            ],
        'product.modifier.category' => [
            {'id': 100, 'name': 'Toppings', 'sequence': 1, 'min_selection': 0,
             'max_selection': 3, 'selection_type': 'optional',
             'product_template_ids': [90]},
          ],
        'product.modifier' => [
            {'id': 1000, 'name': 'Cheese', 'category_id': [100, 'Toppings'],
             'price': 7, 'price_type': 'fixed', 'sequence': 1,
             'product_id': [99, 'Cheese']},
            {'id': 1001, 'name': 'Ten Pct', 'category_id': [100, 'Toppings'],
             'price': 10, 'price_type': 'percentage', 'sequence': 2,
             'product_id': false},
          ],
        _ => [],
      },
    );

void main() {
  test('maps products, unwrapping many2one and false', () async {
    final pull = await puller().pull();
    final p = pull.products.single;
    expect(p.name, 'Margherita');
    expect(p.price, 250);
    expect(p.categoryId, 1);
    expect(p.barcode, '111');
    expect(pull.categories.single.parentId, isNull);
  });

  test('groups linked to a template reach the variant that came from it', () async {
    final pull = await puller().pull();
    // Group 100 links template 90; product 10 is that template's variant.
    expect(pull.productGroupIds[10], [100]);
  });

  test('modifier price types survive the mapping', () async {
    final pull = await puller().pull();
    final mods = pull.groups.single.modifiers;
    expect(mods.firstWhere((m) => m.name == 'Cheese').priceType,
        ModifierPriceType.fixed);
    final pct = mods.firstWhere((m) => m.name == 'Ten Pct');
    expect(pct.priceType, ModifierPriceType.percentage);
    expect(pct.priceFor(250), 25);
    // An unset product_id must not become a bogus link.
    expect(pct.productId, isNull);
  });

  test('an empty pull is not usable, so it cannot wipe a working catalogue', () async {
    final pull = await puller(products: []).pull();
    expect(pull.isUsable, isFalse);
  });
}
