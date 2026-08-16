/// The Arabic answer for anything the till exports as a PDF.
///
/// The pdf package draws in Helvetica unless it is told otherwise, and Helvetica
/// carries no Arabic glyph at all: a report with a dish name in it came out blank
/// where the name should be, and the only sign was a line in the build log saying
/// "Helvetica has no Unicode support". Two things fix it, and both have to be
/// done. The document needs a font that has the glyphs, and the text needs to be
/// marked right-to-left, because the package only runs its bidirectional pass on
/// text that says it is.
///
/// The font is the one already carried for the printer (see pubspec.yaml), so
/// paper and PDF come out of the same two files and nothing is fetched at export
/// time. A till in a shop has no internet to download a web font from, and an
/// export that waits on one is an export that fails at the wrong moment.
library;

import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

pw.ThemeData? _theme;
Future<pw.ThemeData?>? _loading;

/// A document theme whose base, bold and italic faces are the bundled Cairo, or
/// null when the asset cannot be read.
///
/// Read once per process and shared: a manager who downloads five reports pays
/// for one read of the font, and the concurrent callers share the one future.
///
/// Null on failure rather than a throw. A missing asset means a broken build, not
/// a broken shop, and a report that saves in the wrong typeface still beats an
/// export that dies in a cashier's hands.
Future<pw.ThemeData?> unicodePdfTheme() async {
  final ready = _theme;
  if (ready != null) return ready;
  return _loading ??= _load();
}

Future<pw.ThemeData?> _load() async {
  try {
    final base = _ShapedFont(await rootBundle.load('assets/fonts/Cairo-Regular.ttf'));
    final bold = _ShapedFont(await rootBundle.load('assets/fonts/Cairo-Bold.ttf'));
    // Italic and bold-italic are given the upright cuts on purpose. Cairo ships no
    // italic, and leaving those slots empty puts Helvetica back in the document the
    // moment any widget asks for one, which is the bug coming back by a side door.
    return _theme = pw.ThemeData.withFont(
      base: base,
      bold: bold,
      italic: base,
      boldItalic: bold,
    );
  } catch (_) {
    return null;
  } finally {
    _loading = null;
  }
}

/// The bundled font with the joined letter forms it is missing filled in.
///
/// Before it draws Arabic the pdf package joins the letters, which turns each one
/// into the shape it takes in its position in the word, and then asks the font for
/// that shape by its own code point. Cairo does not carry a glyph under every one
/// of those code points, and a shape the font has no glyph for is drawn as
/// nothing: 'كشري' lost its last letter and came out as 'كشر', silently, with the
/// table around it perfectly correct. Filling the gap in is the fix, because the
/// shape is not actually missing from the font, only that way of naming it.
class _ShapedFont extends pw.TtfFont {
  _ShapedFont(super.data);

  @override
  PdfFont buildFont(PdfDocument document) {
    final font = super.buildFont(document);
    if (font is PdfTtfFont) fillJoinedForms(font.font.charToGlyphIndexMap);
    return font;
  }
}

/// Points every joined form in [glyphs] that the font has no glyph of its own for
/// at the plain letter's glyph, which is the same drawing.
///
/// Only fills gaps: a font that draws its own joined shapes keeps them.
void fillJoinedForms(Map<int, int> glyphs) {
  for (final MapEntry(key: form, value: letter) in _joinedFormLetters.entries) {
    final glyph = glyphs[letter];
    if (glyph != null && !glyphs.containsKey(form)) glyphs[form] = glyph;
  }
}

/// Joined form to the plain letter it is a form of, for the forms the bundled
/// faces are missing: the eight marks that sit above and below a letter, in both
/// the standalone and the on-a-letter shape, and the standalone yeh, which ends
/// any Egyptian dish name whose second-to-last letter does not join forwards.
///
/// Not the whole of the Unicode block, which runs to some hundreds and would be a
/// table nobody could check. What is here is what these two files need, and a test
/// asserts that: if the shop's font is ever changed, that test says which shapes
/// the new one is short of.
const Map<int, int> _joinedFormLetters = {
  0xfe70: 0x064b, // fathatan
  0xfe71: 0x064b,
  0xfe72: 0x064c, // dammatan
  0xfe74: 0x064d, // kasratan
  0xfe76: 0x064e, // fatha
  0xfe77: 0x064e,
  0xfe78: 0x064f, // damma
  0xfe79: 0x064f,
  0xfe7a: 0x0650, // kasra
  0xfe7b: 0x0650,
  0xfe7c: 0x0651, // shadda
  0xfe7d: 0x0651,
  0xfe7e: 0x0652, // sukun
  0xfe7f: 0x0652,
  0xfef1: 0x064a, // yeh, standing alone
};

/// True when any of [texts] holds a character the built-in Latin fonts cannot
/// draw, and the document therefore has to carry a font of its own.
///
/// Everything below U+0100 is inside their encoding, which is every report the
/// shop exported before Arabic names arrived. Those keep the small file they have
/// today rather than growing an embedded typeface they never use.
bool pdfNeedsEmbeddedFont(Iterable<String> texts) =>
    texts.any((s) => s.runes.any((r) => r >= 0x100));

/// True when [s] holds a right-to-left letter.
///
/// The printer's rasteriser answers the same question for its own layer, in its
/// own class, and this one is deliberately not routed through it: that file pulls
/// in Flutter's painting stack for the canvas it draws on, and an exporter that
/// only writes bytes should not.
bool pdfIsRightToLeft(String s) => s.runes.any(_rightToLeft);

bool _rightToLeft(int r) =>
    (r >= 0x0590 && r <= 0x08ff) || (r >= 0xfb1d && r <= 0xfeff);
