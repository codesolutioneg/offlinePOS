import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/db/catalogue_store.dart';
import 'package:offline_pos/core/db/database.dart';
import 'package:offline_pos/core/db/settings_store.dart';
import 'package:offline_pos/domain/catalogue.dart';

import 'sqlite_loader.dart';

/// What a manager set per tender has to survive the tender list moving from Odoo's
/// point-of-sale methods to the shop's bank and cash journals.
///
/// The two are numbered from different sequences, so the settings keyed on the old
/// ids are moved through the only record of which method paid into which journal:
/// the catalogue this till already pulled. Anything that cannot be mapped is left
/// exactly as it is, and the two spaces have opposite signs, so it can never be read
/// as the journal that happens to share its number.
void main() {
  setUpAll(useSystemSqlite);

  late Db db;
  late SettingsStore settings;

  /// A till as it was before the update: methods in the catalogue, settings keyed on
  /// their ids, and the migration marker back where the schema bump leaves it.
  void asAnUpdatedTill() {
    settings.setString('tenders_from_journals', 'pending');
    settings = SettingsStore(db);
  }

  setUp(() {
    db = Db.open(':memory:');
    settings = SettingsStore(db);
    CatalogueStore(db).replaceAll(
      categories: const [Category(id: 1, name: 'Pizza')],
      products: const [
        Product(id: 10, name: 'Margherita', price: 250, categoryId: 1)
      ],
      groups: const [],
      productGroupIds: const {},
      paymentMethods: const [
        PaymentMethod(
            id: 1, name: 'Cash', isCash: true, journalId: 11,
            journalName: 'Cash drawer', journalType: 'cash'),
        PaymentMethod(
            id: 2, name: 'Card', journalId: 12,
            journalName: 'Bank CIB', journalType: 'bank'),
        PaymentMethod(id: 4, name: 'Customer account'),
      ],
      refreshedAt: DateTime.now().toUtc(),
    );
  });
  tearDown(() => db.close());

  test('a printed name follows its method to the journal it paid into', () {
    settings.setPaymentMethodLabel(2, 'Visa / Mastercard');

    asAnUpdatedTill();

    expect(settings.paymentMethodLabels, {-12: 'Visa / Mastercard'},
        reason: 'the manager named the tender that books to Bank CIB, and that '
            'is the journal now offered in its place');
  });

  test('a tender switched off stays off', () {
    settings.setPaymentMethodOffered(2, false);

    asAnUpdatedTill();

    expect(settings.disabledPaymentMethodIds, {-12});
    expect(settings.isPaymentMethodOffered(-12), isFalse);
    expect(settings.isPaymentMethodOffered(-11), isTrue,
        reason: 'only the one the manager turned off moves across');
  });

  test('the pay later nomination follows too', () {
    settings.payLaterMethodId = 2;

    asAnUpdatedTill();

    expect(settings.payLaterMethodId, -12);
  });

  test('a method the till never learned a journal for is left alone, not repointed',
      () {
    settings.setPaymentMethodOffered(4, false);
    settings.setPaymentMethodLabel(4, 'Tab');

    asAnUpdatedTill();

    expect(settings.disabledPaymentMethodIds, {4},
        reason: 'there is nothing to map it to, and the two spaces have opposite '
            'signs, so it matches nothing on the new sheet rather than silently '
            'disabling journal 4');
    expect(settings.paymentMethodLabels, {4: 'Tab'});
  });

  test('the pass runs once and does not move a journal a second time', () {
    settings.setPaymentMethodLabel(2, 'Visa / Mastercard');
    asAnUpdatedTill();
    asAnUpdatedTill();

    expect(settings.paymentMethodLabels, {-12: 'Visa / Mastercard'});
  });

  test('a fresh till has nothing to move', () {
    // The schema bump marks every database, including one that never held a
    // point-of-sale method, so the pass has to be a no-op there.
    expect(settings.paymentMethodLabels, isEmpty);
    expect(settings.disabledPaymentMethodIds, isEmpty);
    expect(settings.getString('tenders_from_journals'), 'done');
  });
}
