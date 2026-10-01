import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/features/sell/lost_void_banner.dart';

/// A cancel slip the kitchen never got stays on screen until it is reprinted or
/// the cashier says the kitchen was told: the item is already off the bill, so
/// this warning is the only thing that stops the kitchen cooking it.
void main() {
  late ValueNotifier<List<LostKitchenVoid>> lost;
  late bool printerBack;
  late int retries;

  setUp(() {
    printerBack = false;
    retries = 0;
    lost = ValueNotifier([
      LostKitchenVoid(
        id: 1,
        item: '2× Burger',
        where: 'T4',
        retry: () async {
          retries++;
          return printerBack;
        },
      ),
    ]);
  });
  tearDown(() => lost.dispose());

  Widget banner() => MaterialApp(
        home: Scaffold(
          body: LostVoidBanner(
            lost: lost,
            onResolved: (id) =>
                lost.value = [for (final v in lost.value) if (v.id != id) v],
          ),
        ),
      );

  testWidgets('a lost void is shown with the item and where it was', (t) async {
    await t.pumpWidget(banner());

    expect(find.byKey(const Key('lost-void-1')), findsOneWidget);
    expect(find.textContaining('2× Burger'), findsOneWidget);
    expect(find.textContaining('T4'), findsOneWidget);
  });

  testWidgets('retry with the printer still down keeps the warning', (t) async {
    await t.pumpWidget(banner());

    await t.tap(find.byKey(const Key('lost-void-retry-1')));
    await t.pumpAndSettle();

    expect(retries, 1);
    expect(find.byKey(const Key('lost-void-1')), findsOneWidget);
  });

  testWidgets('retry once the printer is back clears the warning', (t) async {
    await t.pumpWidget(banner());
    printerBack = true;

    await t.tap(find.byKey(const Key('lost-void-retry-1')));
    await t.pumpAndSettle();

    expect(find.byKey(const Key('lost-void-1')), findsNothing);
  });

  testWidgets('"kitchen told" clears it without printing', (t) async {
    await t.pumpWidget(banner());

    await t.tap(find.byKey(const Key('lost-void-told-1')));
    await t.pumpAndSettle();

    expect(retries, 0);
    expect(find.byKey(const Key('lost-void-1')), findsNothing);
  });
}
