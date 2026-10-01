import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// Open a report off the hub. Each report asks for its own period once its tile
/// is tapped; All by default, so a fixture's dates are not a race with the clock.
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
  await t.tap(find.byKey(Key('period-$period')));
  await t.pumpAndSettle();
}
