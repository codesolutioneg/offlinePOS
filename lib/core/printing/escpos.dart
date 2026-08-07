import 'dart:typed_data';

/// Which byte a character becomes on paper, and which table the printer is told
/// to render those bytes with.
///
/// Chosen deliberately rather than left to `latin1`. `latin1.encode` throws on
/// anything outside it, so a euro sign, a smart quote pasted out of a supplier's
/// price list, or a menu item written in Arabic would take the whole receipt down
/// at the moment of encoding. That happens before the spool that exists to make an
/// unprinted receipt recoverable has anything to hold, so the paper trail would
/// vanish with no trace of it ever having existed.
///
/// A character with no byte in the table prints as [EscPos.unmappable] instead.
/// One rune becomes exactly one byte, which is what keeps the column arithmetic in
/// [EscPos.row] and [EscPos.centred] honest.
class EscPosCodePage {
  EscPosCodePage({
    required this.id,
    required this.name,
    required Map<int, int> high,
  }) : _high = Map.unmodifiable(high);

  /// Latin-1 in the high half with [extra] overlaid, which is the shape of most
  /// single-byte printer tables used in Europe.
  factory EscPosCodePage.latin1Based({
    required int id,
    required String name,
    Map<int, int> extra = const {},
  }) =>
      EscPosCodePage(
        id: id,
        name: name,
        high: {
          for (var b = 0xa0; b <= 0xff; b++) b: b,
          ...extra,
        },
      );

  /// The `n` in `ESC t n`.
  final int id;

  final String name;

  final Map<int, int> _high;

  /// Windows-1252: Latin-1 plus the printable block at 0x80-0x9f, which is where
  /// the euro sign and typographic punctuation live. The usual default on a
  /// European thermal printer, and the reason it is the default here.
  static final EscPosCodePage windows1252 = EscPosCodePage.latin1Based(
    id: 16,
    name: 'WPC1252',
    extra: {
      0x20ac: 0x80, // €
      0x201a: 0x82, 0x0192: 0x83, 0x201e: 0x84, 0x2026: 0x85,
      0x2020: 0x86, 0x2021: 0x87, 0x02c6: 0x88, 0x2030: 0x89,
      0x0160: 0x8a, 0x2039: 0x8b, 0x0152: 0x8c, 0x017d: 0x8e,
      0x2018: 0x91, 0x2019: 0x92, // ‘ ’
      0x201c: 0x93, 0x201d: 0x94, // “ ”
      0x2022: 0x95,
      0x2013: 0x96, 0x2014: 0x97, // – —
      0x02dc: 0x98, 0x2122: 0x99, 0x0161: 0x9a, 0x203a: 0x9b,
      0x0153: 0x9c, 0x017e: 0x9e, 0x0178: 0x9f,
    },
  );

  /// The byte [rune] prints as, or null if this table has no room for it.
  int? byteFor(int rune) => rune < 0x80 ? rune : _high[rune];

  /// Never throws. Anything this table cannot carry becomes [fallback].
  List<int> encode(String text, {required int fallback}) => [
        for (final rune in text.runes) byteFor(rune) ?? fallback,
      ];
}

/// ESC/POS command builder.
///
/// Receipts are sent to the printer as text and control codes, never as an image.
/// Odoo rasterises its receipt through html-to-image, which costs the better part of
/// a second per print and inlines several megabytes of font data every time. Sending
/// bytes takes as long as the printer takes and nothing more.
///
/// Deliberately dependency-free so it is fully unit-testable and adds nothing to the
/// supply chain.
class EscPos {
  EscPos({this.columns = 42, EscPosCodePage? codePage})
      : codePage = codePage ?? EscPosCodePage.windows1252;

  /// Characters per line. 42 for 80mm paper, 32 for 58mm.
  final int columns;

  /// A shop selling in a script this cannot carry changes the table here and on
  /// the printer together; the two have to agree or the paper is gibberish.
  final EscPosCodePage codePage;

  final BytesBuilder _out = BytesBuilder();

  /// What a character with no byte in [codePage] prints as. A visibly wrong
  /// character on one line is recoverable; an exception loses the whole receipt.
  static const int unmappable = 0x3f; // '?'

  // ── control codes ────────────────────────────────────────────────
  static const int _esc = 0x1b;
  static const int _gs = 0x1d;
  static const int _lf = 0x0a;

  EscPos reset() {
    _out.add([_esc, 0x40]); // ESC @
    // Stated, not assumed. The table a printer defaults to varies by model, and
    // getting it wrong means every byte above 0x7f prints as something else.
    _out.add([_esc, 0x74, codePage.id]); // ESC t n
    return this;
  }

  EscPos align(EscPosAlign a) {
    _out.add([_esc, 0x61, a.index]); // ESC a n
    return this;
  }

  EscPos bold(bool on) {
    _out.add([_esc, 0x45, on ? 1 : 0]); // ESC E n
    return this;
  }

  /// Double width and/or height. ESC ! n with bits 4 (height) and 5 (width).
  EscPos size({bool doubleWidth = false, bool doubleHeight = false}) {
    var n = 0;
    if (doubleHeight) n |= 0x10;
    if (doubleWidth) n |= 0x20;
    _out.add([_esc, 0x21, n]);
    return this;
  }

  EscPos text(String s) {
    _out.add(codePage.encode(s, fallback: unmappable));
    return this;
  }

  EscPos line([String s = '']) {
    text(s);
    _out.addByte(_lf);
    return this;
  }

  EscPos feed([int lines = 1]) {
    for (var i = 0; i < lines; i++) {
      _out.addByte(_lf);
    }
    return this;
  }

  /// A label on the left and an amount on the right, padded to [columns].
  ///
  /// The label is truncated rather than wrapped so the amount never slips onto its
  /// own line and become unreadable on a narrow roll.
  EscPos row(String label, String amount) {
    final space = columns - amount.length;
    if (space <= 0) return line(amount);
    // Truncate to space - 1 so at least one blank separates label from amount,
    // then pad back out to `space` so the amount still ends flush right.
    final left = (label.length > space - 1 ? label.substring(0, space - 1) : label)
        .padRight(space);
    return line('$left$amount');
  }

  EscPos rule([String char = '-']) => line(char * columns);

  /// Centre without relying on printer alignment, so it survives being logged
  /// or shown on screen as plain text.
  EscPos centred(String s) {
    if (s.length >= columns) return line(s);
    final pad = (columns - s.length) ~/ 2;
    return line(' ' * pad + s);
  }

  EscPos cut() {
    _out.add([_gs, 0x56, 0x42, 0x00]); // GS V B 0, feed and full cut
    return this;
  }

  EscPos openDrawer() {
    _out.add([_esc, 0x70, 0x00, 0x19, 0xfa]); // ESC p 0 t1 t2
    return this;
  }

  Uint8List build() => _out.toBytes();
}

enum EscPosAlign { left, center, right }
