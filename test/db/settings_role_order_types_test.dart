import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/db/database.dart';
import 'package:offline_pos/core/db/settings_store.dart';
import 'package:offline_pos/domain/order.dart';

import 'sqlite_loader.dart';

void main() {
  late Db db;
  late SettingsStore settings;

  setUpAll(useSystemSqlite);
  setUp(() {
    db = Db.open(':memory:');
    settings = SettingsStore(db);
  });
  tearDown(() => db.close());

  test('every role rings everything until a manager says otherwise', () {
    expect(settings.orderTypesFor('cashier'), OrderType.values.toSet());
    expect(settings.orderTypesFor('waiter'), OrderType.values.toSet());
    expect(settings.roleCanRing('cashier', OrderType.delivery), isTrue);
  });

  test('a manager is never restricted', () {
    settings.setRoleOrderType('manager', OrderType.dineIn, false);
    expect(settings.orderTypesFor('manager'), OrderType.values.toSet());
  });

  test('a narrowed role keeps only what it was left', () {
    settings.setRoleOrderType('cashier', OrderType.dineIn, false);
    settings.setRoleOrderType('cashier', OrderType.takeaway, false);

    expect(settings.orderTypesFor('cashier'), {OrderType.delivery});
    expect(settings.roleCanRing('cashier', OrderType.dineIn), isFalse);
    // One role's rule is not another's.
    expect(settings.orderTypesFor('runner'), OrderType.values.toSet());
  });

  test('the last order type cannot be taken away', () {
    for (final t in OrderType.values) {
      settings.setRoleOrderType('cashier', t, false);
    }
    // A role that could ring nothing is a till nobody can sell on.
    expect(settings.orderTypesFor('cashier').length, 1);
  });

  test('a type handed back is offered again', () {
    settings.setRoleOrderType('cashier', OrderType.delivery, false);
    expect(settings.roleCanRing('cashier', OrderType.delivery), isFalse);
    settings.setRoleOrderType('cashier', OrderType.delivery, true);
    expect(settings.roleCanRing('cashier', OrderType.delivery), isTrue);
  });

  test('an unreadable saved value reads as unrestricted, never as locked out', () {
    settings.setString('role_order_types', 'not json');
    expect(settings.orderTypesFor('cashier'), OrderType.values.toSet());
  });
}
