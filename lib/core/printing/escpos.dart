import 'dart:convert';
import 'dart:typed_data';

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
  EscPos({this.columns = 42, Encoding? encoding})
      : _encoding = encoding ?? latin1;

  /// Characters per line. 42 for 80mm paper, 32 for 58mm.
  final int columns;
  final Encoding _encoding;
  final BytesBuilder _out = BytesBuilder();

  // ── control codes ────────────────────────────────────────────────
  static const int _esc = 0x1b;
  static const int _gs = 0x1d;
  static const int _lf = 0x0a;

  EscPos reset() {
    _out.add([_esc, 0x40]); // ESC @
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
    _out.add(_encoding.encode(s));
    return this;
  }

  EscPos line([String s = '']) {
    _out.add(_encoding.encode(s));
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
