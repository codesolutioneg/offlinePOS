import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/sync/odoo_puller.dart';

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
    // A company does not belong to a company, so nothing is claimed about one.
    expect(choices.branches.first.companyId, isNull);
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
}
