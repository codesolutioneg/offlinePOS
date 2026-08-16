import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/db/database.dart';
import 'package:offline_pos/core/db/settings_store.dart';
import 'package:offline_pos/domain/order.dart';

import 'sqlite_loader.dart';

/// Which sales the shop takes at all, and how that composes with the rule about
/// which sales each role may open.
void main() {
  late Db db;
  late SettingsStore settings;

  setUpAll(useSystemSqlite);
  setUp(() {
    db = Db.open(':memory:');
    settings = SettingsStore(db);
  });
  tearDown(() => db.close());

  test('an unconfigured shop offers everything', () {
    expect(settings.shopOrderTypes, OrderType.values.toSet());
    expect(settings.availableOrderTypesFor('cashier'), OrderType.values.toSet());
  });

  test('a withdrawn type is offered to nobody, manager included', () {
    settings.setShopOrderType(OrderType.delivery, false);

    expect(settings.shopOrderTypes.contains(OrderType.delivery), isFalse);
    expect(settings.availableOrderTypesFor('cashier').contains(OrderType.delivery),
        isFalse);
    expect(settings.availableOrderTypesFor('manager').contains(OrderType.delivery),
        isFalse);
  });

  test('the last type standing cannot be withdrawn', () {
    for (final t in OrderType.values) {
      settings.setShopOrderType(t, false);
    }

    expect(settings.shopOrderTypes.length, 1);
    expect(settings.availableOrderTypesFor('cashier'), settings.shopOrderTypes);
  });

  test('the two rules narrow each other rather than overriding', () {
    settings.setShopOrderType(OrderType.delivery, false);
    settings.setRoleOrderType('cashier', OrderType.toGo, false);

    final available = settings.availableOrderTypesFor('cashier');
    expect(available, {OrderType.dineIn, OrderType.takeaway});
    // The role rule is untouched by the shop rule, so restoring the type restores
    // exactly the roles that had it.
    expect(settings.orderTypesFor('cashier').contains(OrderType.delivery), isTrue);
    settings.setShopOrderType(OrderType.delivery, true);
    expect(settings.availableOrderTypesFor('cashier').contains(OrderType.delivery),
        isTrue);
  });

  test('a role with nothing left in common with the shop still sells', () {
    // A delivery desk in a shop that stopped delivering: the shop's word stands
    // rather than leaving a till nobody can ring a sale on.
    settings.setRoleOrderType('cashier', OrderType.dineIn, false);
    settings.setRoleOrderType('cashier', OrderType.takeaway, false);
    settings.setRoleOrderType('cashier', OrderType.toGo, false);
    settings.setShopOrderType(OrderType.delivery, false);

    expect(settings.availableOrderTypesFor('cashier'), settings.shopOrderTypes);
    expect(settings.availableOrderTypesFor('cashier'), isNotEmpty);
  });

  test('an unreadable saved value reads as everything', () {
    settings.setString('shop_order_types', 'not json');

    expect(settings.shopOrderTypes, OrderType.values.toSet());
  });

  test('the floor draws its sections beside the plan until told otherwise', () {
    expect(settings.floorSectionsSide, isTrue);
    settings.floorSectionsSide = false;
    expect(settings.floorSectionsSide, isFalse);
  });
}
