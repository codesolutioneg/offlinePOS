import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/sync/odoo_puller.dart';
import 'package:offline_pos/core/sync/odoo_site.dart';

/// What fills the three pickers on the server screen.
///
/// Nobody knows their warehouse's database id, so the till asks Odoo for the
/// names. Standard models through the same call_kw the catalogue uses, and nothing
/// new on the server.
void main() {
  final asked = <String>[];

  OdooPuller puller({
    Object? companies,
    Object? configs,
    Object? warehouses,
  }) =>
      OdooPuller(
        call: (model, method, args, kwargs) async {
          asked.add(model);
          switch (model) {
            case 'res.company':
              if (companies is Exception) throw companies;
              return companies ??
                  [
                    {'id': 1, 'name': 'Downtown'},
                    {'id': 2, 'name': 'Riverside'},
                  ];
            case 'pos.config':
              if (configs is Exception) throw configs;
              return configs ??
                  [
                    {'id': 7, 'name': 'Counter', 'company_id': [1, 'Downtown']},
                    {'id': 8, 'name': 'Terrace', 'company_id': [2, 'Riverside']},
                  ];
            case 'stock.warehouse':
              if (warehouses is Exception) throw warehouses;
              return warehouses ??
                  [
                    {'id': 2, 'name': 'Main', 'company_id': [1, 'Downtown']},
                  ];
            default:
              return const [];
          }
        },
      );

  setUp(asked.clear);

  test('the three lists come back with their names', () async {
    final choices = await puller().siteChoices();
    expect(choices.branches.map((o) => o.name), ['Downtown', 'Riverside']);
    expect(choices.pointsOfSale.map((o) => o.id), [7, 8]);
    expect(choices.warehouses.single.name, 'Main');
    expect(asked, containsAll(['res.company', 'pos.config', 'stock.warehouse']));
  });

  test('a point of sale and a warehouse say which branch they belong to',
      () async {
    final choices = await puller().siteChoices();
    expect(choices.pointsOfSale.first.companyId, 1);
    expect(choices.warehouses.single.companyId, 1);
    // With no branch addon the branch picker lists companies, each its own
    // company, so picking one names the company the sales are booked to.
    expect(choices.branches.first.isCompany, isTrue);
    expect(choices.branches.first.companyId, choices.branches.first.id);
  });

  test('a model this login cannot read costs only its own picker', () async {
    final choices =
        await puller(warehouses: Exception('Access denied')).siteChoices();
    expect(choices.warehouses, isEmpty);
    expect(choices.branches, hasLength(2),
        reason: 'half a set of names is more use to a manager than none');
    expect(choices.pointsOfSale, hasLength(2));
  });

  test('a server that answers nothing at all gives empty lists', () async {
    final choices = await puller(
      companies: Exception('down'),
      configs: Exception('down'),
      warehouses: Exception('down'),
    ).siteChoices();
    expect(choices.isEmpty, isTrue,
        reason: 'the screen reads this as "could not be loaded" and leaves every '
            'saved id exactly where it was');
  });

  group('the discount product a point of sale already has', () {
    OdooPuller withDiscount({
      required Object? configField,
      List<int> taxes = const [],
      bool productsFail = false,
    }) =>
        OdooPuller(
          call: (model, method, args, kwargs) async {
            switch (model) {
              case 'pos.config':
                return [
                  {
                    'id': 7,
                    'name': 'Counter',
                    'company_id': [1, 'Downtown'],
                    'discount_product_id': configField,
                  },
                ];
              case 'product.product':
                if (productsFail) throw Exception('no access');
                return [
                  {'id': 55, 'taxes_id': taxes},
                ];
              default:
                return const [];
            }
          },
        );

    test('is offered when it carries no tax', () async {
      final choices =
          await withDiscount(configField: [55, 'Discount']).siteChoices();
      expect(choices.pointsOfSale.single.discountProductId, 55);
    });

    test('is left out when it is taxed, since its line would cut the tax',
        () async {
      final choices = await withDiscount(
          configField: [55, 'Discount'], taxes: [3]).siteChoices();
      expect(choices.pointsOfSale.single.discountProductId, isNull);
      expect(choices.pointsOfSale.single.name, 'Counter');
    });

    test('is left out when the product could not be checked', () async {
      final choices = await withDiscount(
          configField: [55, 'Discount'], productsFail: true).siteChoices();
      expect(choices.pointsOfSale.single.discountProductId, isNull);
    });

    test('is simply absent on a point of sale that names none', () async {
      final choices = await withDiscount(configField: false).siteChoices();
      expect(choices.pointsOfSale.single.discountProductId, isNull);
    });

    test('survives the cache round trip', () {
      const o = OdooSiteOption(id: 7, name: 'Counter', discountProductId: 55);
      expect(OdooSiteOption.fromMap(o.toMap()).discountProductId, 55);
    });
  });
}
