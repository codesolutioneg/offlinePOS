import 'dart:io';

/// Reads an exported PDF the way a viewer would, so a test can assert what the
/// page actually says rather than that the exporter returned without throwing.
///
/// A PDF draws text as glyph numbers into an embedded font, so neither the words
/// nor the letters appear anywhere in the file as themselves. What the document
/// does carry, for every font it embeds, is the character map a reader needs to
/// copy text back out of it: glyph number to Unicode. That map is the page's own
/// account of which characters it drew, and running the drawn glyph numbers back
/// through it gives the runs of text on the page in the order they were laid
/// down. Both are read here, which is the only way to tell an Arabic report from
/// a page of blanks.
///
/// Deliberately small: enough of the format to answer those two questions on a
/// document this app produced, and nothing like a general parser.
class PdfBytes {
  PdfBytes(List<int> bytes) : _text = String.fromCharCodes(bytes) {
    _readObjects(bytes);
  }

  final String _text;

  /// Object number to the text of its dictionary.
  final Map<int, String> _dicts = {};

  /// Object number to its stream, already inflated where it was compressed.
  final Map<int, String> _streams = {};

  bool get isPdf => _text.startsWith('%PDF');

  /// True when the document carries a font of its own rather than leaning on one
  /// of the reader's built-in Latin faces.
  bool get embedsFontFile => _text.contains('/FontFile2');

  Iterable<String> get baseFonts => RegExp(r'/BaseFont\s*/([^\s/>\]]+)')
      .allMatches(_text)
      .map((m) => m.group(1)!)
      .toSet();

  bool mentions(String needle) => _text.contains(needle);

  /// Every Unicode character the document's fonts were asked to carry.
  Set<int> get mappedCharacters => {
        for (final cmap in _characterMaps.values) ...cmap.values,
      }..remove(0);

  /// The runs of text on the page, in the order they were drawn, decoded back
  /// through the font each was drawn in.
  ///
  /// A run is one positioned piece of text: a cell, or a word of a cell where the
  /// layout placed the words itself. Reading them back is what proves an amount
  /// beside an Arabic name is still the amount and not its own reverse.
  List<String> get drawnRuns {
    final runs = <String>[];
    for (final page in RegExp(r'/Contents (\d+) 0 R').allMatches(_text)) {
      final content = _streams[int.parse(page.group(1)!)];
      if (content == null) continue;
      Map<int, int>? cmap;
      final token = RegExp(r'/(F\d+) [\d.]+ Tf|\[<([0-9A-Fa-f]+)>\] *TJ');
      for (final m in token.allMatches(content)) {
        final font = m.group(1);
        if (font != null) {
          cmap = _characterMaps[font];
          continue;
        }
        final hex = m.group(2)!;
        final out = StringBuffer();
        for (var i = 0; i + 4 <= hex.length; i += 4) {
          final glyph = int.parse(hex.substring(i, i + 4), radix: 16);
          final code = cmap?[glyph];
          if (code != null && code != 0) out.writeCharCode(code);
        }
        if (out.isNotEmpty) runs.add(out.toString());
      }
    }
    return runs;
  }

  /// Resource name, as the page calls it, to that font's glyph-to-Unicode map.
  Map<String, Map<int, int>> get _characterMaps {
    final maps = <String, Map<int, int>>{};
    for (final entry in _dicts.entries) {
      final name = RegExp(r'/Name\s*/(F\d+)').firstMatch(entry.value);
      final unicode = RegExp(r'/ToUnicode (\d+) 0 R').firstMatch(entry.value);
      if (name == null || unicode == null) continue;
      final cmap = _streams[int.parse(unicode.group(1)!)];
      if (cmap == null) continue;
      maps[name.group(1)!] = {
        for (final m in RegExp(r'<([0-9A-Fa-f]{4})> <([0-9A-Fa-f]{4})>')
            .allMatches(cmap))
          int.parse(m.group(1)!, radix: 16): int.parse(m.group(2)!, radix: 16),
      };
    }
    return maps;
  }

  void _readObjects(List<int> bytes) {
    for (final m in RegExp(r'(\d+) 0 obj').allMatches(_text)) {
      final number = int.parse(m.group(1)!);
      final head = _text.indexOf('endobj', m.end);
      final open = _text.indexOf('stream', m.end);
      final dictEnd = open >= 0 && (head < 0 || open < head) ? open : head;
      if (dictEnd < 0) continue;
      final dict = _text.substring(m.end, dictEnd);
      _dicts[number] = dict;
      if (dictEnd != open) continue;

      // The dictionary says exactly how many bytes the stream is, which beats
      // hunting for the end of something that may hold any byte at all.
      final length = RegExp(r'/Length (\d+)').firstMatch(dict);
      if (length == null) continue;
      var start = open + 'stream'.length;
      if (start < bytes.length && bytes[start] == 0x0d) start++;
      if (start < bytes.length && bytes[start] == 0x0a) start++;
      final end = start + int.parse(length.group(1)!);
      if (end > bytes.length) continue;
      var raw = bytes.sublist(start, end);
      if (dict.contains('/FlateDecode')) {
        try {
          raw = ZLibCodec().decode(raw);
        } catch (_) {
          continue;
        }
      }
      _streams[number] = String.fromCharCodes(raw);
    }
  }
}
