import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/widgets/icon_pad.dart';

void main() {
  Future<String?> open(WidgetTester t, List<IconPadItem> items) async {
    t.view.physicalSize = const Size(1366, 768);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    String? picked;
    await t.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            key: const Key('open'),
            onPressed: () async {
              picked = await showDialog<String>(
                  context: context, builder: (_) => IconPad(items: items));
            },
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await t.tap(find.byKey(const Key('open')));
    await t.pumpAndSettle();
    return picked;
  }

  List<IconPadItem> items(int n) => [
        for (var i = 0; i < n; i++)
          IconPadItem('b$i', 'pad-b$i', Icons.star, 'B$i', Colors.blue, i != 1),
      ];

  testWidgets('fifteen to a page, with paging past that', (t) async {
    await open(t, items(20));
    expect(find.byKey(const Key('pad-b14')), findsOneWidget);
    expect(find.byKey(const Key('pad-b15')), findsNothing);

    await t.tap(find.byKey(const Key('misc-next')));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('pad-b15')), findsOneWidget);
    expect(find.byKey(const Key('pad-b0')), findsNothing);

    await t.tap(find.byKey(const Key('misc-prev')));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('pad-b0')), findsOneWidget);
  });

  testWidgets('one page shows no paging; a greyed button does nothing',
      (t) async {
    await open(t, items(4));
    expect(find.byKey(const Key('misc-next')), findsNothing);
    expect(t.widget<InkWell>(find.byKey(const Key('pad-b1'))).onTap, isNull);

    await t.tap(find.byKey(const Key('pad-b2')));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('misc-pad')), findsNothing);
  });
}
