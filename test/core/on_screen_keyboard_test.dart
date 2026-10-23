import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/widgets/on_screen_keyboard.dart';

void main() {
  Future<TextEditingController> open(WidgetTester t,
      {bool arabicFirst = false, VoidCallback? onDone}) async {
    final ctrl = TextEditingController();
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Column(children: [
          TextField(key: const Key('field'), controller: ctrl, autofocus: true),
          OnScreenKeyboard(controller: ctrl, arabicFirst: arabicFirst, onDone: onDone),
        ]),
      ),
    ));
    await t.pump();
    return ctrl;
  }

  testWidgets('typing English, a capital and a space lands in the field', (t) async {
    final ctrl = await open(t);
    await t.tap(find.byKey(const Key('osk-shift')));
    await t.pump();
    await t.tap(find.byKey(const Key('osk-N')));
    // Shift is for one letter, as on a phone.
    await t.pump();
    await t.tap(find.byKey(const Key('osk-o')));
    await t.tap(find.byKey(const Key('osk-space')));
    await t.tap(find.byKey(const Key('osk-2')));
    await t.pump();

    expect(ctrl.text, 'No 2');
  });

  testWidgets('switching to Arabic types Arabic, and backspace takes one letter',
      (t) async {
    final ctrl = await open(t);
    await t.tap(find.byKey(const Key('osk-language')));
    await t.pump();
    await t.tap(find.byKey(const Key('osk-ب')));
    await t.tap(find.byKey(const Key('osk-د')));
    await t.tap(find.byKey(const Key('osk-و')));
    await t.tap(find.byKey(const Key('osk-ن')));
    await t.pump();
    expect(ctrl.text, 'بدون');

    await t.tap(find.byKey(const Key('osk-backspace')));
    await t.pump();
    expect(ctrl.text, 'بدو');
  });

  testWidgets('a key types where the caret is and keeps the field focused', (t) async {
    final ctrl = await open(t, arabicFirst: false);
    ctrl.value = const TextEditingValue(
        text: 'ac', selection: TextSelection.collapsed(offset: 1));
    await t.tap(find.byKey(const Key('osk-b')));
    await t.pump();

    expect(ctrl.text, 'abc');
    final field = t.widget<EditableText>(find.byType(EditableText));
    expect(field.focusNode.hasFocus, isTrue);
  });

  testWidgets('Done is offered only when there is something to do', (t) async {
    var done = 0;
    await open(t, onDone: () => done++);
    await t.tap(find.byKey(const Key('osk-done')));
    expect(done, 1);

    await open(t);
    expect(find.byKey(const Key('osk-done')), findsNothing);
  });
}
