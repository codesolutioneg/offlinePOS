import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/domain/catalogue.dart';
import 'package:offline_pos/features/sell/modifier_sheet.dart';

/// A box of ten cannot be left at eight by tapping on to the next group; going
/// back to one already answered is always allowed.
void main() {
  const box = Product(id: 10, name: 'Mini box 10', price: 629.99, categoryId: 1);
  const groups = [
    ModifierGroup(
      id: 1,
      name: 'Bread',
      required: true,
      minSelection: 1,
      maxSelection: 1,
      modifiers: [Modifier(id: 11, groupId: 1, name: 'Brioche', price: 0)],
    ),
    ModifierGroup(
      id: 2,
      name: 'Pieces',
      required: true,
      minSelection: 10,
      maxSelection: 10,
      modifiers: [
        Modifier(id: 21, groupId: 2, name: 'Mix cheese', price: 0),
        Modifier(id: 22, groupId: 2, name: 'Turkey', price: 0),
      ],
    ),
    ModifierGroup(
      id: 3,
      name: 'Drinks',
      maxSelection: 2,
      modifiers: [Modifier(id: 31, groupId: 3, name: 'Pepsi', price: 0)],
    ),
  ];

  Future<void> open(WidgetTester t) async {
    t.view.physicalSize = const Size(1200, 1600);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ModifierSheet(
          product: box,
          groups: groups,
          formatAmount: (v) => v.toStringAsFixed(2),
        ),
      ),
    ));
  }

  String current(WidgetTester t) =>
      groups.firstWhere((g) => find.text(g.name).evaluate().length > 1).name;

  testWidgets('a group ahead stays shut until the one before it is complete',
      (t) async {
    await open(t);
    await t.tap(find.byKey(const Key('mod-11')));
    await t.pumpAndSettle();
    expect(current(t), 'Pieces');

    for (var i = 0; i < 8; i++) {
      await t.tap(find.byKey(const Key('mod-21-plus')));
    }
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('mod-step-2')));
    await t.pumpAndSettle();
    expect(current(t), 'Pieces');

    await t.tap(find.byKey(const Key('mod-22-plus')));
    await t.tap(find.byKey(const Key('mod-22-plus')));
    await t.pumpAndSettle();
    expect(current(t), 'Drinks');
  });

  testWidgets('going back to an answered group is always open', (t) async {
    await open(t);
    await t.tap(find.byKey(const Key('mod-11')));
    await t.pumpAndSettle();
    expect(current(t), 'Pieces');

    await t.tap(find.byKey(const Key('mod-step-0')));
    await t.pumpAndSettle();
    expect(current(t), 'Bread');
  });
}
