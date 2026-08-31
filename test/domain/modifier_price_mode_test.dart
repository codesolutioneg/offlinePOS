import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/domain/catalogue.dart';

/// What an option actually charges.
///
/// Odoo lets a group say its options replace the dish's price rather than add to
/// it, which is how sizes are priced: a small coffee is 10 and a large one is 20,
/// not 30. Reading that as an addition overcharges every large coffee the shop
/// sells, and nothing on the receipt looks wrong while it happens.
void main() {
  Modifier option(double price, ModifierPriceType type) => Modifier(
        id: 1,
        groupId: 1,
        name: 'Large',
        price: price,
        priceType: type,
      );

  test('an option that replaces the price brings the line to that price', () {
    // The menu says a large coffee is 20. The dish is 10.
    final large = option(20, ModifierPriceType.replace);
    expect(large.priceFor(10), 10, reason: 'it adds the difference');
    expect(10 + large.priceFor(10), 20, reason: 'so the line is what the menu says');
  });

  test('the same option read as an addition is the bug', () {
    final wrong = option(20, ModifierPriceType.fixed);
    expect(10 + wrong.priceFor(10), 30);
  });

  test('a replacing option on a dearer dish takes money off', () {
    // A shop that prices a size below the dish it hangs on is unusual, but the
    // arithmetic has to hold rather than clamp at zero and quietly overcharge.
    final small = option(8, ModifierPriceType.replace);
    expect(12 + small.priceFor(12), 8);
  });

  test('the other three ways of pricing are unchanged', () {
    expect(option(5, ModifierPriceType.fixed).priceFor(10), 5);
    expect(option(10, ModifierPriceType.percentage).priceFor(50), 5);
    expect(option(99, ModifierPriceType.free).priceFor(10), 0);
  });
}
