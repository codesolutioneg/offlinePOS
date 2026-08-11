import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/db/customer_store.dart';
import 'package:offline_pos/core/db/database.dart';
import 'package:offline_pos/features/customers/customer_management_screen.dart';

import '../db/sqlite_loader.dart';

void main() {
  late Db db;
  late CustomerStore store;
  int changedCount = 0;

  setUpAll(useSystemSqlite);
  setUp(() {
    db = Db.open(':memory:');
    store = CustomerStore(db);
    changedCount = 0;
  });
  tearDown(() => db.close());

  Widget app() => MaterialApp(
        home: CustomerManagementScreen(
          store: store,
          onChanged: () => changedCount++,
        ),
      );

  testWidgets('shows an empty state when there are no local customers yet', (t) async {
    await t.pumpWidget(app());
    expect(find.byKey(const Key('no-customers')), findsOneWidget);
  });

  testWidgets('the search field and add-customer control are present', (t) async {
    await t.pumpWidget(app());
    expect(find.byKey(const Key('customer-search')), findsOneWidget);
    expect(find.byKey(const Key('add-customer')), findsOneWidget);
  });

  testWidgets('adding a customer saves it and shows it in the list', (t) async {
    await t.pumpWidget(app());

    await t.tap(find.byKey(const Key('add-customer')));
    await t.pumpAndSettle();

    await t.enterText(find.byKey(const Key('cust-name')), 'Layla');
    await t.enterText(find.byKey(const Key('cust-phone')), '0100000000');
    await t.tap(find.byKey(const Key('customer-form-save')));
    await t.pumpAndSettle();

    expect(store.search(query: 'Layla'), isNotEmpty);
    expect(find.text('Layla'), findsOneWidget);
    expect(find.text('0100000000'), findsOneWidget);
    expect(changedCount, 1);
  });

  testWidgets('a blank name is rejected inline and nothing is saved', (t) async {
    await t.pumpWidget(app());

    await t.tap(find.byKey(const Key('add-customer')));
    await t.pumpAndSettle();

    await t.tap(find.byKey(const Key('customer-form-save')));
    await t.pump();

    expect(find.byKey(const Key('customer-form-error')), findsOneWidget);
    expect(store.search(), isEmpty);
    expect(changedCount, 0);
  });

  testWidgets('searching filters the visible list by name', (t) async {
    store.add(name: 'Mona', phone: '111');
    store.add(name: 'Ziad', phone: '222');

    await t.pumpWidget(app());
    await t.pumpAndSettle();

    await t.enterText(find.byKey(const Key('customer-search')), 'Mona');
    await t.pumpAndSettle();

    // 'Mona' also appears in the search field, so allow more than one match; the
    // meaningful assertion is that the non-matching customer is filtered out.
    expect(find.text('Mona'), findsWidgets);
    expect(find.text('Ziad'), findsNothing);
  });
}
