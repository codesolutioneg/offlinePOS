import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/db/database.dart';
import 'package:offline_pos/core/db/settings_store.dart';

import 'sqlite_loader.dart';

/// Which payment methods (journals) the till offers. Off-by-omission: a method
/// nobody has touched is offered, so a fresh till shows them all, and turning one
/// off hides only it, surviving a reopen.
void main() {
  setUpAll(useSystemSqlite);

  late Db db;
  late SettingsStore settings;

  setUp(() {
    db = Db.open(':memory:');
    settings = SettingsStore(db);
  });
  tearDown(() => db.close());

  test('every method is offered until one is turned off', () {
    expect(settings.isPaymentMethodOffered(1), isTrue);
    expect(settings.disabledPaymentMethodIds, isEmpty);
  });

  test('a category accepts auto-add until it is turned off, and it persists', () {
    expect(settings.isAutoAddAllowed(7), isTrue);
    expect(settings.isAutoAddAllowed(null), isTrue);

    settings.setAutoAddAllowed(7, false);
    expect(settings.isAutoAddAllowed(7), isFalse);
    expect(settings.isAutoAddAllowed(8), isTrue);

    final fresh = SettingsStore(db);
    expect(fresh.isAutoAddAllowed(7), isFalse);
    fresh.setAutoAddAllowed(7, true);
    expect(fresh.isAutoAddAllowed(7), isTrue);
    expect(fresh.autoAddDisabledCategories, isEmpty);
  });

  test('turning a method off hides only it, and it persists', () {
    settings.setPaymentMethodOffered(2, false);
    expect(settings.isPaymentMethodOffered(2), isFalse);
    expect(settings.isPaymentMethodOffered(1), isTrue);

    // Survives a reopen (a new store over the same db).
    final fresh = SettingsStore(db);
    expect(fresh.isPaymentMethodOffered(2), isFalse);
    expect(fresh.disabledPaymentMethodIds, {2});

    // Turning it back on clears it.
    fresh.setPaymentMethodOffered(2, true);
    expect(fresh.isPaymentMethodOffered(2), isTrue);
    expect(fresh.disabledPaymentMethodIds, isEmpty);
  });
}
