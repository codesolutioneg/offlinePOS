import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/db/database.dart';
import 'package:offline_pos/core/db/settings_store.dart';
import 'package:offline_pos/domain/order.dart' show OrderType;

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

  group('per order type', () {
    test('a method is offered for every type until narrowed', () {
      for (final t in OrderType.values) {
        expect(settings.isPaymentMethodOfferedFor(2, t), isTrue);
      }
      expect(settings.paymentMethodOrderTypes, isEmpty);
    });

    test('narrowing one method leaves the others and survives a reopen', () {
      settings.setPaymentMethodTypes(2, {OrderType.deliveryFromCompany});

      final fresh = SettingsStore(db);
      expect(fresh.isPaymentMethodOfferedFor(2, OrderType.deliveryFromCompany), isTrue);
      expect(fresh.isPaymentMethodOfferedFor(2, OrderType.dineIn), isFalse);
      expect(fresh.isPaymentMethodOfferedFor(1, OrderType.dineIn), isTrue);
    });

    test('ticking every type again clears the restriction', () {
      settings.setPaymentMethodTypes(2, {OrderType.dineIn});
      settings.setPaymentMethodTypes(2, OrderType.values.toSet());
      expect(settings.paymentMethodOrderTypes, isEmpty);
    });

    test('a method switched off is off for every type', () {
      settings.setPaymentMethodOffered(2, false);
      expect(settings.isPaymentMethodOfferedFor(2, OrderType.dineIn), isFalse);
    });

    test('travels to a joining till with the shop settings', () {
      settings.setPaymentMethodTypes(2, {OrderType.takeaway, OrderType.toGo});
      final bundle = settings.exportShopBundle();

      final other = SettingsStore(Db.open(':memory:'));
      other.applyShopBundle(bundle);
      expect(other.paymentMethodTypes(2), {OrderType.takeaway, OrderType.toGo});
      expect(other.paymentMethodTypes(1), OrderType.values.toSet());
    });
  });
}
