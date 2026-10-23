import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/features/tables/floor_action_bar.dart';

void main() {
  Future<void> pump(WidgetTester tester, Widget bar, {double width = 1400}) async {
    tester.view.physicalSize = Size(width, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: Align(alignment: Alignment.bottomCenter, child: bar)),
    ));
  }

  List<FloorAction> actions(List<String> taps, {bool held = false}) => [
        for (final id in ['begin', 'end', 'tabs', 'quick'])
          FloorAction(
            id: id,
            label: id,
            icon: Icons.circle,
            color: Colors.orange,
            newWork: id == 'quick',
            onTap: () => taps.add(id),
          ),
        const FloorAction(
            id: 'employee-transfer',
            label: 'x',
            icon: Icons.circle,
            color: Colors.blue),
      ];

  testWidgets('each tile runs its action; a tile with no action is inert',
      (tester) async {
    final taps = <String>[];
    await pump(tester, FloorActionBar(actions: actions(taps)));
    await tester.tap(find.byKey(const Key('floor-action-begin')));
    await tester.tap(find.byKey(const Key('floor-action-tabs')));
    await tester.tap(find.byKey(const Key('floor-action-employee-transfer')));
    expect(taps, ['begin', 'tabs']);
  });

  testWidgets('the guard can refuse a tile that starts an order', (tester) async {
    final taps = <String>[];
    await pump(
        tester, FloorActionBar(actions: actions(taps), guard: (_) => false));
    await tester.tap(find.byKey(const Key('floor-action-quick')));
    await tester.tap(find.byKey(const Key('floor-action-end')));
    expect(taps, ['end']);
  });

  testWidgets('wraps onto two rows on a narrow window', (tester) async {
    await pump(tester, FloorActionBar(actions: actions([])), width: 300);
    final first = tester.getTopLeft(find.byKey(const Key('floor-action-begin')));
    final last = tester
        .getTopLeft(find.byKey(const Key('floor-action-employee-transfer')));
    expect(last.dy, greaterThan(first.dy));
  });
}
