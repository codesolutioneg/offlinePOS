import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/sync/odoo_puller.dart';
import 'package:offline_pos/core/sync/odoo_site.dart';

/// Which tenders reach the payment sheet.
///
/// The shop asked to be paid from the account journals of type bank and cash, which
/// is what its other till has always done. So the tender list is journals: the ones
/// the till's Odoo user is allowed to take money on when the shop named any, and
/// every bank and cash journal of the branch's company when it did not.
void main() {
  final asked = <String>[];

  /// A company's treasuries, plus one journal that is not money over the counter and
  /// one belonging to another branch.
  const allJournals = [
    {'id': 11, 'name': 'Cash drawer', 'type': 'cash', 'sequence': 5,
      'company_id': [3, 'Branch A']},
    {'id': 12, 'name': 'Bank CIB', 'type': 'bank', 'sequence': 10,
      'company_id': [3, 'Branch A']},
    {'id': 13, 'name': 'InstaPay', 'type': 'bank', 'sequence': 10,
      'company_id': false},
    {'id': 14, 'name': 'Bank Misr', 'type': 'bank', 'sequence': 20,
      'company_id': [4, 'Branch B']},
  ];

  OdooPuller puller({Object? journals, Object? user, int? userId}) => OdooPuller(
        userId: userId == null ? null : () => userId,
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
              if (journals is Exception) throw journals;
              return journals ?? allJournals;
            case 'res.users':
              if (user is Exception) throw user;
              return user ?? const [];
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

  test('the journals are the tenders', () async {
    final pull = await puller().pull();

    expect(pull.paymentMethodsRead, isTrue);
    expect(pull.paymentMethods.map((m) => m.name),
        ['Cash drawer', 'Bank CIB', 'InstaPay', 'Bank Misr'],
        reason: 'in sequence then name, which is the order the other till in the '
            'same shop shows them in');
    expect(asked, contains('account.journal'));
    expect(asked, isNot(contains('pos.payment.method')),
        reason: 'a journal the shop never mirrored as a point-of-sale method is '
            'still money it takes, and asking about the mirror is what used to '
            'leave those journals unsellable');
  });

  test('a journal carries what it is and where it books', () async {
    final pull = await puller().pull();
    final cash = pull.paymentMethods.singleWhere((m) => m.name == 'Cash drawer');
    final card = pull.paymentMethods.singleWhere((m) => m.name == 'Bank CIB');

    expect(cash.isCash, isTrue, reason: 'a cash journal is the drawer, and the '
        'shift count and the drawer kick both read that');
    expect(card.isCash, isFalse);
    expect(card.journalId, 12);
    expect(card.journalName, 'Bank CIB');
    expect(card.journalType, 'bank');
    expect(card.isJournal, isTrue);
    expect(card.id, -12,
        reason: 'the sign is what keeps a journal and a point-of-sale method that '
            'share a number from being read as one another');
    expect(card.isPayLater, isFalse);
  });

  test('the user narrows the list when the shop named any journals', () async {
    final pull = await puller(
      userId: 7,
      user: const [
        {'id': 7, 'payment_method_ids': [11, 13]}
      ],
    ).pull();

    expect(pull.paymentMethods.map((m) => m.name), ['Cash drawer', 'InstaPay']);
  });

  test('a user with no journals named is allowed all of them', () async {
    final pull = await puller(
      userId: 7,
      user: const [
        {'id': 7, 'payment_method_ids': <int>[]}
      ],
    ).pull();

    expect(pull.paymentMethods, hasLength(4),
        reason: "the field's own help says an empty list means show all methods, "
            'so it widens rather than narrows');
  });

  test('a user whose journals are all elsewhere is not left unable to sell',
      () async {
    final pull = await puller(
      userId: 7,
      user: const [
        {'id': 7, 'payment_method_ids': [99]}
      ],
    ).pull();

    expect(pull.paymentMethods, hasLength(4),
        reason: 'a narrowing that leaves nothing is dropped, because a till that '
            'can name no tender cannot take money');
  });

  test('an Odoo that will not answer for the user narrows nothing', () async {
    final pull =
        await puller(userId: 7, user: Exception('Access denied')).pull();

    expect(pull.paymentMethodsRead, isTrue);
    expect(pull.paymentMethods, hasLength(4));
  });

  test("the branch's company narrows it, and an unscoped journal survives",
      () async {
    OdooSite.shared = const OdooSite(branchId: 3);
    final pull = await puller().pull();

    expect(pull.paymentMethods.map((m) => m.name),
        ['Cash drawer', 'Bank CIB', 'InstaPay'],
        reason: 'another branch keeps its own treasuries, and a journal that '
            'names no company is unknown rather than disqualified');
  });

  test('a company that matches no journal at all leaves the list alone', () async {
    OdooSite.shared = const OdooSite(branchId: 99);
    final pull = await puller(journals: const [
      {'id': 11, 'name': 'Cash drawer', 'type': 'cash', 'company_id': [3, 'A']},
      {'id': 14, 'name': 'Bank Misr', 'type': 'bank', 'company_id': [4, 'B']},
    ]).pull();

    expect(pull.paymentMethods, hasLength(2),
        reason: 'offering one tender too many beats a till that can name none');
  });

  test('a refused journal read is not a shop with no tenders', () async {
    final pull = await puller(journals: Exception('Access denied')).pull();

    expect(pull.isUsable, isTrue);
    expect(pull.paymentMethods, isEmpty);
    expect(pull.paymentMethodsRead, isFalse,
        reason: 'the caller keeps the tenders the till already had, and only an '
            'answered question may replace them');
  });
}
