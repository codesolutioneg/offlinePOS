import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/sync/odoo_puller.dart';

/// Which menu a till pulls when the chain sells different things in different
/// branches.
///
/// A product names the branches that sell it and an empty list means all of them,
/// so a shop that has never heard of branches keeps the menu it had. The till adds
/// its own branch to the question; nothing new exists on the server for it to ask.
void main() {
  late List<List<dynamic>> domains;

  OdooPuller puller({int? branch, bool branchFieldExists = true}) {
    domains = [];
    return OdooPuller(
      branchId: branch == null ? null : () => branch,
      call: (model, method, args, kwargs) async {
        if (model == 'product.product') {
          final domain = (args.first as List).cast<dynamic>();
          domains.add(domain);
          final mentionsBranches =
              domain.any((c) => c is List && '${c.first}'.contains('branch_ids'));
          // An Odoo without the field answers the question with an error, which is
          // the case the fallback exists for.
          if (mentionsBranches && !branchFieldExists) {
            throw Exception('Invalid field product.template.branch_ids');
          }
          return [
            {
              'id': 1,
              'display_name': 'French coffee',
              'lst_price': 40.0,
              'pos_categ_ids': const <int>[],
              'active': true,
              'product_tmpl_id': [11, 'French coffee'],
            }
          ];
        }
        // Everything else the pull asks for is beside the point here.
        return const [];
      },
    );
  }

  bool mentionsBranch(List<dynamic> domain) =>
      domain.any((c) => c is List && '${c.first}'.contains('branch_ids'));

  test('a till with no branch asks for the whole menu', () async {
    await puller().pull();
    expect(domains, hasLength(1));
    expect(mentionsBranch(domains.single), isFalse,
        reason: 'a single-shop till has no branch to filter by and never had one');
  });

  test('a till in a branch asks for that branch and the unrestricted products',
      () async {
    await puller(branch: 3).pull();
    final domain = domains.single;
    expect(mentionsBranch(domain), isTrue);
    // Empty means every branch, so those have to come too or installing branches
    // would empty the menu of every product nobody has ticked yet.
    expect(domain, contains('|'));
    expect(
        domain.any((c) =>
            c is List && '${c.first}'.contains('branch_ids') && c.last == false),
        isTrue);
    expect(
        domain.any((c) =>
            c is List &&
            '${c.first}'.contains('branch_ids') &&
            c.last is List &&
            (c.last as List).contains(3)),
        isTrue);
  });

  test('an Odoo without the branches field still gets a menu', () async {
    // The alternative is a till that shows nothing and cannot trade, which is far
    // worse than one showing a few dishes another branch also sells.
    final p = puller(branch: 3, branchFieldExists: false);
    final pull = await p.pull();
    expect(pull.products, hasLength(1));
    expect(mentionsBranch(domains.first), isTrue, reason: 'it did try');
    expect(mentionsBranch(domains.last), isFalse, reason: 'then asked for the lot');

    // And it does not go on asking. The read it falls out of probes every optional
    // field before giving up, so repeating that each refresh would spend a handful
    // of failing calls to learn the same thing.
    final asksOnFirstPull = domains.length;
    await p.pull();
    expect(domains.length - asksOnFirstPull, 1);
    expect(mentionsBranch(domains.last), isFalse);
  });

  test('a bad minute does not put the till back on the whole menu', () async {
    // A timeout is not Odoo saying the field is missing. Latching on one would
    // quietly hand a chain's till the whole chain's menu until someone restarted
    // it, on the strength of one failed refresh.
    var failNext = true;
    domains = [];
    final p = OdooPuller(
      branchId: () => 3,
      call: (model, method, args, kwargs) async {
        if (model != 'product.product') return const [];
        final domain = (args.first as List).cast<dynamic>();
        domains.add(domain);
        if (failNext && mentionsBranch(domain)) {
          throw Exception('SocketException: connection timed out');
        }
        return const [];
      },
    );

    // The failed pull gives up rather than falling back to the whole menu: a
    // stale correct menu beats a fresh wrong one, and the catalogue is only
    // replaced by a pull that finished.
    await expectLater(p.pull(), throwsA(isA<Exception>()));
    expect(domains.every(mentionsBranch), isTrue,
        reason: 'it never asked for the whole chain menu');

    failNext = false;
    domains = [];
    await p.pull();
    expect(mentionsBranch(domains.first), isTrue,
        reason: 'it asks for its own branch again on the next refresh');
  });

  test('the branch is read at the moment of the pull, not at startup', () async {
    // A manager can move a till to another branch, and the puller is built once.
    var branch = 3;
    final p = OdooPuller(
      branchId: () => branch,
      call: (model, method, args, kwargs) async {
        if (model == 'product.product') domains.add((args.first as List).cast());
        return const [];
      },
    );
    domains = [];
    await p.pull();
    branch = 4;
    await p.pull();

    List<dynamic> branchClause(List<dynamic> d) => d.firstWhere((c) =>
        c is List && '${c.first}'.contains('branch_ids') && c.last is List);
    expect((branchClause(domains.first).last as List).single, 3);
    expect((branchClause(domains.last).last as List).single, 4,
        reason: 'the next refresh is the new menu, not the next restart');
  });
}
