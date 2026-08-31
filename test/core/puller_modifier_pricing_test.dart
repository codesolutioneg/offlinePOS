import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/sync/odoo_puller.dart';
import 'package:offline_pos/domain/catalogue.dart';

/// How Odoo's pricing of an option reaches the till.
///
/// A group says whether its options add to the dish's price or are it, and an
/// option can carry an upgrade surcharge of its own. Reading any of the three the
/// wrong way charges the customer a different number from the one on the menu, and
/// nothing about the sale looks wrong while it happens.
void main() {
  OdooPuller pullerWith({
    String priceMode = 'add',
    Map<String, dynamic>? extraOption,
  }) =>
      OdooPuller(
        call: (model, method, args, kwargs) async => switch (model) {
          'product.product' => [
              {
                'id': 1,
                'display_name': 'Coffee',
                'lst_price': 10.0,
                'pos_categ_ids': const <int>[],
                'active': true,
                'product_tmpl_id': [90, 'Coffee'],
              }
            ],
          'pos.product.modifier' => [
              {
                'id': 5,
                'name': 'Size',
                'sequence': 1,
                'product_tmpl_id': [90, 'Coffee'],
                'required': true,
                'min_selection': 1,
                'max_selection': 1,
                'display_type': 'radio',
                'price_mode': priceMode,
              }
            ],
          'pos.modifier.option' => [
              {
                'id': 50,
                'name': 'Small',
                'modifier_id': [5, 'Size'],
                'price_extra': 10.0,
                'sequence': 1,
              },
              {
                'id': 51,
                'name': 'Large',
                'modifier_id': [5, 'Size'],
                'price_extra': 20.0,
                'sequence': 2,
              },
              ?extraOption,
            ],
          _ => const [],
        },
      );

  Modifier optionNamed(List<Modifier> all, String name) =>
      all.firstWhere((m) => m.name == name);

  test('a replace group prices the dish, it does not add to it', () async {
    final pull = await pullerWith(priceMode: 'replace').pull();
    final large = optionNamed(pull.groups.single.modifiers, 'Large');

    expect(large.priceType, ModifierPriceType.replace);
    // The menu says a large coffee is 20, and the base is 10.
    expect(10 + large.priceFor(10), 20);
  });

  test('an add group still adds', () async {
    final pull = await pullerWith().pull();
    final large = optionNamed(pull.groups.single.modifiers, 'Large');
    expect(large.priceType, ModifierPriceType.fixed);
    expect(10 + large.priceFor(10), 30);
  });

  test('a group with no price mode is treated as adding', () async {
    // Which is the field's own default in Odoo, and what an older add-on that has
    // no such field means.
    final pull = await pullerWith(priceMode: '').pull();
    expect(optionNamed(pull.groups.single.modifiers, 'Large').priceType,
        ModifierPriceType.fixed);
  });

  test('a replace group takes one choice, however it is displayed', () async {
    // A dish has one price, so two of them is not something a bill can express:
    // taken twice, the option's difference from the dish applies twice and the
    // size is charged as if it were an extra, which is the arithmetic this price
    // mode exists to stop.
    final pull = await pullerWith(priceMode: 'replace').pull();
    expect(pull.groups.single.maxSelection, 1);
  });

  test('an upgrade charges its own surcharge, not the option price', () async {
    // upgrade_price is already the difference from the option the dish comes with,
    // so it is a flat addition whatever the group is set to. Read as price_extra
    // instead, a paid upgrade rings free or rings the whole size price.
    final pull = await pullerWith(
      priceMode: 'replace',
      extraOption: {
        'id': 52,
        'name': 'Extra shot',
        'modifier_id': [5, 'Size'],
        'price_extra': 0.0,
        'sequence': 3,
        'is_upgrade': true,
        'upgrade_price': 7.0,
      },
    ).pull();

    final shot = optionNamed(pull.groups.single.modifiers, 'Extra shot');
    expect(shot.priceType, ModifierPriceType.fixed,
        reason: 'a surcharge adds, even inside a group that replaces');
    expect(shot.priceFor(10), 7.0);
  });
}
