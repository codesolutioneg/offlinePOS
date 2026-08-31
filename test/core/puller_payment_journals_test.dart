import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/sync/odoo_puller.dart';
import 'package:offline_pos/core/sync/odoo_site.dart';

/// Which tenders reach the payment sheet once the journal behind each one is
/// known.
///
/// The shop asked for the methods whose journal is a bank or a cash journal. The
/// narrowing happens here and only here: what the till puts on the wire is still a
/// `pos.payment.method` id, because that is the model the booking side resolves,
/// and sending it a journal id would book every card sale into the cash drawer.
void main() {
  final asked = <String>[];

  /// The company's methods, one per journal type Odoo can give a shop, plus the
  /// pay-later tender that has no journal at all.
  const allMethods = [
    {'id': 1, 'name': 'Cash', 'is_cash_count': true, 'journal_id': [11, 'Cash']},
    {'id': 2, 'name': 'Card', 'is_cash_count': false, 'journal_id': [12, 'Bank']},
    {'id': 3, 'name': 'Voucher', 'is_cash_count': false, 'journal_id': [13, 'Misc']},
    {'id': 4, 'name': 'Customer account', 'is_cash_count': false, 'journal_id': false},
  ];

  const allJournals = [
    {'id': 11, 'name': 'Cash drawer', 'type': 'cash'},
    {'id': 12, 'name': 'Bank CIB', 'type': 'bank'},
    {'id': 13, 'name': 'Miscellaneous', 'type': 'general'},
  ];

  OdooPuller puller({Object? methods, Object? journals}) => OdooPuller(
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
              return methods ?? allMethods;
            case 'account.journal':
              if (journals is Exception) throw journals;
              return journals ?? allJournals;
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

  test('only the bank and cash backed methods are offered', () async {
    final pull = await puller().pull();
    expect(pull.paymentMethods.map((m) => m.name),
        ['Cash', 'Card', 'Customer account'],
        reason: 'a voucher booking to a miscellaneous journal is not money over '
            'the counter, so offering it puts a tender on the sheet the shop '
            'cannot reconcile');
    expect(asked, contains('account.journal'));
  });

  test('a method with no journal is kept, as pay later', () async {
    final pull = await puller().pull();
    final onAccount =
        pull.paymentMethods.singleWhere((m) => m.name == 'Customer account');
    expect(onAccount.isPayLater, isTrue);
    expect(onAccount.journalId, isNull);
    expect(onAccount.isBankOrCash, isFalse,
        reason: 'nothing is banked when the customer settles later, and the '
            'module treats it as an on-account tender rather than a drawer');
  });

  test('the journal a tender books to comes down with it', () async {
    final pull = await puller().pull();
    final card = pull.paymentMethods.singleWhere((m) => m.name == 'Card');
    expect(card.journalId, 12);
    expect(card.journalName, 'Bank CIB');
    expect(card.journalType, 'bank');
    expect(card.isBankOrCash, isTrue);
    // Still the pos.payment.method id, which is the one the wire carries.
    expect(card.id, 2);
  });

  test('a refused journal read narrows nothing', () async {
    final pull =
        await puller(journals: Exception('Access denied')).pull();
    expect(pull.paymentMethodsRead, isTrue);
    expect(pull.paymentMethods.map((m) => m.id), [1, 2, 3, 4],
        reason: 'a server that will not answer the journal question must not '
            'cost the till the tenders it was already selling with');
    expect(pull.paymentMethods.first.journalType, isNull);
  });

  test('a refused tender read is still not a shop with no tenders', () async {
    final pull = await puller(methods: Exception('Access denied')).pull();
    expect(pull.isUsable, isTrue);
    expect(pull.paymentMethods, isEmpty);
    expect(pull.paymentMethodsRead, isFalse);
  });

  test('narrowing to nothing leaves the list alone', () async {
    final pull = await puller(methods: [
      {'id': 3, 'name': 'Voucher', 'is_cash_count': false, 'journal_id': [13, 'Misc']}
    ]).pull();
    expect(pull.paymentMethods, hasLength(1),
        reason: 'a till that can name no tender at all cannot take money, so an '
            'empty narrowing is dropped the way the point-of-sale one is');
  });

  test('the point of sale is narrowed before the journals are', () async {
    OdooSite.shared = const OdooSite(restaurantId: 7);
    final puller = OdooPuller(
      call: (model, method, args, kwargs) async {
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
            return allMethods;
          case 'pos.config':
            return [
              {'id': 7, 'payment_method_ids': [1, 3]}
            ];
          case 'account.journal':
            return allJournals;
          default:
            return const [];
        }
      },
    );
    final pull = await puller.pull();
    expect(pull.paymentMethods.map((m) => m.id), [1],
        reason: 'this point of sale runs cash and a voucher; the voucher goes to '
            'a miscellaneous journal, so only the cash tender survives both');
  });
}
