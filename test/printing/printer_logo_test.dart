import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

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

  test('a tall logo is sent as strips that together carry every row once', () {
    const rows = 150;
    final bits = Uint8List(2 * rows);
    for (var i = 0; i < bits.length; i++) {
      bits[i] = i & 0xff;
    }
    final bytes = PrinterLogo(widthDots: 16, heightDots: rows, bits: bits).raster();

    final heights = <int>[];
    final body = BytesBuilder();
    var at = 0;
    while (at < bytes.length) {
      expect(bytes.sublist(at, at + 6), [0x1d, 0x76, 0x30, 0x00, 2, 0]);
      final h = bytes[at + 6] | (bytes[at + 7] << 8);
      heights.add(h);
      body.add(bytes.sublist(at + 8, at + 8 + 2 * h));
      at += 8 + 2 * h;
    }
    expect(heights, [64, 64, 22]);
    expect(body.toBytes(), bits);
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

    ByteData flat(int width, int height, int r, int g, int b) {
      final data = ByteData(width * height * 4);
      for (var i = 0; i < width * height; i++) {
        data
          ..setUint8(i * 4, r)
          ..setUint8(i * 4 + 1, g)
          ..setUint8(i * 4 + 2, b)
          ..setUint8(i * 4 + 3, 255);
      }
      return data;
    }

    int inked(PrinterLogo logo) =>
        logo.bits.fold(0, (n, byte) => n + byte.toRadixString(2).replaceAll('0', '').length);

    test('a mid grey is shaded, not printed as a solid black block', () {
      final logo = PrinterLogo.fromRgba(flat(32, 32, 128, 128, 128), 32, 32);
      final share = inked(logo) / (32 * 32);
      expect(share, inInclusiveRange(0.4, 0.6));
    });

    test('a coloured part of a logo is shaded too', () {
      // A strong red, which a plain cut printed as solid black.
      final logo = PrinterLogo.fromRgba(flat(32, 32, 220, 30, 30), 32, 32);
      final share = inked(logo) / (32 * 32);
      expect(share, greaterThan(0.2));
      expect(share, lessThan(0.9));
    });

    test('the near-white background of a JPG prints nothing', () {
      final logo = PrinterLogo.fromRgba(flat(32, 32, 238, 240, 236), 32, 32);
      expect(logo.bits, everyElement(0));
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

  group('loading a file', () {
    /// A [size] square PNG on white with a black square of [mark] in the middle.
    Future<File> png(Directory dir, int size, int mark) async {
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder)
        ..drawRect(ui.Rect.fromLTWH(0, 0, size.toDouble(), size.toDouble()),
            ui.Paint()..color = const ui.Color(0xFFFFFFFF));
      final start = (size - mark) / 2;
      canvas.drawRect(ui.Rect.fromLTWH(start, start, mark.toDouble(), mark.toDouble()),
          ui.Paint()..color = const ui.Color(0xFF000000));
      final image = await recorder.endRecording().toImage(size, size);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      final file = File('${dir.path}${Platform.pathSeparator}logo.png');
      await file.writeAsBytes(data!.buffer.asUint8List());
      return file;
    }

    testWidgets('the white border is trimmed and the mark fits the height cap',
        (tester) async {
      await tester.runAsync(() async {
        final dir = await Directory.systemTemp.createTemp('logo');
        try {
          final file = await png(dir, 1000, 400);
          final logo = await loadPrinterLogo(file.path, maxWidthDots: 576, maxHeightDots: 160);
          expect(logo, isNotNull);
          expect(logo!.widthDots, 160);
          expect(logo.heightDots, 160);
          // All mark, no border: the corners are inked.
          expect(logo.bits.first & 0x80, 0x80);
          expect(logo.bits.last & 0x01, 0x01);
          // A few kilobytes a slip, not tens.
          expect(logo.raster().length, lessThan(4000));
        } finally {
          await dir.delete(recursive: true);
        }
      });
    });

    testWidgets('a picture that is all paper is not a logo', (tester) async {
      await tester.runAsync(() async {
        final dir = await Directory.systemTemp.createTemp('logo');
        try {
          final file = await png(dir, 64, 0);
          expect(await loadPrinterLogo(file.path), isNull);
        } finally {
          await dir.delete(recursive: true);
        }
      });
    });
  });
}
