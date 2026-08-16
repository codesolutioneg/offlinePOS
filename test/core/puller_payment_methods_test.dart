import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/sync/odoo_puller.dart';
import 'package:offline_pos/core/sync/odoo_site.dart';

/// Where the tender list on the payment sheet comes from, and what happens on the
/// two occasions it does not arrive: a server that refuses the question, and a shop
/// whose point of sale only runs some of the company's methods.
void main() {
  final asked = <String>[];

  OdooPuller puller({
    Object? methods,
    List<Map<String, dynamic>>? configs,
  }) =>
      OdooPuller(
        call: (model, method, args, kwargs) async {
          asked.add(model);
          switch (model) {
            case 'pos.category':
              return [
                {'id': 1, 'name': 'Pizza', 'sequence': 1, 'parent_id': false}
              ];
            case 'product.product':
              return [
                {
                  'id': 10, 'display_name': 'Margherita', 'lst_price': 250,
                  'pos_categ_ids': [1], 'active': true, 'to_weight': false,
                  'product_tmpl_id': [90, 'Margherita'],
                }
              ];
            case 'pos.payment.method':
              if (methods is Exception) throw methods;
              return methods ??
                  [
                    {'id': 1, 'name': 'Cash', 'is_cash_count': true},
                    {'id': 2, 'name': 'Card', 'is_cash_count': false},
                    {'id': 3, 'name': 'Another branch card', 'is_cash_count': false},
                  ];
            case 'pos.config':
              return configs ?? const [];
            default:
              return const [];
          }
        },
      );

  setUp(() {
    asked.clear();
    OdooSite.shared = const OdooSite();
  });
  tearDown(() => OdooSite.shared = const OdooSite());

  test('methods the server gave are the ones the till offers', () async {
    final pull = await puller().pull();
    expect(pull.paymentMethodsRead, isTrue);
    expect(pull.paymentMethods.map((m) => m.name),
        ['Cash', 'Card', 'Another branch card']);
    expect(pull.paymentMethods.first.isCash, isTrue);
  });

  test('a refused tender read is not the same as a shop with no tenders',
      () async {
    final pull = await puller(methods: Exception('Access denied')).pull();
    // The menu still lands: losing the whole catalogue over a tender read would be
    // a bad trade.
    expect(pull.isUsable, isTrue);
    expect(pull.paymentMethods, isEmpty);
    expect(pull.paymentMethodsRead, isFalse,
        reason: 'the caller must be able to tell "refused" from "none", or a '
            'refusal wipes the tenders the till was already selling with');
  });

  test('a named point of sale is only offered its own methods', () async {
    OdooSite.shared = const OdooSite(restaurantId: 7);
    final pull = await puller(configs: [
      {'id': 7, 'payment_method_ids': [1, 2]}
    ]).pull();
    expect(pull.paymentMethods.map((m) => m.id), [1, 2],
        reason: 'a method that is not on this point of sale books as cash server '
            'side, so offering it would put a tender in the mix Odoo never sees');
    expect(asked, contains('pos.config'));
  });

  test('an unnamed point of sale asks nothing and keeps every method', () async {
    final pull = await puller().pull();
    expect(pull.paymentMethods, hasLength(3));
    expect(asked, isNot(contains('pos.config')));
  });

  test('a point of sale with no method of its own leaves the list alone',
      () async {
    OdooSite.shared = const OdooSite(restaurantId: 7);
    final pull = await puller(configs: [
      {'id': 7, 'payment_method_ids': false}
    ]).pull();
    expect(pull.paymentMethods, hasLength(3),
        reason: 'filtering to nothing would leave the till unable to name a tender');
  });
}
