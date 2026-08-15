/// Removes ESC/POS control sequences so a test can assert on the printed text.
///
/// Filtering by byte value is not enough: the parameter bytes of a sequence can be
/// printable (ESC ! and ESC E both carry a printable command byte) and leak into the
/// text, which silently inflates every width assertion.
String strippedText(List<int> bytes) {
  final out = <int>[];
  var i = 0;
  while (i < bytes.length) {
    final b = bytes[i];
    if (b == 0x1b) {
      // ESC sequences used by EscPos: @ (1 byte), a/E/!/t (2 bytes), p (4 bytes).
      final cmd = i + 1 < bytes.length ? bytes[i + 1] : 0;
      i += switch (cmd) {
        0x40 => 2,
        0x61 || 0x45 || 0x21 || 0x74 => 3,
        0x70 => 5,
        _ => 2,
      };
      continue;
    }
    if (b == 0x1d) {
      final band = _bandAt(bytes, i);
      // GS v 0 carries a rendered line: skipping only the header would let a
      // megabyte of pixels through as if it were printed text.
      i += band?.length ?? _gsLength(bytes, i);
      continue;
    }
    out.add(b);
    i++;
  }
  return String.fromCharCodes(out);
}

/// How long a GS sequence is: `GS ! n` sets the character size in three bytes,
/// everything else this app emits (GS V B n) takes four. Getting this wrong leaks a
/// parameter byte into the text and inflates every width assertion.
int _gsLength(List<int> bytes, int i) =>
    i + 1 < bytes.length && bytes[i + 1] == 0x21 ? 3 : 4;

/// One rendered line found in a document.
class PrintedBand {
  PrintedBand({
    required this.widthDots,
    required this.heightDots,
    required this.inkedDots,
    required this.length,
  });

  final int widthDots;
  final int heightDots;

  /// How many dots the printer would burn. Zero means a blank band, which is a
  /// rendering bug wearing a picture's clothes.
  final int inkedDots;

  /// Bytes the whole command occupies, header included.
  final int length;
}

PrintedBand? _bandAt(List<int> bytes, int i) {
  if (i + 8 > bytes.length || bytes[i] != 0x1d || bytes[i + 1] != 0x76) return null;
  final widthBytes = bytes[i + 4] | (bytes[i + 5] << 8);
  final height = bytes[i + 6] | (bytes[i + 7] << 8);
  final payload = widthBytes * height;
  var ink = 0;
  for (var p = i + 8; p < i + 8 + payload && p < bytes.length; p++) {
    ink += _onBits(bytes[p]);
  }
  return PrintedBand(
    widthDots: widthBytes * 8,
    heightDots: height,
    inkedDots: ink,
    length: 8 + payload,
  );
}

int _onBits(int b) {
  var n = 0;
  for (var bit = 0; bit < 8; bit++) {
    if (b & (1 << bit) != 0) n++;
  }
  return n;
}

/// Every rendered line in a document, in print order.
List<PrintedBand> printedBands(List<int> bytes) {
  final bands = <PrintedBand>[];
  var i = 0;
  while (i < bytes.length) {
    final band = _bandAt(bytes, i);
    if (band != null) {
      bands.add(band);
      i += band.length;
      continue;
    }
    i++;
  }
  return bands;
}

/// The document as a golden: the text that prints, with a rendered line shown as
/// its size in dots so a golden pins which lines became pictures and how big.
String documentShape(List<int> bytes) {
  final out = StringBuffer();
  final text = <int>[];
  void flush() {
    if (text.isEmpty) return;
    out.write(String.fromCharCodes(text));
    text.clear();
  }

  var i = 0;
  while (i < bytes.length) {
    final b = bytes[i];
    final band = _bandAt(bytes, i);
    if (band != null) {
      flush();
      out.writeln('[band ${band.widthDots}x${band.heightDots}]');
      i += band.length;
      continue;
    }
    if (b == 0x1b) {
      final cmd = i + 1 < bytes.length ? bytes[i + 1] : 0;
      i += switch (cmd) {
        0x40 => 2,
        0x61 || 0x45 || 0x21 || 0x74 => 3,
        0x70 => 5,
        _ => 2,
      };
      continue;
    }
    if (b == 0x1d) {
      i += _gsLength(bytes, i);
      continue;
    }
    text.add(b);
    i++;
  }
  flush();
  return out.toString();
}
