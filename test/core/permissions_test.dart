import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/auth/permissions.dart';
import 'package:offline_pos/core/db/database.dart';
import 'package:offline_pos/core/db/settings_store.dart';

import '../db/sqlite_loader.dart';

void main() {
  group('Permission model', () {
    test('every permission has a unique, stable key with a label and description', () {
      final keys = Permission.values.map((p) => p.key).toList();
      expect(keys.toSet().length, Permission.values.length);
      for (final p in Permission.values) {
        expect(p.key, isNotEmpty);
        expect(p.label, isNotEmpty);
        expect(p.description, isNotEmpty);
        expect(Permission.fromKey(p.key), p);
      }
    });

    test('fromKey returns null for an unknown key', () {
      expect(Permission.fromKey('not_a_real_key'), isNull);
    });
  });

  group('role permissions in the settings store', () {
    late Db db;
    late SettingsStore settings;
    setUpAll(useSystemSqlite);
    setUp(() {
      db = Db.open(':memory:');
      settings = SettingsStore(db);
    });
    tearDown(() => db.close());

    test('a manager always has every permission and cannot be reduced', () {
      expect(settings.permissionsFor('manager'), Permission.values.toSet());
      // Attempting to revoke a manager permission is a no-op.
      settings.setRolePermission('manager', Permission.refund, false);
      expect(settings.permissionsFor('manager'), Permission.values.toSet());
      expect(settings.roleCan('manager', Permission.refund), isTrue);
    });

    test('a cashier defaults to reprint and view reports only', () {
      expect(settings.permissionsFor('cashier'),
          {Permission.reprint, Permission.viewReports});
      expect(settings.roleCan('cashier', Permission.applyDiscount), isFalse);
      expect(settings.roleCan('cashier', Permission.reprint), isTrue);
    });

    test('granting and revoking a cashier permission round-trips and persists', () {
      settings.setRolePermission('cashier', Permission.applyDiscount, true);
      expect(settings.roleCan('cashier', Permission.applyDiscount), isTrue);
      // The sensible defaults are not wiped by toggling one permission.
      expect(settings.roleCan('cashier', Permission.reprint), isTrue);
      expect(settings.roleCan('cashier', Permission.viewReports), isTrue);

      // A fresh store over the same database still sees the saved value.
      final reopened = SettingsStore(db);
      expect(reopened.roleCan('cashier', Permission.applyDiscount), isTrue);

      // Revoking a default takes effect and leaves the rest intact.
      settings.setRolePermission('cashier', Permission.reprint, false);
      expect(settings.roleCan('cashier', Permission.reprint), isFalse);
      expect(settings.roleCan('cashier', Permission.viewReports), isTrue);
    });

    test('correcting a paid sale asks a manager until it is granted', () {
      // Rewriting a sale that is already tendered is not a cashier's on their own,
      // so it falls to the manager-PIN gate by default and can still be delegated.
      expect(settings.roleCan('cashier', Permission.amendOrder), isFalse);
      settings.setRolePermission('cashier', Permission.amendOrder, true);
      expect(settings.roleCan('cashier', Permission.amendOrder), isTrue);
      expect(settings.roleCan('manager', Permission.amendOrder), isTrue);
    });

    test('an unknown custom role starts with no permissions', () {
      expect(settings.permissionsFor('runner'), isEmpty);
      settings.setRolePermission('runner', Permission.reprint, true);
      expect(settings.permissionsFor('runner'), {Permission.reprint});
    });
  });
}
