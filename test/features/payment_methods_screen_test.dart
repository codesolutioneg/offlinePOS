import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/db/database.dart';
import 'package:offline_pos/core/db/settings_store.dart';
import 'package:offline_pos/domain/catalogue.dart';
import 'package:offline_pos/features/settings/payment_methods_screen.dart';

import '../db/sqlite_loader.dart';

/// Renaming a tender for the paper only.
void main() {
  late Db db;
  late SettingsStore settings;
  int changedCount = 0;

  const methods = [
    PaymentMethod(id: 1, name: 'Cash', isCash: true),
    PaymentMethod(id: 2, name: 'Bank'),
  ];

  setUpAll(useSystemSqlite);
  setUp(() {
    db = Db.open(':memory:');
    settings = SettingsStore(db);
    changedCount = 0;
  });
  tearDown(() => db.close());

  Widget app({List<PaymentMethod> withMethods = methods}) => MaterialApp(
        home: PaymentMethodsScreen(
          settings: settings,
          methods: withMethods,
          onChanged: () => changedCount++,
        ),
      );

  testWidgets('a printed name is saved against the method id', (t) async {
    await t.pumpWidget(app());

    await t.enterText(find.byKey(const Key('payment-label-2')), 'Visa / Mastercard');
    await t.tap(find.byKey(const Key('save-payment-labels')));
    await t.pumpAndSettle();

    expect(settings.paymentMethodLabels, {2: 'Visa / Mastercard'});
    expect(changedCount, 1);
  });

  testWidgets('emptying the box gives the method its own name back', (t) async {
    settings.setPaymentMethodLabel(2, 'Visa / Mastercard');
    await t.pumpWidget(app());

    expect(
        t.widget<TextField>(find.byKey(const Key('payment-label-2')))
            .controller!
            .text,
        'Visa / Mastercard');

    await t.enterText(find.byKey(const Key('payment-label-2')), '   ');
    await t.tap(find.byKey(const Key('save-payment-labels')));
    await t.pumpAndSettle();

    expect(settings.paymentMethodLabels, isEmpty);
  });

  testWidgets('a till that has never synced says so instead of showing nothing',
      (t) async {
    await t.pumpWidget(app(withMethods: const []));

    expect(find.byKey(const Key('no-payment-methods')), findsOneWidget);
    expect(find.byKey(const Key('save-payment-labels')), findsNothing);
  });

  testWidgets('pay later is off until a method is nominated, and never cash',
      (t) async {
    await t.pumpWidget(app());
    expect(settings.payLaterMethodId, isNull);

    // What the two names look like on the screen behind the closed picker.
    final cashBefore = t.widgetList(find.text('Cash')).length;
    final bankBefore = t.widgetList(find.text('Bank')).length;

    await t.tap(find.byKey(const Key('pay-later-method')));
    await t.pumpAndSettle();
    // The menu offers Bank and not Cash: a tab booked as cash counts the drawer
    // short by money nobody handed over.
    expect(t.widgetList(find.text('Bank')).length, bankBefore + 1);
    expect(t.widgetList(find.text('Cash')).length, cashBefore);

    await t.tap(find.text('Bank').last);
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('save-payment-labels')));
    await t.pumpAndSettle();

    expect(settings.payLaterMethodId, 2);
  });

  /// A manager choosing tenders has to see where each one puts the money, or
  /// "Bank" and "Cash" are two words with nothing behind them.
  group('what a tender books to', () {
    String journalLine(WidgetTester t, int id) =>
        t.widget<Text>(find.byKey(Key('payment-journal-$id'))).data!;

    testWidgets('the journal name and its type sit under the method', (t) async {
      await t.pumpWidget(app(withMethods: const [
        PaymentMethod(
            id: 1, name: 'Cash', isCash: true, journalId: 11,
            journalName: 'Cash drawer', journalType: 'cash'),
        PaymentMethod(
            id: 2, name: 'Card', journalId: 12,
            journalName: 'Bank CIB', journalType: 'bank'),
      ]));

      expect(journalLine(t, 1), contains('Cash drawer'));
      expect(journalLine(t, 1), contains('Cash'));
      expect(journalLine(t, 2), contains('Bank CIB'));
      expect(journalLine(t, 2), contains('Bank'));
    });

    testWidgets('a method with no journal is named as pay later', (t) async {
      await t.pumpWidget(app(withMethods: const [
        PaymentMethod(id: 4, name: 'Customer account'),
      ]));

      expect(journalLine(t, 4), contains('pay later'),
          reason: 'Odoo holds no journal against its pay-later tender, so the '
              'gap is the meaning rather than missing data');
    });
  });
}
