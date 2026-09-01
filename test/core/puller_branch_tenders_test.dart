import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/sync/odoo_puller.dart';
import 'package:offline_pos/core/sync/odoo_site.dart';

/// Which tenders reach the payment sheet when the shop names them per branch.
///
/// A shop that fills in `branch.pos.config` on the server has said exactly which
/// journals this branch's tills offer, and the rest of the company's journals stay
/// off the till. A shop that never installed the addon, or named nothing, keeps
/// the company-wide list it has always had.
void main() {
  final asked = <String>[];

  /// The branch company's treasuries plus a company-less journal, so the tests can
  /// tell "named" narrowing apart from the company narrowing that runs first.
  const allJournals = [
    {'id': 11, 'name': 'Cash drawer', 'type': 'cash', 'sequence': 5,
      'company_id': [3, 'Branch A']},
    {'id': 12, 'name': 'Bank CIB', 'type': 'bank', 'sequence': 10,
      'company_id': [3, 'Branch A']},
    {'id': 13, 'name': 'InstaPay', 'type': 'bank', 'sequence': 15,
      'company_id': false},
    {'id': 14, 'name': 'Bank Misr', 'type': 'bank', 'sequence': 20,
      'company_id': [4, 'Branch B']},
  ];

  OdooPuller puller({Object? config}) => OdooPuller(
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
            case 'account.journal':
              return allJournals;
            case 'branch.pos.config':
              if (config is Exception) throw config;
              return config ?? const [];
            default:
              return const [];
          }
        },
      );

  setUp(() {
    asked.clear();
    // The till sells for Branch A, whose company id is 3.
    OdooSite.shared = const OdooSite(branchId: 3);
  });
  tearDown(() => OdooSite.shared = const OdooSite());

  test('the branch names its tenders and only those show', () async {
    final pull = await puller(config: [
      {'id': 1, 'payment_journal_ids': [11]},
    ]).pull();

    expect(pull.paymentMethods.map((m) => m.name), ['Cash drawer'],
        reason: 'the shop said this branch takes cash only, so the company\'s '
            'other journals stay off the till');
  });

  test('a branch with no configuration keeps the company-wide list', () async {
    final pull = await puller().pull();

    expect(pull.paymentMethods.map((m) => m.name),
        ['Cash drawer', 'Bank CIB', 'InstaPay'],
        reason: 'naming nothing is not a refusal to take money; the company '
            'narrowing still keeps Branch B\'s journal off this till');
  });

  test('a configuration that names nothing this till can see is dropped',
      () async {
    final pull = await puller(config: [
      {'id': 1, 'payment_journal_ids': [99]},
    ]).pull();

    expect(pull.paymentMethods, isNotEmpty,
        reason: 'a till that can name no tender cannot take money, so a '
            'narrowing that would leave nothing is dropped');
  });

  test('an Odoo without the addon is asked once, not on every refresh',
      () async {
    final p = puller(
        config: Exception(
            'Object branch.pos.config doesn\'t exist in the registry'));
    await p.pull();
    await p.pull();

    expect(asked.where((m) => m == 'branch.pos.config').length, 1,
        reason: 'the missing model is remembered for the life of the puller');
  });

  test('a passing failure does not fail the refresh and is asked again',
      () async {
    final p = puller(config: Exception('Connection timed out'));
    final pull = await p.pull();

    expect(pull.paymentMethodsRead, isTrue);
    expect(pull.paymentMethods, isNotEmpty,
        reason: 'the company narrowing already keeps other branches out, so a '
            'bad moment on this read must not stop the till taking money');
    await p.pull();
    expect(asked.where((m) => m == 'branch.pos.config').length, 2,
        reason: 'a timeout says nothing about the addon, so the next refresh '
            'asks again');
  });
}
