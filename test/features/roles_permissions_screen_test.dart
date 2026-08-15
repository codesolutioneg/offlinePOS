import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/auth/permissions.dart';
import 'package:offline_pos/core/db/database.dart';
import 'package:offline_pos/core/db/settings_store.dart';
import 'package:offline_pos/domain/order.dart';
import 'package:offline_pos/features/admin/roles_permissions_screen.dart';

import '../db/sqlite_loader.dart';

void main() {
  late Db db;
  late SettingsStore settings;
  setUpAll(useSystemSqlite);
  setUp(() {
    db = Db.open(':memory:');
    settings = SettingsStore(db);
  });
  tearDown(() => db.close());

  testWidgets('toggling a cashier permission persists it', (t) async {
    var changed = 0;
    await t.pumpWidget(MaterialApp(
      home: RolesPermissionsScreen(settings: settings, onChanged: () => changed++),
    ));

    expect(settings.roleCan('cashier', Permission.applyDiscount), isFalse);
    // The list is longer than a short screen, so scroll to the switch the way a
    // manager would rather than tapping at a coordinate off the bottom.
    final discount = find.byKey(Key('perm-${Permission.applyDiscount.key}'));
    await t.ensureVisible(discount);
    await t.pumpAndSettle();
    await t.tap(discount);
    await t.pump();

    expect(settings.roleCan('cashier', Permission.applyDiscount), isTrue);
    expect(changed, greaterThan(0));
  });

  testWidgets('the manager role is shown as read-only full access', (t) async {
    await t.pumpWidget(MaterialApp(
      home: RolesPermissionsScreen(settings: settings, onChanged: () {}),
    ));
    expect(find.byKey(const Key('role-manager')), findsOneWidget);
  });

  testWidgets('taking an order type off a role persists it', (t) async {
    var changed = 0;
    await t.pumpWidget(MaterialApp(
      home: RolesPermissionsScreen(settings: settings, onChanged: () => changed++),
    ));

    final dineIn = find.byKey(const Key('order-type-allowed-dineIn'));
    await t.ensureVisible(dineIn);
    await t.pumpAndSettle();
    await t.tap(dineIn);
    await t.pump();

    expect(settings.roleCanRing('cashier', OrderType.dineIn), isFalse);
    expect(settings.roleCanRing('cashier', OrderType.takeaway), isTrue);
    expect(changed, greaterThan(0));
  });
}
