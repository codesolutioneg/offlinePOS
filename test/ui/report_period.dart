import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// Open a report off the hub: pick it in the tree, set the period on the form,
/// and run it. All by default, so a fixture's dates are not a race with the clock.
Future<void> tapReport(WidgetTester t, String tile,
    {String period = 'all'}) async {
  final finder = find.byKey(Key(tile));
  if (finder.evaluate().isEmpty) {
    await t.scrollUntilVisible(finder, 200,
        scrollable: find.byType(Scrollable).last);
  }
  await t.ensureVisible(finder);
  await t.pumpAndSettle();
  await t.tap(finder);
  await t.pumpAndSettle();
  await t.tap(find.byKey(const Key('report-period')));
  await t.pumpAndSettle();
  await t.tap(find.byKey(Key('period-$period')).last);
  await t.pumpAndSettle();
  await t.tap(find.byKey(const Key('report-run')));
  await t.pumpAndSettle();
}

/// What the report page on screen shows on the same line as [label]: a report
/// opens as a page, where a line is the pieces of text at one height.
List<String> pageLine(WidgetTester t, String label) {
  final cells = t
      .widgetList<Positioned>(find.descendant(
          of: find.byKey(const Key('rm-page')),
          matching: find.byType(Positioned)))
      .where((p) => p.child is Text)
      .toList();
  String text(Positioned p) => (p.child as Text).data ?? '';
  final at = cells.firstWhere((p) => text(p) == label).top;
  return [
    for (final p in cells)
      if (p.top == at && text(p) != label) text(p),
  ];
}

/// Close the report that is open: its page, or its own screen when it opened
/// as one.
Future<void> closeReport(WidgetTester t) async {
  final close = find.byKey(const Key('rm-close'));
  if (close.evaluate().isEmpty) {
    await t.pageBack();
  } else {
    await t.tap(close);
  }
  await t.pumpAndSettle();
}
