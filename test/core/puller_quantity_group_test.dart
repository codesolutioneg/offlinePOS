import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/sync/odoo_puller.dart';

/// How a "choose ten from the list" group reaches the till.
///
/// Odoo carries the count on the group as item_quantity and caps a single option
/// with max_quantity. The till reads neither from min/max, so both have to be
/// mapped here or a box of ten arrives as "take as many as you like".
void main() {
  OdooPuller pullerWith(Map<String, dynamic> groupExtra,
          {Map<String, dynamic> optionExtra = const {}}) =>
      OdooPuller(
        call: (model, method, args, kwargs) async => switch (model) {
          'product.product' => [
              {
                'id': 1,
                'display_name': 'Box',
                'lst_price': 100.0,
                'pos_categ_ids': const <int>[],
                'active': true,
                'product_tmpl_id': [90, 'Box'],
              }
            ],
          'pos.product.modifier' => [
              {
                'id': 5,
                'name': 'Pick 3',
                'sequence': 1,
                'product_tmpl_id': [90, 'Box'],
                'required': true,
                'min_selection': 0,
                'max_selection': 0,
                ...groupExtra,
              }
            ],
          'pos.modifier.option' => [
              {
                'id': 50,
                'name': 'Chicken',
                'modifier_id': [5, 'Pick 3'],
                'price_extra': 0.0,
                'sequence': 1,
                ...optionExtra,
              },
              {
                'id': 51,
                'name': 'Beef',
                'modifier_id': [5, 'Pick 3'],
                'price_extra': 0.0,
                'sequence': 2,
              },
            ],
          _ => const [],
        },
      );

  test('a quantity group is bounded by its item count, not its min/max', () async {
    final pull = await pullerWith({
      'display_type': 'quantity',
      'item_quantity': 3,
      'required': true,
    }).pull();
    final g = pull.groups.single;

    // The count is the group's whole rule: choose exactly three.
    expect(g.minSelection, 3);
    expect(g.maxSelection, 3);
  });

  test('an option carries its own ceiling', () async {
    final pull = await pullerWith(
      {'display_type': 'quantity', 'item_quantity': 3},
      optionExtra: {'max_quantity': 2},
    ).pull();
    final chicken =
        pull.groups.single.modifiers.firstWhere((m) => m.name == 'Chicken');
    expect(chicken.maxQuantity, 2);
  });

  test('an item-selection group caps at its item count, whatever it displays as',
      () async {
    // The sauce bug: the group is item-selection with a count of one and shown as
    // checkboxes, so the till let the cashier tick several. Its ceiling is the one.
    final pull = await pullerWith({
      'modifier_type': 'item_selection',
      'display_type': 'checkbox',
      'item_quantity': 1,
      'required': true,
      'max_selection': 0,
    }).pull();
    final g = pull.groups.single;

    expect(g.maxSelection, 1);
    expect(g.minSelection, 1, reason: 'a required box of one wants exactly one');
  });

  test('an optional item-selection group allows up to its count, not below',
      () async {
    final pull = await pullerWith({
      'modifier_type': 'item_selection',
      'display_type': 'checkbox',
      'item_quantity': 2,
      'required': false,
    }).pull();
    final g = pull.groups.single;
    expect(g.maxSelection, 2);
    expect(g.minSelection, 0);
  });

  test('a checkbox group is untouched by the quantity fields', () async {
    // The old shape still has to arrive the old way: a checkbox reads its own
    // min/max, and item_quantity means nothing to it.
    final pull = await pullerWith({
      'modifier_type': 'optional_addon',
      'display_type': 'checkbox',
      'min_selection': 1,
      'max_selection': 2,
      'item_quantity': 3,
    }).pull();
    final g = pull.groups.single;

    // item_quantity means nothing to a group that is not item-selection.
    expect(g.minSelection, 1);
    expect(g.maxSelection, 2);
  });
}
