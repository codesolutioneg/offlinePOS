import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/printing/printer_logo.dart';

/// The two ways a mark reaches paper, byte for byte.
///
/// A logo is the one place this app sends a picture to a printer, so the commands
/// have to be exactly right: a wrong length in an FS q header does not print a wrong
/// logo, it leaves the printer reading receipt text as image data.
void main() {
  /// An 8 by 8 stamp with the top-left dot and the bottom-right dot inked, which is
  /// enough to tell the row layout from the column layout apart.
  PrinterLogo corners() {
    final bits = Uint8List(8);
    bits[0] = 0x80; // row 0, leftmost dot
    bits[7] = 0x01; // row 7, rightmost dot
    return PrinterLogo(widthDots: 8, heightDots: 8, bits: bits);
  }

  test('printing a stored logo costs four bytes, whatever it weighs', () {
    expect(PrinterLogo.printStored(), [0x1c, 0x70, 1, 0]);
    expect(PrinterLogo.printStored(index: 2, doubleWidth: true, doubleHeight: true),
        [0x1c, 0x70, 2, 3]);
  });

  test('the flash upload carries the size in bytes and the dots in columns', () {
    final bytes = corners().defineNv();

    // FS q 1, then one byte across and one byte down.
    expect(bytes.sublist(0, 7), [0x1c, 0x71, 0x01, 1, 0, 1, 0]);
    // One byte per dot-column: the first column holds the top dot, the last holds
    // the bottom one, and nothing is inked between them.
    expect(bytes.length, 7 + 8);
    expect(bytes[7], 0x80);
    expect(bytes.sublist(8, 14), everyElement(0));
    expect(bytes[14], 0x01);
  });

  test('the raster fallback is GS v 0 with the rows exactly as they are held', () {
    final logo = corners();
    final bytes = logo.raster();

    expect(bytes.sublist(0, 8), [0x1d, 0x76, 0x30, 0x00, 1, 0, 8, 0]);
    expect(bytes.sublist(8), logo.bits);
  });

  test('a wide logo reports its width in whole bytes', () {
    final wide = PrinterLogo(
        widthDots: 384, heightDots: 16, bits: Uint8List(48 * 16));
    final header = wide.defineNv().sublist(3, 7);
    // 48 bytes across, 2 down.
    expect(header, [48, 0, 2, 0]);
  });

  group('what is kept on the device', () {
    test('survives a round trip', () {
      final back = PrinterLogo.decode(corners().encode());
      expect(back, isNotNull);
      expect(back!.widthDots, 8);
      expect(back.heightDots, 8);
      expect(back.bits, corners().bits);
    });

    test('a mangled value costs the receipt its logo, not the receipt', () {
      expect(PrinterLogo.decode(null), isNull);
      expect(PrinterLogo.decode(''), isNull);
      expect(PrinterLogo.decode('8:8:not-base64!!'), isNull);
      // Right shape, wrong amount of data: a short buffer would run off the end of
      // the packing loop rather than print a short logo.
      expect(PrinterLogo.decode('8:8:AAAA'), isNull);
      // Not a whole byte across, which neither command can express.
      expect(PrinterLogo.decode('7:8:AAAAAAAAAAA='), isNull);
    });
  });

  group('turning pixels into dots', () {
    /// [dark] pixels are opaque black, the rest are opaque white.
    ByteData pixels(int width, int height, Set<int> dark) {
      final data = ByteData(width * height * 4);
      for (var i = 0; i < width * height; i++) {
        final ink = dark.contains(i);
        data.setUint8(i * 4, ink ? 0 : 255);
        data.setUint8(i * 4 + 1, ink ? 0 : 255);
        data.setUint8(i * 4 + 2, ink ? 0 : 255);
        data.setUint8(i * 4 + 3, 255);
      }
      return data;
    }

    test('dark pixels ink and light ones do not', () {
      final logo = PrinterLogo.fromRgba(pixels(8, 8, {0, 63}), 8, 8);
      expect(logo.widthDots, 8);
      expect(logo.heightDots, 8);
      expect(logo.bits[0], 0x80);
      expect(logo.bits[7], 0x01);
      expect(logo.bits.sublist(1, 7), everyElement(0));
    });

    test('a transparent background is paper, not ink', () {
      final data = ByteData(8 * 8 * 4);
      // Every pixel is black but fully transparent, which is what a logo exported
      // with a cut-out background looks like around the mark.
      for (var i = 0; i < 64; i++) {
        data.setUint8(i * 4 + 3, 0);
      }
      expect(PrinterLogo.fromRgba(data, 8, 8).bits, everyElement(0));
    });

    test('an odd size is padded to whole bytes both ways', () {
      final logo = PrinterLogo.fromRgba(pixels(20, 13, {0}), 20, 13);
      // 20 dots across is two whole bytes and a remainder that carries no picture.
      expect(logo.widthDots, 16);
      // Height rounds up, because the flash route counts 8-dot blocks.
      expect(logo.heightDots, 16);
      expect(logo.bits.length, 2 * 16);
      expect(logo.bits[0], 0x80);
    });
  });
}
