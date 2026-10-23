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
    await t.tap(find.byKey(const Key('level-cashier')));
    await t.pumpAndSettle();
    // The list is longer than a short screen, so scroll to the switch the way a
    // manager would rather than tapping at a coordinate off the bottom.
    final discount = find.byKey(Key('perm-${Permission.applyDiscount.key}'));
    // Far enough down the list that it is not built yet, so scroll it into being
    // rather than asking for an element that does not exist.
    await t.scrollUntilVisible(discount, 200);
    await t.pumpAndSettle();
    await t.tap(discount);
    await t.pump();

    expect(settings.roleCan('cashier', Permission.applyDiscount), isTrue);
    expect(changed, greaterThan(0));
  });

  testWidgets('a level just added opens on its own page, ready to set up',
      (t) async {
    t.view.physicalSize = const Size(1366, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(
      home: RolesPermissionsScreen(settings: settings, onChanged: () {}),
    ));
    await t.tap(find.byKey(const Key('add-role')));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const Key('role-name-field')), 'Level 1');
    await t.tap(find.byKey(const Key('role-name-save')));
    await t.pumpAndSettle();

    expect(find.byKey(const Key('level-page-Level 1')), findsOneWidget);
    final refund = find.byKey(Key('perm-Level 1-${Permission.refund.key}'));
    await t.scrollUntilVisible(refund, 200);
    await t.pumpAndSettle();
    await t.tap(refund);
    await t.pump();
    expect(settings.roleCan('Level 1', Permission.refund), isTrue);

    await t.pageBack();
    await t.pumpAndSettle();
    expect(find.byKey(const Key('level-Level 1')), findsOneWidget,
        reason: 'the new level sits on the list, a tap away');
    await t.tap(find.byKey(const Key('level-Level 1')));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('access-open-Level 1')), findsOneWidget);
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

    await t.tap(find.byKey(const Key('level-cashier')));
    await t.pumpAndSettle();
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
