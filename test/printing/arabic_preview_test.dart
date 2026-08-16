import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/printing/escpos.dart';
import 'package:offline_pos/core/printing/raster_line.dart';
import 'package:offline_pos/core/printing/receipt_builder.dart';
import 'package:offline_pos/domain/order.dart';

/// Proof that the dots the printer burns are Arabic letters, not empty boxes.
///
/// Every other test of the raster path measures geometry, and geometry passes
/// whether a glyph was drawn or not: the test binding substitutes a font that draws
/// every rune as a filled square, so a band full of squares has ink, has the right
/// width and passes everything. That is exactly how a build shipped with Arabic that
/// did not print.
///
/// So this loads the font the app actually carries and does two things a box font
/// cannot survive. It asserts on the shape of the ink, and it writes the bands out as
/// a picture at build/arabic_receipt_preview.png so a human who cannot get to the
/// printer can open the file and read the Arabic.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// The band is drawn in the family named in pubspec.yaml. The test binding does not
  /// register asset fonts, so it is registered here by hand; without this the whole
  /// file would be measuring squares again.
  setUpAll(() async {
    final loader = FontLoader(LineRasteriser.family)
      ..addFont(rootBundle.load('assets/fonts/Cairo-Regular.ttf'))
      ..addFont(rootBundle.load('assets/fonts/Cairo-Bold.ttf'));
    await loader.load();
  });

  setUp(() {
    EscPosPrintProfile.shared = EscPosPrintProfile();
    EscPosDeferredDocs.shared.clear();
    LineRasteriser.shared = LineRasteriser();
  });

  test('the font carried in the app draws letters, not squares', () async {
    final band = (await LineRasteriser()
        .render(const RasterRequest(text: 'شاورما', dots: 504)))!;

    // A square font inks its whole em box. Arabic at this size is thin strokes with
    // a lot of paper around them, so the ink can never approach that.
    final area = band.widthDots * band.heightDots;
    expect(_ink(band), greaterThan(0), reason: 'a blank band is a bug');
    expect(_ink(band) / area, lessThan(0.12),
        reason: 'a band this solid is a row of boxes, not a word');
  });

  test('two words that differ by one letter print differently', () async {
    // The clincher. A font with no Arabic in it draws the same square for every rune,
    // so these two would be bit-for-bit identical. They are only different if the
    // renderer really has the letters.
    final r = LineRasteriser();
    final a = (await r.render(const RasterRequest(text: 'شاورما', dots: 504)))!;
    final b = (await r.render(const RasterRequest(text: 'شاورمة', dots: 504)))!;
    expect(a.heightDots, b.heightDots);
    expect(a.bits, isNot(equals(b.bits)));
  });

  test('the letters join: a word is narrower than its letters spelled apart',
      () async {
    // Arabic is cursive. Six joined letters take less paper than the same six with a
    // space between them, and nothing but real shaping produces that.
    final r = LineRasteriser();
    final joined = (await r.render(
        const RasterRequest(text: 'شاورما', dots: 504, align: EscPosAlign.left)))!;
    final apart = (await r.render(const RasterRequest(
        text: 'ش ا و ر م ا', dots: 504, align: EscPosAlign.left)))!;
    expect(_rightmostInkedDot(joined), lessThan(_rightmostInkedDot(apart)));
  });

  test('a receipt of Arabic names is written out as a picture to look at',
      () async {
    final order = Order(deviceId: 'till-1', cashierId: 'sara', lines: [
      OrderLine(
        productId: 1,
        name: 'شاورما فراخ',
        quantity: 2,
        unitPrice: 65,
        note: 'بدون بصل',
        modifiers: [
          OrderModifier(
              modifierId: 1, name: 'جبنة زيادة', quantity: 1, unitPrice: 10),
        ],
      ),
      OrderLine(productId: 2, name: 'عصير مانجو', quantity: 1, unitPrice: 30),
      OrderLine(productId: 3, name: 'Cola', quantity: 1, unitPrice: 20),
    ])
      ..discountPercent = 10
      ..discountReason = 'زبون دائم';

    final sent = await rasteriseEscPos(ReceiptBuilder(
      shopName: 'مطعم جمعة',
      header: 'شارع الجمهورية - القاهرة',
      footer: 'شكرا لزيارتكم',
      formatAmount: (v) => v.toStringAsFixed(2),
      showDateTime: false,
      showNumber: false,
    ).build(order));

    final bands = _bandsIn(sent);
    expect(bands, isNotEmpty, reason: 'nothing was rendered, so nothing to look at');

    final file = File('build/arabic_receipt_preview.png');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(await _stackToPng(bands));

    // Named in the report so the shop can open it. If this ever shrinks to almost
    // nothing the picture is blank and the renderer has lost its font again.
    expect(await file.length(), greaterThan(1000));
  });
}

int _ink(RasterBand band) {
  var n = 0;
  for (final byte in band.bits) {
    for (var bit = 0; bit < 8; bit++) {
      if (byte & (1 << bit) != 0) n++;
    }
  }
  return n;
}

int _rightmostInkedDot(RasterBand band) {
  for (var x = band.widthDots - 1; x >= 0; x--) {
    for (var y = 0; y < band.heightDots; y++) {
      if (band.bits[y * band.widthBytes + (x >> 3)] & (0x80 >> (x & 7)) != 0) {
        return x;
      }
    }
  }
  return 0;
}

/// Every `GS v 0` band in a document, read back off the wire exactly as a printer
/// would read it, so the picture below is made of the bytes that were actually sent.
List<RasterBand> _bandsIn(Uint8List bytes) {
  final out = <RasterBand>[];
  var i = 0;
  while (i + 8 <= bytes.length) {
    if (bytes[i] != 0x1d || bytes[i + 1] != 0x76 || bytes[i + 2] != 0x30) {
      i++;
      continue;
    }
    final widthBytes = bytes[i + 4] | (bytes[i + 5] << 8);
    final height = bytes[i + 6] | (bytes[i + 7] << 8);
    final payload = widthBytes * height;
    if (i + 8 + payload > bytes.length) break;
    out.add(RasterBand(
      widthDots: widthBytes * 8,
      heightDots: height,
      bits: Uint8List.sublistView(bytes, i + 8, i + 8 + payload),
    ));
    i += 8 + payload;
  }
  return out;
}

/// The bands stacked down the roll on white paper, encoded as a PNG.
Future<Uint8List> _stackToPng(List<RasterBand> bands) async {
  const gap = 6;
  const margin = 8;
  final width = bands.map((b) => b.widthDots).reduce((a, b) => a > b ? a : b) +
      margin * 2;
  final height =
      bands.fold<int>(margin * 2, (h, b) => h + b.heightDots + gap) - gap;

  final rgba = Uint8List(width * height * 4)..fillRange(0, width * height * 4, 0xff);
  var top = margin;
  for (final band in bands) {
    for (var y = 0; y < band.heightDots; y++) {
      for (var x = 0; x < band.widthDots; x++) {
        final lit =
            band.bits[y * band.widthBytes + (x >> 3)] & (0x80 >> (x & 7)) != 0;
        if (!lit) continue;
        final at = (((top + y) * width) + margin + x) * 4;
        rgba[at] = 0;
        rgba[at + 1] = 0;
        rgba[at + 2] = 0;
      }
    }
    top += band.heightDots + gap;
  }

  final descriptor = ui.ImageDescriptor.raw(
    await ui.ImmutableBuffer.fromUint8List(rgba),
    width: width,
    height: height,
    pixelFormat: ui.PixelFormat.rgba8888,
  );
  final codec = await descriptor.instantiateCodec();
  final frame = await codec.getNextFrame();
  final png = await frame.image.toByteData(format: ui.ImageByteFormat.png);
  frame.image.dispose();
  codec.dispose();
  descriptor.dispose();
  return png!.buffer.asUint8List();
}
