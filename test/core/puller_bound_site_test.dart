import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/sync/odoo_puller.dart';

/// Which branch the till belongs to, answered by Odoo instead of a picker.
///
/// The shop lists its people on the branch record; a till signed into one of
/// those logins adopts that branch. Odoo staying silent, whatever the reason,
/// always means "keep what the till has".
void main() {
  OdooPuller puller({Object? branches, int? uid = 7}) => OdooPuller(
        userId: uid == null ? null : () => uid,
        call: (model, method, args, kwargs) async {
          if (model == 'branch.simple') {
            if (branches is Exception) throw branches;
            return branches ?? const [];
          }
          return const [];
        },
      );

  test('one branch names the login, so the till is bound to it', () async {
    final bound = await puller(branches: [
      {
        'id': 5, 'name': 'Cairo', 'company_id': [3, 'Cairo Co'],
        'warehouse_id': [9, 'Cairo WH'],
      },
    ]).boundSite();

    expect(bound, isNotNull);
    expect(bound!.name, 'Cairo');
    expect(bound.companyId, 3);
    expect(bound.warehouseId, 9);
  });

  test('a branch without a warehouse still binds the company', () async {
    final bound = await puller(branches: [
      {'id': 5, 'name': 'Cairo', 'company_id': [3, 'Cairo Co'],
        'warehouse_id': false},
    ]).boundSite();

    expect(bound!.companyId, 3);
    expect(bound.warehouseId, isNull);
  });

  test('a login two branches claim decides nothing', () async {
    final bound = await puller(branches: [
      {'id': 5, 'name': 'Cairo', 'company_id': [3, 'Cairo Co']},
      {'id': 6, 'name': 'Giza', 'company_id': [4, 'Giza Co']},
    ]).boundSite();

    expect(bound, isNull,
        reason: 'a floater\'s login says nothing about where this till is');
  });

  test('no branch naming the login leaves the till as it was', () async {
    expect(await puller().boundSite(), isNull);
  });

  test('an Odoo without the addon leaves the till as it was', () async {
    expect(
        await puller(
                branches: Exception(
                    "Invalid field 'user_ids' on model 'branch.simple'"))
            .boundSite(),
        isNull);
  });

  test('a till that has not authenticated asks nothing', () async {
    var asked = false;
    final p = OdooPuller(
      call: (model, method, args, kwargs) async {
        asked = true;
        return const [];
      },
    );
    expect(await p.boundSite(), isNull);
    expect(asked, isFalse, reason: 'no login, nobody to ask about');
  });
}
