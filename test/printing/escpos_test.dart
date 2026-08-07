import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/printing/escpos.dart';

import 'strip_escpos.dart';

void main() {
  test('starts with a printer reset', () {
    final b = EscPos().reset().build();
    expect(b.sublist(0, 2), [0x1b, 0x40]);
  });

  test('a row pads the label so the amount ends flush right', () {
    final s = strippedText(EscPos(columns: 20).row('Pizza', '250.00').build());
    expect(s.trimRight().length, 20);
    expect(s.endsWith('250.00\n'), isTrue);
  });

  test('a long label is truncated so the amount never wraps', () {
    final s = strippedText(
        EscPos(columns: 20).row('A' * 40, '9.99').build());
    expect(s.split('\n').first.length, 20);
    expect(s.trimRight().endsWith('9.99'), isTrue);
  });

  test('rules span the paper width', () {
    final s = strippedText(EscPos(columns: 32).rule().build());
    expect(s.trimRight().length, 32);
  });

  test('centring is symmetric', () {
    final s = strippedText(EscPos(columns: 11).centred('abc').build());
    expect(s, '    abc\n');
  });

  test('cut is a full cut with feed', () {
    final b = EscPos().cut().build();
    expect(b, [0x1d, 0x56, 0x42, 0x00]);
  });

  test('nothing is rasterised: output is bytes, not an image', () {
    final b = EscPos().line('hello').build();
    expect(b.length, lessThan(64));
  });

  group('no character can lose a receipt', () {
    test('the code page is told to the printer rather than assumed', () {
      // Without this the printer renders every byte above 0x7f with whatever
      // table it happened to boot with, so a euro sign is a lottery.
      expect(EscPos().reset().build(), [0x1b, 0x40, 0x1b, 0x74, 16]);
    });

    test('a euro price and typographic punctuation print', () {
      final b = EscPos().line('Café 3€ — don’t').build();
      expect(b, contains(0x80), reason: 'the euro sign');
      expect(b, contains(0x97), reason: 'the em dash');
      expect(b, contains(0x92), reason: 'the right single quote');
    });

    test('a name in a script the code page cannot carry still yields a receipt',
        () {
      // The old behaviour threw, and it threw before the spool had anything to
      // hold, so the sale was taken and the paper trail vanished with nothing
      // anywhere recording that a receipt had ever been due. Illegible beats
      // absent.
      expect(strippedText(EscPos().line('شاي').build()), '???\n');
    });

    test('one character is one byte, so a column width still means something',
        () {
      final s = strippedText(EscPos(columns: 20).row('Café €', '9.99').build());
      expect(s.trimRight().length, 20);
      expect(s.trimRight().endsWith('9.99'), isTrue);
    });
  });
}
