import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/widgets/select_pill.dart';

void main() {
  Future<(Color, Color)> colours(WidgetTester t, Brightness b,
      {required bool selected}) async {
    await t.pumpWidget(MaterialApp(
      theme: ThemeData(brightness: b),
      home: Scaffold(
        body: SelectPill(label: 'Takeaway', selected: selected, onTap: () {}),
      ),
    ));
    final text = t.widget<Text>(find.text('Takeaway')).style!.color!;
    final box = t.widget<AnimatedContainer>(find.byType(AnimatedContainer));
    return (text, (box.decoration! as BoxDecoration).color!);
  }

  for (final b in Brightness.values) {
    testWidgets('an unselected label is readable on the $b theme', (t) async {
      final (fg, bg) = await colours(t, b, selected: false);
      final ratio =
          (fg.computeLuminance() + 0.05) / (bg.computeLuminance() + 0.05);
      expect(ratio > 1 ? ratio : 1 / ratio, greaterThan(4.5));
    });
  }
}
