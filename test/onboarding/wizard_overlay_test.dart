import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/features/onboarding/wizard_overlay.dart';

void main() {
  late List<WizardOutcome> closed;

  setUp(() => closed = []);

  const steps = [
    WizardStep(title: 'Pick a product', body: 'Tap anything in the grid.'),
    WizardStep(title: 'Take the money', body: 'Tap Pay when the order is right.'),
    WizardStep(title: 'Print', body: 'The receipt prints on its own.'),
  ];

  Widget app({List<WizardStep>? only}) => MaterialApp(
        home: Scaffold(
          body: WizardOverlay(steps: only ?? steps, onClosed: closed.add),
        ),
      );

  testWidgets('opens on the first step with nothing to go back to', (t) async {
    await t.pumpWidget(app());
    expect(find.text('Pick a product'), findsOneWidget);
    expect(find.byKey(const Key('wizard-progress')), findsOneWidget);
    expect(t.widget<TextButton>(find.byKey(const Key('wizard-back'))).onPressed,
        isNull);
  });

  testWidgets('advances and goes back', (t) async {
    await t.pumpWidget(app());
    await t.tap(find.byKey(const Key('wizard-next')));
    await t.pumpAndSettle();
    expect(find.text('Take the money'), findsOneWidget);
    await t.tap(find.byKey(const Key('wizard-back')));
    await t.pumpAndSettle();
    expect(find.text('Pick a product'), findsOneWidget);
    expect(closed, isEmpty);
  });

  testWidgets('the last step finishes instead of advancing', (t) async {
    await t.pumpWidget(app());
    for (var i = 0; i < steps.length; i++) {
      await t.tap(find.byKey(const Key('wizard-next')));
      await t.pumpAndSettle();
    }
    // Reading to the end is not a request to never see it again.
    expect(closed, [WizardOutcome.completed]);
  });

  testWidgets("'Don't show this again' reports a permanent dismissal", (t) async {
    await t.pumpWidget(app());
    await t.tap(find.byKey(const Key('wizard-never')));
    await t.pumpAndSettle();
    expect(closed, [WizardOutcome.dismissedForever]);
  });

  testWidgets('skipping closes it without turning it off for good', (t) async {
    await t.pumpWidget(app());
    await t.tap(find.byKey(const Key('wizard-skip')));
    await t.pumpAndSettle();
    expect(closed, [WizardOutcome.skipped]);
  });

  testWidgets('tapping outside closes it without turning it off for good',
      (t) async {
    await t.pumpWidget(app());
    await t.tapAt(const Offset(4, 4));
    await t.pumpAndSettle();
    expect(closed, [WizardOutcome.skipped]);
  });

  testWidgets('escape closes it the same as skipping', (t) async {
    await t.pumpWidget(app());
    await t.pump();
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await t.pumpAndSettle();
    expect(closed, [WizardOutcome.skipped]);
  });

  testWidgets('the arrow keys move between steps', (t) async {
    await t.pumpWidget(app());
    await t.pump();
    await t.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await t.pumpAndSettle();
    expect(find.text('Take the money'), findsOneWidget);
    await t.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await t.pumpAndSettle();
    expect(find.text('Pick a product'), findsOneWidget);
  });

  testWidgets('a single-step wizard is done in one tap', (t) async {
    await t.pumpWidget(app(only: const [
      WizardStep(title: 'Only step', body: 'That is all.'),
    ]));
    expect(find.text('Done'), findsOneWidget);
    await t.tap(find.byKey(const Key('wizard-next')));
    await t.pumpAndSettle();
    expect(closed, [WizardOutcome.completed]);
  });
}
