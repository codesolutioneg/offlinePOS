import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/sync/odoo_puller.dart';

/// The two extras a menu can carry: what a dish costs the shop, and what it looks
/// like. Both are asked for on top of the menu, and neither may cost the till its
/// menu when the server will not part with it.
void main() {
  /// A one-byte PNG stand-in. The till never decodes these here; it stores what the
  /// server sent and hands it to Flutter later.
  final picture = base64Encode(const [1, 2, 3, 4]);

  /// An Odoo that answers with whatever fields it was asked for, minus the ones in
  /// [refuses], which it rejects the way a server rejects an unknown field.
  OdooPuller odoo({Set<String> refuses = const {}, bool? withImages}) => OdooPuller(
        withImages: withImages,
        call: (model, method, args, kwargs) async {
          final fields = (args[1] as List).cast<String>();
          for (final f in fields) {
            if (refuses.contains(f)) throw Exception('Invalid field $f on model');
          }
          if (model != 'product.product') return const [];
          return [
            {
              'id': 10,
              'display_name': 'Margherita',
              'lst_price': 250,
              'pos_categ_ids': [1],
              'active': true,
              'to_weight': false,
              'product_tmpl_id': [90, 'Margherita'],
              if (fields.contains('standard_price')) 'standard_price': 90.5,
              if (fields.contains('image_128')) 'image_128': picture,
            },
            {
              'id': 11,
              'display_name': 'Water',
              'lst_price': 20,
              'pos_categ_ids': [1],
              'active': true,
              'to_weight': false,
              'product_tmpl_id': [91, 'Water'],
              if (fields.contains('standard_price')) 'standard_price': 0,
              // A product with no picture, which is the common case.
              if (fields.contains('image_128')) 'image_128': false,
            },
          ];
        },
      );

  test('the cost comes down with the menu', () async {
    final pull = await odoo().pull();
    expect(pull.products.firstWhere((p) => p.id == 10).cost, 90.5);
    expect(pull.products.firstWhere((p) => p.id == 11).cost, 0);
  });

  test('a server that refuses the cost still gives up the menu', () async {
    final pull = await odoo(refuses: {'standard_price'}).pull();
    expect(pull.products, hasLength(2));
    expect(pull.products.first.cost, 0);
  });

  test('pictures are asked for only when the shop shows them', () async {
    expect((await odoo(withImages: false).pull()).productImages, isEmpty);
    final on = await odoo(withImages: true).pull();
    expect(on.productImages.keys, [10]);
    expect(on.productImages[10], [1, 2, 3, 4]);
  });

  test('the shop switch decides when nothing is injected', () async {
    CataloguePullOptions.shared = const CataloguePullOptions(images: true);
    addTearDown(() => CataloguePullOptions.shared = const CataloguePullOptions());
    expect((await odoo().pull()).productImages.keys, [10]);
  });

  test('a server with no picture field keeps the menu and the cost', () async {
    final pull = await odoo(refuses: {'image_128'}, withImages: true).pull();
    expect(pull.products, hasLength(2), reason: 'the menu must survive');
    expect(pull.products.first.cost, 90.5,
        reason: 'giving up the picture must not give up the cost');
    expect(pull.productImages, isEmpty);
  });

  test('a picture that will not decode is treated as no picture', () async {
    final pull = await OdooPuller(
      withImages: true,
      call: (model, method, args, kwargs) async => model != 'product.product'
          ? const []
          : [
              {
                'id': 10,
                'display_name': 'Margherita',
                'lst_price': 250,
                'active': true,
                'to_weight': false,
                'image_128': 'not base64 at all !!',
              },
            ],
    ).pull();
    expect(pull.products, hasLength(1));
    expect(pull.productImages, isEmpty);
  });
}
