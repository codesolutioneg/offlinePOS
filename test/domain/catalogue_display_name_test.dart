import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/domain/catalogue.dart';

void main() {
  test('stripCatalogueCodePrefix drops a leading [CODE]', () {
    expect(stripCatalogueCodePrefix('[961(K)] Mini Burger'), 'Mini Burger');
    expect(stripCatalogueCodePrefix('[962(K)] Mini Cheese Burger'),
        'Mini Cheese Burger');
    expect(stripCatalogueCodePrefix('Plain name'), 'Plain name');
    expect(stripCatalogueCodePrefix('[only-code]'), '[only-code]');
  });

  test('Product.displayName uses the stripped form', () {
    const p = Product(
      id: 1,
      name: '[961(K)] Mini Burger',
      price: 10,
    );
    expect(p.displayName, 'Mini Burger');
  });
}
