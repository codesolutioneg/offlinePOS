import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/db/database.dart';
import 'package:offline_pos/core/onboarding/wizard_id.dart';
import 'package:offline_pos/core/onboarding/wizard_store.dart';

import '../db/sqlite_loader.dart';

void main() {
  late Db db;
  late WizardStore store;

  setUpAll(useSystemSqlite);
  setUp(() {
    db = Db.open(':memory:');
    store = WizardStore(db);
  });
  tearDown(() => db.close());

  test('a wizard is offered the first time and not after it is dismissed', () {
    expect(store.shouldShow(WizardId.firstSale, 'sara'), isTrue);
    store.dismiss(WizardId.firstSale, 'sara');
    expect(store.shouldShow(WizardId.firstSale, 'sara'), isFalse);
  });

  test('dismissing one wizard leaves the others showing', () {
    store.dismiss(WizardId.firstSale, 'sara');
    expect(store.shouldShow(WizardId.modifiers, 'sara'), isTrue);
    expect(store.shouldShow(WizardId.printerSetup, 'sara'), isTrue);
  });

  test('one cashier switching help off does not hide it from the other', () {
    store.dismiss(WizardId.firstSignIn, 'sara');
    expect(store.shouldShow(WizardId.firstSignIn, 'omar'), isTrue);
  });

  test('dismissing the same wizard twice is not an error', () {
    store.dismiss(WizardId.diagnostics, 'sara');
    store.dismiss(WizardId.diagnostics, 'sara');
    expect(store.shouldShow(WizardId.diagnostics, 'sara'), isFalse);
  });

  test('dismissing everything covers every wizard this build ships', () {
    store.dismissAll('sara');
    for (final id in WizardId.values) {
      expect(store.shouldShow(id, 'sara'), isFalse, reason: id.key);
    }
  });

  test('a wizard shipped later still shows once, after the rest were dismissed', () {
    // What an earlier build's "dismiss everything" wrote: every wizard that existed
    // then. Printer setup stands in for the one added afterwards.
    for (final id in WizardId.values.where((id) => id != WizardId.printerSetup)) {
      store.dismiss(id, 'sara');
    }
    expect(store.shouldShow(WizardId.printerSetup, 'sara'), isTrue);
  });

  test('reset brings them all back', () {
    store.dismissAll('sara');
    store.dismissAll('omar');
    store.reset();
    expect(store.shouldShow(WizardId.firstSale, 'sara'), isTrue);
    expect(store.shouldShow(WizardId.firstSale, 'omar'), isTrue);
  });

  test('resetting one cashier leaves the other cashier alone', () {
    store.dismissAll('sara');
    store.dismissAll('omar');
    store.reset(cashierId: 'sara');
    expect(store.shouldShow(WizardId.modifiers, 'sara'), isTrue);
    expect(store.shouldShow(WizardId.modifiers, 'omar'), isFalse);
  });
}
