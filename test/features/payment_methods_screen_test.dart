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
}
