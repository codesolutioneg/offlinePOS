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
      i += 4; // GS V B n
      continue;
    }
    out.add(b);
    i++;
  }
  return String.fromCharCodes(out);
}
