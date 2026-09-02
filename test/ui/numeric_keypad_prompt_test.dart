import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/widgets/numeric_keypad.dart';

/// The touch number-pad dialog keeps the promise its display makes.
void main() {
  Future<double?> prompt(WidgetTester t, {String? initial}) async {
    double? answer;
    var done = false;
    await t.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async {
            answer = await promptNumber(context,
                title: 'Opening float', initial: initial);
            done = true;
          },
          child: const Text('open'),
        ),
      ),
    ));
    await t.tap(find.text('open'));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('keypad-ok')));
    await t.pumpAndSettle();
    expect(done, isTrue);
    return answer;
  }

  testWidgets('OK on the untouched pad answers the zero the display shows',
      (t) async {
    // The display reads 0 while nothing is typed; pressing OK must mean that
    // 0, not a silent cancel that makes the cashier type the zero themselves.
    expect(await prompt(t), 0);
  });

  testWidgets('a typed value still answers itself', (t) async {
    double? answer;
    await t.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async {
            answer = await promptNumber(context, title: 'Opening float');
          },
          child: const Text('open'),
        ),
      ),
    ));
    await t.tap(find.text('open'));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('key-2')));
    await t.tap(find.byKey(const Key('key-5')));
    await t.pump();
    await t.tap(find.byKey(const Key('keypad-ok')));
    await t.pumpAndSettle();
    expect(answer, 25);
  });
}
