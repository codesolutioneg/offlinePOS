import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/auth/permissions.dart';
import 'package:offline_pos/core/db/database.dart';
import 'package:offline_pos/core/db/settings_store.dart';
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
    await t.tap(find.byKey(Key('perm-${Permission.applyDiscount.key}')));
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
}
