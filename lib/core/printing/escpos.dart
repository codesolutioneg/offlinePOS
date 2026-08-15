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

  /// Windows-1256, the Arabic table. `ESC t 49` on the Epson table list every
  /// generic thermal printer clones, and the fast path for a printer that has it:
  /// the firmware does the joining, one rune stays one byte, and nothing is
  /// rendered. A printer without it prints gibberish for these bytes, which is why
  /// this is chosen per shop on the printers screen rather than assumed.
  ///
  /// Spelled out in full rather than layered over Latin-1: 1256 puts Arabic letters
  /// where Latin-1 keeps accented vowels, so an identity high half would print
  /// `lam` for every `á`.
  static final EscPosCodePage windows1256 = EscPosCodePage(
    id: 49,
    name: 'WPC1256',
    high: {
      0x20ac: 0x80, 0x067e: 0x81, 0x201a: 0x82, 0x0192: 0x83, 0x201e: 0x84,
      0x2026: 0x85, 0x2020: 0x86, 0x2021: 0x87, 0x02c6: 0x88, 0x2030: 0x89,
      0x0679: 0x8a, 0x2039: 0x8b, 0x0152: 0x8c, 0x0686: 0x8d, 0x0698: 0x8e,
      0x0688: 0x8f, 0x06af: 0x90, 0x2018: 0x91, 0x2019: 0x92, 0x201c: 0x93,
      0x201d: 0x94, 0x2022: 0x95, 0x2013: 0x96, 0x2014: 0x97, 0x06a9: 0x98,
      0x2122: 0x99, 0x0691: 0x9a, 0x203a: 0x9b, 0x0153: 0x9c, 0x200c: 0x9d,
      0x200d: 0x9e, 0x06ba: 0x9f, 0x00a0: 0xa0, 0x060c: 0xa1, 0x00a2: 0xa2,
      0x00a3: 0xa3, 0x00a4: 0xa4, 0x00a5: 0xa5, 0x00a6: 0xa6, 0x00a7: 0xa7,
      0x00a8: 0xa8, 0x00a9: 0xa9, 0x06be: 0xaa, 0x00ab: 0xab, 0x00ac: 0xac,
      0x00ad: 0xad, 0x00ae: 0xae, 0x00af: 0xaf, 0x00b0: 0xb0, 0x00b1: 0xb1,
      0x00b2: 0xb2, 0x00b3: 0xb3, 0x00b4: 0xb4, 0x00b5: 0xb5, 0x00b6: 0xb6,
      0x00b7: 0xb7, 0x00b8: 0xb8, 0x00b9: 0xb9, 0x061b: 0xba, 0x00bb: 0xbb,
      0x00bc: 0xbc, 0x00bd: 0xbd, 0x00be: 0xbe, 0x061f: 0xbf, 0x06c1: 0xc0,
      0x0621: 0xc1, 0x0622: 0xc2, 0x0623: 0xc3, 0x0624: 0xc4, 0x0625: 0xc5,
      0x0626: 0xc6, 0x0627: 0xc7, 0x0628: 0xc8, 0x0629: 0xc9, 0x062a: 0xca,
      0x062b: 0xcb, 0x062c: 0xcc, 0x062d: 0xcd, 0x062e: 0xce, 0x062f: 0xcf,
      0x0630: 0xd0, 0x0631: 0xd1, 0x0632: 0xd2, 0x0633: 0xd3, 0x0634: 0xd4,
      0x0635: 0xd5, 0x0636: 0xd6, 0x00d7: 0xd7, 0x0637: 0xd8, 0x0638: 0xd9,
      0x0639: 0xda, 0x063a: 0xdb, 0x0640: 0xdc, 0x0641: 0xdd, 0x0642: 0xde,
      0x0643: 0xdf, 0x00e0: 0xe0, 0x0644: 0xe1, 0x00e2: 0xe2, 0x0645: 0xe3,
      0x0646: 0xe4, 0x0647: 0xe5, 0x0648: 0xe6, 0x00e7: 0xe7, 0x00e8: 0xe8,
      0x00e9: 0xe9, 0x00ea: 0xea, 0x00eb: 0xeb, 0x0649: 0xec, 0x064a: 0xed,
      0x00ee: 0xee, 0x00ef: 0xef, 0x064b: 0xf0, 0x064c: 0xf1, 0x064d: 0xf2,
      0x064e: 0xf3, 0x00f4: 0xf4, 0x064f: 0xf5, 0x0650: 0xf6, 0x00f7: 0xf7,
      0x0651: 0xf8, 0x00f9: 0xf9, 0x0652: 0xfa, 0x00fb: 0xfb, 0x00fc: 0xfc,
      0x200e: 0xfd, 0x200f: 0xfe, 0x06d2: 0xff,
    },
  );

  /// The tables a manager can pick between, by the key stored on the device.
  static final Map<String, EscPosCodePage> byKey = {
    'wpc1252': windows1252,
    'wpc1256': windows1256,
  };

  /// The byte [rune] prints as, or null if this table has no room for it.
  int? byteFor(int rune) => rune < 0x80 ? rune : _high[rune];

  /// True when this table cannot carry every rune in [text], so the line has to be
  /// rendered as an image or printed as fallback characters.
  bool carriesAll(String text) => !text.runes.any((r) => byteFor(r) == null);

  /// Never throws. Anything this table cannot carry becomes [fallback].
  List<int> encode(String text, {required int fallback}) => [
        for (final rune in text.runes) byteFor(rune) ?? fallback,
      ];
}

/// The two printing choices the receipt layouts cannot pass in.
///
/// [ReceiptBuilder] and [KitchenTicketBuilder] construct an [EscPos] deep inside a
/// layout with nothing but a column count, and the printing layer is deliberately
/// free of the database, so the shop's table and its Arabic preference are published
/// here once by [SettingsStore] instead of being threaded through every builder.
class EscPosPrintProfile {
  EscPosPrintProfile({EscPosCodePage? codePage, this.rasterUnmappable = true})
      : codePage = codePage ?? EscPosCodePage.windows1252;

  /// Replaced whole rather than mutated, so a reader either sees the old pair or
  /// the new one and never a half-applied change.
  static EscPosPrintProfile shared = EscPosPrintProfile();

  final EscPosCodePage codePage;

  /// Render a line the table cannot carry instead of printing fallback characters.
  /// On unless a shop turns it off: it costs a Latin receipt nothing, because no
  /// line of one has a rune the table is missing.
  final bool rasterUnmappable;
}

/// A line to be rendered, described by everything that changes its pixels.
///
/// [right] is the amount column of a [EscPos.row]: it is rendered flush right in
/// its own paint rather than reached by padding, because a rendered line is set in
/// a proportional font where padding spaces align nothing.
class RasterRequest {
  const RasterRequest({
    required this.text,
    required this.dots,
    this.right,
    this.bold = false,
    this.doubleWidth = false,
    this.doubleHeight = false,
    this.align = EscPosAlign.left,
  });

  final String text;
  final String? right;

  /// Printable width of the band in printer dots.
  final int dots;

  final bool bold;
  final bool doubleWidth;
  final bool doubleHeight;
  final EscPosAlign align;

  @override
  bool operator ==(Object other) =>
      other is RasterRequest &&
      other.text == text &&
      other.right == right &&
      other.dots == dots &&
      other.bold == bold &&
      other.doubleWidth == doubleWidth &&
      other.doubleHeight == doubleHeight &&
      other.align == align;

  @override
  int get hashCode =>
      Object.hash(text, right, dots, bold, doubleWidth, doubleHeight, align);
}

/// A rendered line: one bit per dot, rows top to bottom, most significant bit
/// leftmost, which is the layout `GS v 0` expects.
class RasterBand {
  RasterBand({
    required this.widthDots,
    required this.heightDots,
    required this.bits,
  });

  final int widthDots;
  final int heightDots;
  final Uint8List bits;

  int get widthBytes => widthDots ~/ 8;

  /// `GS v 0` raster bit image, mode 0 (normal density).
  Uint8List command() {
    final out = BytesBuilder()
      ..add([
        0x1d, 0x76, 0x30, 0x00,
        widthBytes & 0xff, (widthBytes >> 8) & 0xff,
        heightDots & 0xff, (heightDots >> 8) & 0xff,
      ])
      ..add(bits);
    return out.toBytes();
  }
}

/// Where a deferred line sits in a built document: [start] to [end] is the byte
/// range holding the fallback text it stands in for.
class EscPosDeferredLine {
  EscPosDeferredLine({
    required this.start,
    required this.end,
    required this.request,
  });

  final int start;
  final int end;
  final RasterRequest request;
}

/// The lines a document could not carry as bytes, kept beside the bytes that stand
/// in for them until the send path can render them.
///
/// Why a side table and not a marker inside the byte stream: what [EscPos.build]
/// returns is a complete, valid receipt on its own, with the offending line printed
/// as fallback characters exactly as before this existed. A caller that never
/// resolves it prints today's paper, and no invented byte can ever reach a printer.
///
/// Keyed by what the document says, not by which buffer holds it: a kitchen ticket
/// is copied into a fresh list on its way to a station, and a copy has to resolve
/// the same way the original would. Two copies of one receipt share an entry, which
/// is right, because they want the same bands.
class EscPosDeferredDocs {
  static final EscPosDeferredDocs shared = EscPosDeferredDocs();

  final Map<String, List<EscPosDeferredLine>> _docs = {};
  final List<String> _order = [];

  /// A cash sale prints at most a receipt, its copies and a ticket per station at
  /// once, so a short window is enough and nothing accumulates over a shift.
  static const int keep = 8;

  /// True while no document is waiting, which is the whole life of a Latin till and
  /// the reason the send path costs it nothing.
  bool get isEmpty => _docs.isEmpty;

  void record(Uint8List bytes, List<EscPosDeferredLine> lines) {
    if (lines.isEmpty) return;
    final key = _keyOf(bytes);
    if (!_docs.containsKey(key)) _order.add(key);
    _docs[key] = List.unmodifiable(lines);
    while (_order.length > keep) {
      _docs.remove(_order.removeAt(0));
    }
  }

  /// Non-destructive on purpose: a kitchen ticket that fails at its station is sent
  /// again through the receipt printer, and the second attempt needs the same lines.
  List<EscPosDeferredLine>? operator [](Uint8List bytes) =>
      _docs.isEmpty ? null : _docs[_keyOf(bytes)];

  void clear() {
    _docs.clear();
    _order.clear();
  }

  static String _keyOf(Uint8List bytes) => String.fromCharCodes(bytes);
}

/// ESC/POS command builder.
///
/// Receipts are sent to the printer as text and control codes, never as an image.
/// Odoo rasterises its receipt through html-to-image, which costs the better part of
/// a second per print and inlines several megabytes of font data every time. Sending
/// bytes takes as long as the printer takes and nothing more.
///
/// The one exception is a line carrying runes [codePage] has no byte for, an Arabic
/// dish name on a Latin table above all. That line alone is rendered, the rest of the
/// receipt stays bytes, and a Latin receipt is byte for byte what it always was.
///
/// Rendering needs Flutter text layout, which is asynchronous, while every builder
/// here is synchronous and is called from a print helper a sale never awaits. So
/// this file only marks the offending line: [build] emits the fallback text as
/// before and records the byte range in [EscPosDeferredDocs], and the send path
/// swaps in the rendered band on its way to the wire, where an await is already the
/// norm. Nothing on a selling path can wait for a picture, and a render that fails
/// or times out costs the line its script, never the receipt.
///
/// Deliberately free of Flutter and of the database so it is fully unit-testable and
/// adds nothing to the supply chain.
class EscPos {
  EscPos({
    this.columns = 42,
    EscPosCodePage? codePage,
    bool? rasterUnmappable,
    int? dotsPerLine,
  })  : codePage = codePage ?? EscPosPrintProfile.shared.codePage,
        rasterUnmappable =
            rasterUnmappable ?? EscPosPrintProfile.shared.rasterUnmappable,
        // Rounded down to whole bytes because that is the unit GS v 0 counts a
        // raster row in.
        dotsPerLine = (dotsPerLine ?? columns * dotsPerColumn) & ~7;

  /// Characters per line. 42 for 80mm paper, 32 for 58mm.
  final int columns;

  /// A shop selling in a script this cannot carry changes the table here and on
  /// the printer together; the two have to agree or the paper is gibberish.
  final EscPosCodePage codePage;

  /// Render a line this table cannot carry rather than print fallback characters.
  final bool rasterUnmappable;

  /// How wide a rendered line may be, in printer dots. The font A cell is 12 dots
  /// across on every printer this app talks to, so the text area a column count
  /// describes is that count of cells.
  static const int dotsPerColumn = 12;

  final int dotsPerLine;

  final BytesBuilder _out = BytesBuilder();

  final List<EscPosDeferredLine> _deferred = [];

  // Printer state as this document has set it so far, so a rendered band carries the
  // weight, size and alignment the same line would have had as bytes.
  bool _bold = false;
  bool _doubleWidth = false;
  bool _doubleHeight = false;
  EscPosAlign _align = EscPosAlign.left;

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
    _bold = false;
    _doubleWidth = false;
    _doubleHeight = false;
    _align = EscPosAlign.left;
    return this;
  }

  EscPos align(EscPosAlign a) {
    _out.add([_esc, 0x61, a.index]); // ESC a n
    _align = a;
    return this;
  }

  EscPos bold(bool on) {
    _out.add([_esc, 0x45, on ? 1 : 0]); // ESC E n
    _bold = on;
    return this;
  }

  /// Double width and/or height. ESC ! n with bits 4 (height) and 5 (width).
  EscPos size({bool doubleWidth = false, bool doubleHeight = false}) {
    var n = 0;
    if (doubleHeight) n |= 0x10;
    if (doubleWidth) n |= 0x20;
    _out.add([_esc, 0x21, n]);
    _doubleWidth = doubleWidth;
    _doubleHeight = doubleHeight;
    return this;
  }

  /// A fragment, with no line end. Never rendered: a band replaces a whole line, and
  /// half a line is not enough to lay one out.
  EscPos text(String s) {
    _out.add(codePage.encode(s, fallback: unmappable));
    return this;
  }

  EscPos line([String s = '']) => _emit(s);

  /// Writes [printed] as bytes with a line end, and when the line carries runes the
  /// table has no byte for, records the range so the send path can put a rendered
  /// band in its place. [rasterText] and [rasterRight] are what that band should
  /// say, which is not always what the byte line says: padding that aligns a column
  /// in a fixed-width table means nothing in a rendered one.
  EscPos _emit(
    String printed, {
    String? rasterText,
    String? rasterRight,
    EscPosAlign? rasterAlign,
  }) {
    final start = _out.length;
    _out.add(codePage.encode(printed, fallback: unmappable));
    _out.addByte(_lf);
    if (!rasterUnmappable) return this;
    final left = rasterText ?? printed;
    if (codePage.carriesAll(left) &&
        (rasterRight == null || codePage.carriesAll(rasterRight))) {
      return this;
    }
    _deferred.add(EscPosDeferredLine(
      start: start,
      end: _out.length,
      request: RasterRequest(
        text: left,
        right: rasterRight,
        dots: dotsPerLine,
        bold: _bold,
        doubleWidth: _doubleWidth,
        doubleHeight: _doubleHeight,
        align: rasterAlign ?? _align,
      ),
    ));
    return this;
  }

  /// A whole command this builder does not compose itself, above all the shop's
  /// logo (see PrinterLogo). Deliberately not a general escape hatch: it takes
  /// finished bytes and never text, so nothing can slip past [codePage] through it,
  /// and the column arithmetic is untouched because a command draws no characters.
  EscPos command(List<int> bytes) {
    _out.add(bytes);
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
    // A rendered row is given both halves untruncated: it sets the label to fit and
    // keeps the amount flush right, so a long Arabic dish name loses nothing.
    return _emit('$left$amount', rasterText: label, rasterRight: amount);
  }

  EscPos rule([String char = '-']) => line(char * columns);

  /// Centre without relying on printer alignment, so it survives being logged
  /// or shown on screen as plain text.
  EscPos centred(String s) {
    if (s.length >= columns) return line(s);
    final pad = (columns - s.length) ~/ 2;
    // The padding is for the byte line only; a rendered band is centred by layout.
    return _emit(' ' * pad + s, rasterText: s, rasterAlign: EscPosAlign.center);
  }

  EscPos cut() {
    _out.add([_gs, 0x56, 0x42, 0x00]); // GS V B 0, feed and full cut
    return this;
  }

  EscPos openDrawer() {
    _out.add([_esc, 0x70, 0x00, 0x19, 0xfa]); // ESC p 0 t1 t2
    return this;
  }

  /// A complete document. Any line the table could not carry is in it as fallback
  /// text and is also filed in [EscPosDeferredDocs] under this exact buffer, so the
  /// send path can render it. Ignoring that file prints what this app always printed.
  Uint8List build() {
    final bytes = _out.toBytes();
    EscPosDeferredDocs.shared.record(bytes, _deferred);
    return bytes;
  }

  /// The lines this document would rather print as an image, in the order they were
  /// written. Empty for anything the code page carries whole.
  List<EscPosDeferredLine> get deferred => List.unmodifiable(_deferred);
}

enum EscPosAlign { left, center, right }
