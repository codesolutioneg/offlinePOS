import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/export/pdf_fonts.dart';
import 'package:pdf/pdf.dart';

/// The bundled faces, read the way the exporter reads them.
///
/// The joined-form table in the exporter is written for these two files. If the
/// shop's font is ever changed, this is what says whether the new one still needs
/// the table and whether the table is still enough: a shape with no glyph behind
/// it is drawn as nothing at all, which is a letter quietly missing from a dish
/// name rather than an error anyone would see.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// The two code points in the joined-forms block that are not a letter or a
  /// mark, so no font carries them and no shaper ever asks for one: a piece of a
  /// tail, and an unassigned slot.
  const notLetters = {0xfe73, 0xfe75};

  for (final face in ['Cairo-Regular', 'Cairo-Bold']) {
    test('$face can draw every joined Arabic form once the gaps are filled',
        () async {
      final glyphs =
          TtfParser(await rootBundle.load('assets/fonts/$face.ttf'))
              .charToGlyphIndexMap;

      // The gap this is all for. Cairo has the letter and not the standalone
      // form of it, which is the shape the pdf package asks for at the end of a
      // word like كشري.
      expect(glyphs.containsKey(0xfef1), isFalse,
          reason: 'the face grew the form on its own; the table can shrink');

      fillJoinedForms(glyphs);

      expect(glyphs[0xfef1], glyphs[0x064a]);
      final missing = [
        for (var c = 0xfe70; c <= 0xfefc; c++)
          if (!notLetters.contains(c) && (glyphs[c] ?? 0) == 0)
            c.toRadixString(16),
      ];
      expect(missing, isEmpty,
          reason: 'these shapes would print as nothing: add them to the table');
    });
  }

  test('a face that draws its own forms is left alone', () {
    // Only gaps are filled, so a font with a real standalone yeh of its own keeps
    // it rather than being pointed at the plain letter.
    final glyphs = {0x064a: 11, 0xfef1: 22};
    fillJoinedForms(glyphs);
    expect(glyphs[0xfef1], 22);
  });
}
