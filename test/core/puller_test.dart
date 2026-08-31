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

/// One product, and nothing said about modifiers by anybody.
List<Map<String, dynamic>> _theMenu(String model) => switch (model) {
      'product.product' => [
          {'id': 10, 'display_name': 'Margherita', 'lst_price': 250,
           'pos_categ_ids': [1], 'active': true, 'to_weight': false,
           'product_tmpl_id': [90, 'Margherita']},
        ],
      _ => const [],
    };

/// The models the shops actually run on: a group hung on a product template, with
/// its options underneath and its default named on the group.
List<Map<String, dynamic>> _posModifiers(String model) => switch (model) {
      'pos.product.modifier' => [
          {'id': 5, 'name': 'Size', 'sequence': 1,
           'product_tmpl_id': [90, 'Margherita'], 'required': true,
           'min_selection': 0, 'max_selection': 0, 'display_type': 'radio',
           'auto_add': false, 'default_option_id': [51, 'Large']},
        ],
      'pos.modifier.option' => [
          {'id': 50, 'name': 'Small', 'modifier_id': [5, 'Size'],
           'price_extra': 0, 'sequence': 1, 'product_id': false,
           'is_default': false},
          {'id': 51, 'name': 'Large', 'modifier_id': [5, 'Size'],
           'price_extra': 12, 'sequence': 2, 'product_id': [99, 'Large cup'],
           'is_default': false},
        ],
      _ => const [],
    };

void main() {
  test('the modifiers the shop really has come down and reach their product',
      () async {
    final pull = await OdooPuller(
      call: (model, method, args, kwargs) async =>
          [..._theMenu(model), ..._posModifiers(model)],
    ).pull();

    final group = pull.groups.single;
    expect(group.name, 'Size');
    expect(group.required, isTrue);
    expect(pull.productGroupIds[10], [5],
        reason: 'the group hangs on template 90, and product 10 is its variant');
    expect(pull.groupsRead, isTrue);

    final large = group.modifiers.firstWhere((m) => m.name == 'Large');
    expect(large.price, 12, reason: 'price_extra is what the option costs');
    expect(large.productId, 99);
    expect(large.isDefault, isTrue,
        reason: 'the group named it as its default, not the option itself');
    expect(group.modifiers.firstWhere((m) => m.name == 'Small').isDefault, isFalse);
  });

  test('a single-choice group cannot be answered twice', () async {
    final pull = await OdooPuller(
      call: (model, method, args, kwargs) async =>
          [..._theMenu(model), ..._posModifiers(model)],
    ).pull();
    // The server holds 0 (no ceiling) because it only enforces its own limits for
    // a checkbox. Taken at face value, a radio "Size" would let a cashier ring
    // Small and Large on the same dish.
    expect(pull.groups.single.maxSelection, 1);
    expect(pull.groups.single.isSatisfiedBy(2), isFalse);
  });

  test('the models the shop uses win over the older ones', () async {
    final pull = await OdooPuller(
      call: (model, method, args, kwargs) async => [
        ..._theMenu(model),
        ..._posModifiers(model),
        ...switch (model) {
          'product.modifier.category' => [
              {'id': 100, 'name': 'Toppings', 'sequence': 1, 'min_selection': 0,
               'max_selection': 3, 'selection_type': 'optional',
               'product_template_ids': [90]},
            ],
          'product.modifier' => [
              {'id': 1000, 'name': 'Cheese', 'category_id': [100, 'Toppings'],
               'price': 7, 'price_type': 'fixed', 'sequence': 1,
               'product_id': false},
            ],
          _ => const <Map<String, dynamic>>[],
        },
      ],
    ).pull();
    // Both add-ons are installed and both have rows. They number their groups from
    // separate sequences, so one set has to win outright rather than be merged.
    expect(pull.groups.map((g) => g.name), ['Size']);
    expect(pull.productGroupIds[10], [5]);
  });

  test('a shop on the older add-on still gets its modifiers', () async {
    // The current models answer with nothing, which is what an Odoo without that
    // add-on looks like. The till must fall back rather than show no options.
    final pull = await puller().pull();
    expect(pull.groups.single.name, 'Toppings');
    expect(pull.productGroupIds[10], [100]);
    expect(pull.groupsRead, isTrue);
  });

  test('a refused modifier read is not a shop with no modifiers', () async {
    final pull = await OdooPuller(
      call: (model, method, args, kwargs) async {
        if (model.contains('modifier')) throw Exception('Access denied');
        return _theMenu(model);
      },
    ).pull();
    expect(pull.groups, isEmpty);
    expect(pull.groupsRead, isFalse,
        reason: 'a refused read must not read as an answer of none');
    expect(pull.isUsable, isTrue, reason: 'and the menu still comes down');
  });

  test('a shop that genuinely has no modifiers says so', () async {
    final pull = await OdooPuller(
      call: (model, method, args, kwargs) async => _theMenu(model),
    ).pull();
    expect(pull.groups, isEmpty);
    expect(pull.groupsRead, isTrue);
  });

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

  test('the auto-add flags come down when the add-on has them', () async {
    final pull = await OdooPuller(
      call: (model, method, args, kwargs) async => switch (model) {
        'product.product' => [
            {'id': 10, 'display_name': 'Margherita', 'lst_price': 250,
             'pos_categ_ids': [1], 'active': true, 'to_weight': false,
             'product_tmpl_id': [90, 'Margherita']},
          ],
        'product.modifier.category' => [
            {'id': 100, 'name': 'Sauce', 'sequence': 1, 'min_selection': 1,
             'max_selection': 1, 'selection_type': 'required',
             'product_template_ids': [90], 'auto_add': true},
          ],
        'product.modifier' => [
            {'id': 1000, 'name': 'Tomato', 'category_id': [100, 'Sauce'],
             'price': 0, 'price_type': 'fixed', 'sequence': 1,
             'product_id': false, 'is_default': true},
          ],
        _ => [],
      },
    ).pull();
    final group = pull.groups.single;
    expect(group.autoAdd, isTrue);
    expect(group.modifiers.single.isDefault, isTrue);
    expect(group.resolvesItself, isTrue);
  });

  test('an add-on without the flags still gives up its modifiers', () async {
    // The old server refuses the read that asks for a field it does not have. The
    // modifiers must survive that, because a menu is worth more than a default.
    var refusedOnce = false;
    final pull = await OdooPuller(
      call: (model, method, args, kwargs) async {
        final fields = (args[1] as List).cast<String>();
        if (fields.contains('auto_add') || fields.contains('is_default')) {
          refusedOnce = true;
          throw Exception('Invalid field on model');
        }
        return switch (model) {
          'product.product' => [
              {'id': 10, 'display_name': 'Margherita', 'lst_price': 250,
               'pos_categ_ids': [1], 'active': true, 'to_weight': false,
               'product_tmpl_id': [90, 'Margherita']},
            ],
          'product.modifier.category' => [
              {'id': 100, 'name': 'Toppings', 'sequence': 1, 'min_selection': 0,
               'max_selection': 3, 'selection_type': 'optional',
               'product_template_ids': [90]},
            ],
          'product.modifier' => [
              {'id': 1000, 'name': 'Cheese', 'category_id': [100, 'Toppings'],
               'price': 7, 'price_type': 'fixed', 'sequence': 1,
               'product_id': false},
            ],
          _ => [],
        };
      },
    ).pull();
    expect(refusedOnce, isTrue);
    expect(pull.groups.single.modifiers.single.name, 'Cheese');
    expect(pull.groups.single.autoAdd, isFalse);
  });

  test('the pull names the add-on the modifiers actually came from', () async {
    // Two unrelated add-ons hold modifiers in the same database and a shop can have
    // both installed. Nothing anywhere said which one a till was reading, so a
    // support call about an option that will not appear began by guessing.
    final legacy = await puller().pull();
    expect(legacy.modifierModel, 'product.modifier.category');

    final current = await OdooPuller(
      call: (model, method, args, kwargs) async => switch (model) {
        'product.product' => [
            {'id': 10, 'display_name': 'Margherita', 'lst_price': 250,
             'pos_categ_ids': [1], 'active': true,
             'product_tmpl_id': [90, 'Margherita']},
          ],
        'pos.product.modifier' => [
            {'id': 100, 'name': 'Size', 'sequence': 1, 'product_tmpl_id': [90, 'M'],
             'required': true, 'min_selection': 1, 'max_selection': 1,
             'display_type': 'radio'},
          ],
        'pos.modifier.option' => [
            {'id': 1000, 'name': 'Large', 'modifier_id': [100, 'Size'],
             'price_extra': 20, 'sequence': 1, 'product_id': false},
          ],
        _ => const <Map<String, dynamic>>[],
      },
    ).pull();
    expect(current.modifierModel, 'pos.product.modifier');

    final none = await OdooPuller(
      call: (model, method, args, kwargs) async => const <Map<String, dynamic>>[],
    ).pull();
    expect(none.modifierModel, isNull,
        reason: 'neither pair had a row, so neither is the one in use');
  });

  test('the point of sale is read at the moment it is asked, not at build time',
      () async {
    // The puller is built once at startup and a manager can move the till to
    // another point of sale afterwards, which is why the branch is a reader. This
    // one is read the same way rather than off a static the class also holds.
    int? pointOfSale = 7;
    final asked = <Object?>[];
    final p = OdooPuller(
      restaurantId: () => pointOfSale,
      call: (model, method, args, kwargs) async {
        if (model == 'pos.config') {
          asked.add(((args.first as List).first as List).last);
          return [
            {'id': pointOfSale, 'limit_categories': false}
          ];
        }
        return const <Map<String, dynamic>>[];
      },
    );
    await p.searchProducts('');
    pointOfSale = 9;
    await p.searchProducts('');
    expect(asked, [7, 9]);
  });
}
