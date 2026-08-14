import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

import 'escpos.dart';

/// Renders the receipt lines a printer's character table cannot carry.
///
/// This is the Arabic answer. A thermal printer speaks one single-byte table at a
/// time, so an Arabic dish name on a Latin table prints as a row of question marks
/// (see [EscPos]). Here that one line is laid out by Flutter, which shapes and joins
/// the script and orders a mixed line correctly, and comes back as the dots the
/// printer draws. Everything else on the receipt stays bytes.
///
/// Kept out of escpos.dart so that file stays free of Flutter and pure enough to
/// reason about a byte at a time.
class LineRasteriser {
  LineRasteriser({this.fontSize = 20, this.minHeight = 24, this.cacheSize = 64});

  /// The default used by [rasteriseEscPos], so the cache is shared across prints:
  /// a receipt's second copy and its reprint cost nothing to render.
  static LineRasteriser shared = LineRasteriser();

  /// Dots tall. Font A is a 12 by 24 cell, and 20 leaves a little room under the
  /// baseline for the marks Arabic hangs below it.
  final double fontSize;

  /// A band is never shorter than a text line would have been, so a receipt does not
  /// tighten up where it switches from bytes to dots.
  final int minHeight;

  final int cacheSize;

  final Map<RasterRequest, RasterBand> _cache = {};
  final List<RasterRequest> _order = [];

  /// Null when the line cannot be rendered at all, which leaves the fallback text in
  /// place. Never throws: illegible beats absent, and absent is what an exception on
  /// the print path would mean.
  Future<RasterBand?> render(RasterRequest r) async {
    final hit = _cache[r];
    if (hit != null) return hit;
    try {
      final band = await _draw(r);
      if (band != null) _remember(r, band);
      return band;
    } catch (_) {
      return null;
    }
  }

  void _remember(RasterRequest r, RasterBand band) {
    _cache[r] = band;
    _order.add(r);
    while (_order.length > cacheSize) {
      _cache.remove(_order.removeAt(0));
    }
  }

  Future<RasterBand?> _draw(RasterRequest r) async {
    if (r.dots < 8 || r.dots % 8 != 0) return null;
    // Double width is a horizontal stretch on the printer, so it is laid out in half
    // the room and drawn twice as wide rather than set in a wider font.
    final stretch = r.doubleWidth ? 2 : 1;
    final usable = r.dots / stretch;
    final style = TextStyle(
      fontSize: fontSize * (r.doubleHeight ? 2 : 1),
      height: 1.0,
      fontWeight: r.bold ? FontWeight.w700 : FontWeight.w400,
      color: const Color(0xFF000000),
    );

    // The amount is measured at its natural width first, and what is left over is
    // what the label may use, which is how the byte path decides too.
    final right = r.right == null || r.right!.isEmpty
        ? null
        : _painter(r.right!, style, TextAlign.right, usable, snug: true);
    final gap = right == null ? 0.0 : fontSize * 0.4;
    final leftWidth = math.max(usable - (right?.width ?? 0) - gap, fontSize);
    final left = _painter(
      r.text,
      style,
      right != null ? TextAlign.left : _alignment(r.align),
      leftWidth,
    );

    final height = math.max(
      math.max(left.height, right?.height ?? 0).ceil(),
      minHeight * (r.doubleHeight ? 2 : 1),
    );
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    if (stretch != 1) canvas.scale(stretch.toDouble(), 1);
    left.paint(canvas, Offset.zero);
    right?.paint(canvas, Offset(usable - right.width, 0));
    final picture = recorder.endRecording();
    final image = await picture.toImage(r.dots, height);
    picture.dispose();
    try {
      final pixels =
          await image.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
      if (pixels == null) return null;
      return RasterBand(
        widthDots: r.dots,
        heightDots: height,
        bits: _pack(pixels, r.dots, height),
      );
    } finally {
      image.dispose();
    }
  }

  /// One line with an ellipsis, so a long name can never push the amount column onto
  /// paper of its own. Laid out at exactly [width] so the alignment inside it means
  /// something, unless [snug] asks for the text's own width, which is how the amount
  /// column reports how much room it needs.
  TextPainter _painter(
    String s,
    TextStyle style,
    TextAlign align,
    double width, {
    bool snug = false,
  }) =>
      TextPainter(
        text: TextSpan(text: s, style: style),
        textDirection: _directionOf(s),
        textAlign: align,
        maxLines: 1,
        ellipsis: '…',
      )..layout(minWidth: snug ? 0 : width, maxWidth: width);

  static TextAlign _alignment(EscPosAlign a) => switch (a) {
        EscPosAlign.left => TextAlign.left,
        EscPosAlign.center => TextAlign.center,
        EscPosAlign.right => TextAlign.right,
      };

  /// Direction by content, not by the app's language: a receipt from an Arabic shop
  /// still has Latin lines on it, and each has to read the way it was written. The
  /// first strong character decides, which is what the bidirectional algorithm does.
  static TextDirection _directionOf(String s) {
    for (final r in s.runes) {
      if (_isRightToLeft(r)) return TextDirection.rtl;
      if (_isLatinLetter(r)) return TextDirection.ltr;
    }
    return TextDirection.ltr;
  }

  static bool _isRightToLeft(int r) =>
      (r >= 0x0590 && r <= 0x08ff) || (r >= 0xfb1d && r <= 0xfeff);

  static bool _isLatinLetter(int r) =>
      (r >= 0x41 && r <= 0x5a) || (r >= 0x61 && r <= 0x7a) || (r >= 0xc0 && r <= 0x24f);

  /// One bit per dot, rows top to bottom, most significant bit leftmost. A dot is
  /// inked wherever anything was drawn: the threshold sits below half opacity so the
  /// thin edges of a rendered glyph survive as heat rather than disappearing.
  static Uint8List _pack(ByteData pixels, int width, int height) {
    final widthBytes = width ~/ 8;
    final bits = Uint8List(widthBytes * height);
    for (var y = 0; y < height; y++) {
      final row = y * widthBytes;
      for (var x = 0; x < width; x++) {
        final alpha = pixels.getUint8(((y * width) + x) * 4 + 3);
        if (alpha >= 96) bits[row + (x >> 3)] |= 0x80 >> (x & 7);
      }
    }
    return bits;
  }
}

/// Swaps the rendered band in for every line [EscPos] had to print as fallback text.
///
/// Called on the way to the wire, which is the one place an await is free: the sale
/// is long committed, and the print helpers that get here are never awaited by the
/// screen that took the money. [bytes] comes back untouched when the document has
/// nothing deferred, which is every Latin receipt, so the common path costs one map
/// lookup.
///
/// [timeout] is the whole document's budget. A renderer that never answers must cost
/// the paper its script and not the paper itself.
Future<Uint8List> rasteriseEscPos(
  Uint8List bytes, {
  LineRasteriser? using,
  Duration timeout = const Duration(seconds: 3),
}) async {
  final deferred = EscPosDeferredDocs.shared[bytes];
  if (deferred == null || deferred.isEmpty) return bytes;
  final rasteriser = using ?? LineRasteriser.shared;
  try {
    final bands = await Future.wait(deferred.map((d) => rasteriser.render(d.request)))
        .timeout(timeout);
    final out = BytesBuilder();
    var cursor = 0;
    for (var i = 0; i < deferred.length; i++) {
      final line = deferred[i];
      final band = bands[i];
      out.add(Uint8List.sublistView(bytes, cursor, line.start));
      // A line that would not render keeps its fallback text, so the receipt still
      // says something where the picture would have been.
      out.add(band == null
          ? Uint8List.sublistView(bytes, line.start, line.end)
          : band.command());
      cursor = line.end;
    }
    out.add(Uint8List.sublistView(bytes, cursor));
    return out.toBytes();
  } catch (_) {
    return bytes;
  }
}
