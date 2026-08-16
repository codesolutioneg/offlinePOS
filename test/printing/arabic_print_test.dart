import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/db/database.dart';
import 'package:offline_pos/core/db/settings_store.dart';
import 'package:offline_pos/core/printing/escpos.dart';
import 'package:offline_pos/core/printing/kitchen_ticket.dart';
import 'package:offline_pos/core/printing/printer_transport.dart';
import 'package:offline_pos/core/printing/raster_line.dart';
import 'package:offline_pos/core/printing/receipt_builder.dart';
import 'package:offline_pos/core/printing/spool_store.dart';
import 'package:offline_pos/domain/order.dart';

import '../db/sqlite_loader.dart';
import 'strip_escpos.dart';

class _Recording implements PrinterTransport {
  _Recording({this.failAlways = false});

  final bool failAlways;
  final List<Uint8List> received = [];

  @override
  Future<void> send(Uint8List bytes) async {
    if (failAlways) throw PrinterUnavailable('down');
    received.add(bytes);
  }
}

/// A renderer that never answers, for proving what a print does while it waits.
class _NeverRenders extends LineRasteriser {
  final Completer<RasterBand?> _never = Completer<RasterBand?>();

  @override
  Future<RasterBand?> render(RasterRequest r) => _never.future;
}

Order arabicOrder() => Order(deviceId: 'till-1', cashierId: 'sara', lines: [
      OrderLine(
        productId: 1,
        name: 'شاورما فراخ',
        quantity: 2,
        unitPrice: 65,
        note: 'بدون بصل',
        modifiers: [
          OrderModifier(modifierId: 1, name: 'جبنة زيادة', quantity: 1, unitPrice: 10),
        ],
      ),
      OrderLine(productId: 2, name: 'Cola', quantity: 1, unitPrice: 20),
    ]);

Uint8List receipt(Order o) => ReceiptBuilder(
      shopName: 'JOUMA',
      footer: 'Thank you',
      formatAmount: (v) => v.toStringAsFixed(2),
      showDateTime: false,
      showNumber: false,
    ).build(o);

void main() {
  setUp(() {
    // The profile is process-wide (published by SettingsStore on a real till), so
    // each test states the shop it is describing.
    EscPosPrintProfile.shared = EscPosPrintProfile();
    EscPosDeferredDocs.shared.clear();
    LineRasteriser.shared = LineRasteriser();
  });

  group('a line the table cannot spell', () {
    test('prints as a rendered band with no fallback characters left', () async {
      final bytes = (EscPos()
            ..reset()
            ..line('شاي بالنعناع'))
          .build();
      // What the builder returns is still the old, printable document: the sale is
      // never held up for a picture.
      expect(strippedText(bytes), contains('?'));

      final sent = await rasteriseEscPos(bytes);
      expect(printedBands(sent), hasLength(1));
      expect(strippedText(sent).contains('?'), isFalse,
          reason: 'the question marks were replaced, not joined');
    });

    test('the band is a GS v 0 raster of whole bytes, and has ink in it', () async {
      final sent =
          await rasteriseEscPos((EscPos()..reset()..line('شاورما')).build());
      final at = _indexOf(sent, [0x1d, 0x76, 0x30, 0x00]);
      expect(at, isNonNegative, reason: 'GS v 0, mode 0');
      final band = printedBands(sent).single;
      expect(band.widthDots % 8, 0, reason: 'a raster row is counted in bytes');
      expect(band.widthDots, 42 * EscPos.dotsPerColumn);
      expect(band.inkedDots, greaterThan(0), reason: 'a blank band is a bug');
    });

    test('an amount stays in its own column when the label is rendered', () async {
      final p = EscPos()
        ..reset()
        ..row('شاورما فراخ', '130.00');
      // The label and the amount go to the renderer as two halves, so the padding
      // that aligns a fixed-width line is not baked into the picture and a long name
      // cannot push the amount out of its column.
      final request = p.deferred.single.request;
      expect(request.text, 'شاورما فراخ');
      expect(request.right, '130.00');
      expect(printedBands(await rasteriseEscPos(p.build())), hasLength(1));
    });

    test('a long name gets the room the amount does not need', () async {
      // The amount is measured at its own width, not at the paper's: measuring it
      // full width once left every label ellipsised into a single character.
      final band = (await LineRasteriser()
          .render(const RasterRequest(text: 'شاورما فراخ سبيشال', right: '130.00', dots: 504)))!;
      expect(_inkBetween(band, 168, 336), greaterThan(0),
          reason: 'the name reaches the middle of the paper');
      expect(_inkBetween(band, 0, 24), greaterThan(0), reason: 'and starts at the left');
    });

    test('weight and size are baked into the band, since ESC ! cannot reach dots',
        () {
      final p = EscPos()
        ..reset()
        ..size(doubleWidth: true, doubleHeight: true)
        ..bold(true)
        ..line('مطعم جمعة');
      final r = p.deferred.single.request;
      expect(r.bold, isTrue);
      expect(r.doubleWidth, isTrue);
      expect(r.doubleHeight, isTrue);
    });

    test('a centred line is centred by layout, not by padding spaces', () {
      final r = (EscPos()..centred('مطعم جمعة')).deferred.single.request;
      expect(r.text, 'مطعم جمعة');
      expect(r.align, EscPosAlign.center);
    });
  });

  group('a Latin receipt is untouched', () {
    test('nothing is deferred and the bytes are returned as they came', () async {
      final o = Order(deviceId: 'till-1', cashierId: 'sara', lines: [
        OrderLine(productId: 1, name: 'Pizza', quantity: 2, unitPrice: 250),
      ]);
      final bytes = receipt(o);
      expect(EscPosDeferredDocs.shared[bytes], isNull);
      final sent = await rasteriseEscPos(bytes);
      expect(identical(sent, bytes), isTrue,
          reason: 'not even a copy: the Latin path costs one map lookup');
      expect(printedBands(sent), isEmpty);
    });

    test('a euro sign and typographic punctuation still go as bytes', () async {
      final bytes = (EscPos()..reset()..line('Café 3€ don’t')).build();
      expect(printedBands(await rasteriseEscPos(bytes)), isEmpty);
    });
  });

  test('a mixed receipt renders only the lines that need it', () async {
    final bytes = receipt(arabicOrder());
    final sent = await rasteriseEscPos(bytes);
    final text = strippedText(sent);
    // The Arabic name, its modifier and its note are the three rendered lines; the
    // Latin drink, the totals and the footer stay text.
    expect(printedBands(sent), hasLength(3));
    expect(text, contains('Cola'));
    expect(text, contains('TOTAL'));
    expect(text, contains('Thank you'));
    expect(text.contains('?'), isFalse);
  });

  group('the shop decides', () {
    test('with rendering off, the line prints as fallback characters', () async {
      EscPosPrintProfile.shared = EscPosPrintProfile(rasterUnmappable: false);
      final bytes = (EscPos()..reset()..line('شاي')).build();
      expect(EscPosDeferredDocs.shared[bytes], isNull);
      final sent = await rasteriseEscPos(bytes);
      expect(identical(sent, bytes), isTrue);
      expect(strippedText(sent), '???\n');
    });

    test('an Arabic character table needs no picture at all', () async {
      EscPosPrintProfile.shared =
          EscPosPrintProfile(codePage: EscPosCodePage.windows1256);
      final bytes = (EscPos()..reset()..line('شاي')).build();
      // ESC t 49, and three Arabic letters as three bytes: the firmware joins them.
      expect(bytes.sublist(0, 5), [0x1b, 0x40, 0x1b, 0x74, 49]);
      expect(bytes, isNot(contains(EscPos.unmappable)));
      expect(printedBands(await rasteriseEscPos(bytes)), isEmpty);
    });

    test('the Arabic table keeps Latin accents where 1252 has them', () {
      // 1256 puts lam where Latin-1 keeps á, so an identity high half would have
      // printed an Arabic letter for every accented vowel.
      expect(EscPosCodePage.windows1256.byteFor('á'.runes.first), isNull);
      expect(EscPosCodePage.windows1256.byteFor('à'.runes.first), 0xe0);
      expect(EscPosCodePage.windows1256.byteFor('ل'.runes.first), 0xe1);
    });
  });

  group('a sale never waits for a picture', () {
    test('the document is bytes in hand while the renderer is still thinking',
        () async {
      // No await between an order and its bytes: the builders are synchronous all
      // the way down, which is what keeps printing off the selling path.
      final Uint8List bytes = receipt(arabicOrder());
      expect(strippedText(bytes), contains('?'));

      // And when the renderer never answers, the receipt still goes out on paper
      // with its fallback text rather than hanging in the print helper.
      final sent = await rasteriseEscPos(bytes,
          using: _NeverRenders(), timeout: const Duration(milliseconds: 50));
      expect(identical(sent, bytes), isTrue);
      expect(printedBands(sent), isEmpty);
    });
  });

  group('the send path is where the dots appear', () {
    test('a printer is handed the rendered document, not the fallback', () async {
      final wire = _Recording();
      await SpooledPrinter(wire).send(receipt(arabicOrder()), reference: 'r1');
      expect(printedBands(wire.received.single), hasLength(3));
    });

    test('what the spool holds is what would have printed', () async {
      final spool = MemorySpoolStore();
      final printer = SpooledPrinter(_Recording(failAlways: true), spool: spool);
      await expectLater(printer.send(receipt(arabicOrder()), reference: 'r1'),
          throwsA(isA<PrinterUnavailable>()));
      // A receipt held while the printer was off must not lose its Arabic when the
      // backlog finally flushes, long after the document was composed.
      final held = await spool.oldestFirst();
      expect(printedBands(held.single.bytes), hasLength(3));
    });

    test('a ticket copied on its way to a station still renders', () async {
      final wire = _Recording();
      // The kitchen path copies the bytes into a fresh buffer before sending, so a
      // document has to be recognised by what it says and not by which list holds it.
      final copy = Uint8List.fromList(KitchenTicketBuilder().build(arabicOrder()));
      await SpooledPrinter(wire).send(copy, reference: 'kot');
      expect(printedBands(wire.received.single), isNotEmpty);
    });

    test('a Latin job reaches the wire byte for byte', () async {
      final wire = _Recording();
      final bytes = receipt(Order(deviceId: 'till-1', cashierId: 'sara', lines: [
        OrderLine(productId: 1, name: 'Pizza', quantity: 1, unitPrice: 250),
      ]));
      await SpooledPrinter(wire).send(bytes, reference: 'r1');
      expect(wire.received.single, bytes);
    });
  });

  group('the till publishes what its printer can spell', () {
    late Db db;

    setUpAll(useSystemSqlite);
    setUp(() => db = Db.open(':memory:'));
    tearDown(() => db.close());

    test('every till renders by default, whatever language the screens are in', () {
      // The shop that broke was an English-language till with an Arabic menu, which
      // is the ordinary case here. Keying this to the UI language meant that shop
      // printed nonsense and nothing on screen said why.
      final settings = SettingsStore(db);
      expect(EscPosPrintProfile.shared.rasterUnmappable, isTrue);
      settings.language = 'ar';
      expect(EscPosPrintProfile.shared.rasterUnmappable, isTrue);
      settings.language = 'en';
      expect(EscPosPrintProfile.shared.rasterUnmappable, isTrue,
          reason: 'an English screen does not mean a Latin menu');
    });

    test('a manager can overrule the default either way', () {
      final settings = SettingsStore(db)..language = 'ar';
      settings.receiptArabicRaster = false;
      expect(EscPosPrintProfile.shared.rasterUnmappable, isFalse);
      // And it survives a restart, which is what a stored setting is for.
      expect(SettingsStore(db).receiptArabicRaster, isFalse);
      expect(EscPosPrintProfile.shared.rasterUnmappable, isFalse);
    });

    test('the chosen character table reaches the builders', () {
      final settings = SettingsStore(db);
      expect(EscPosPrintProfile.shared.codePage.id, 16);
      settings.receiptCodePage = 'wpc1256';
      expect(EscPosPrintProfile.shared.codePage.id, 49);
      // A table this build does not know must not silently change what prints.
      settings.receiptCodePage = 'pc999';
      expect(EscPosPrintProfile.shared.codePage.id, 16);
    });
  });

  group('goldens', () {
    test('a receipt carrying Arabic product names', () async {
      final o = Order(deviceId: 'till-1', cashierId: 'sara', lines: [
        OrderLine(productId: 1, name: 'شاورما فراخ', quantity: 2, unitPrice: 65),
        OrderLine(productId: 2, name: 'Cola', quantity: 1, unitPrice: 20),
      ]);
      final sent = await rasteriseEscPos(ReceiptBuilder(
        shopName: 'JOUMA',
        formatAmount: (v) => v.toStringAsFixed(2),
        showDateTime: false,
        showNumber: false,
        showCashier: false,
        showOrderType: false,
      ).build(o));
      expect(documentShape(sent), '''
JOUMA
------------------------------------------
------------------------------------------
[band 504x24]
1 x Cola                             20.00
------------------------------------------
TOTAL                               150.00


''');
    });

    test('a kitchen ticket carrying Arabic product names', () async {
      final o = Order(deviceId: 'till-1', cashierId: 'sara', lines: [
        OrderLine(
          productId: 1,
          name: 'شاورما فراخ',
          quantity: 2,
          unitPrice: 65,
          note: 'بدون بصل',
        ),
      ]);
      final sent = await rasteriseEscPos(KitchenTicketBuilder().build(o));
      // The clock line is the one thing that cannot be a golden.
      final shape = documentShape(sent)
          .split('\n')
          .where((l) => !l.contains('#'))
          .join('\n');
      // The name is double height on a kitchen ticket, so its band is twice as tall:
      // the size the byte line would have had is baked into the picture.
      expect(shape, '''
KITCHEN
------------------------------------------
DINE-IN
By: sara
------------------------------------------
[band 504x48]
[band 504x24]



''');
    });
  });
}

/// Inked dots in a vertical slice of a band, for asking where on the paper the text
/// actually landed.
int _inkBetween(RasterBand band, int fromDot, int toDot) {
  var ink = 0;
  for (var y = 0; y < band.heightDots; y++) {
    for (var x = fromDot; x < toDot; x++) {
      if (band.bits[y * band.widthBytes + (x >> 3)] & (0x80 >> (x & 7)) != 0) ink++;
    }
  }
  return ink;
}

int _indexOf(List<int> haystack, List<int> needle) {
  for (var i = 0; i + needle.length <= haystack.length; i++) {
    var hit = true;
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) {
        hit = false;
        break;
      }
    }
    if (hit) return i;
  }
  return -1;
}
