import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/printing/escpos.dart';
import 'package:offline_pos/core/printing/receipt_builder.dart';
import 'package:offline_pos/domain/order.dart';

import 'strip_escpos.dart';

/// How big the slip prints.
///
/// The profile is the document's base size; a line that emphasises itself (the
/// TOTAL, the shop name) multiplies on top of it rather than replacing it, and the
/// layout is recomputed so a wider character never pushes the amount column off the
/// roll. A till on the normal profile must print exactly the bytes it always has.
void main() {
  Order sale() => Order(deviceId: 'till-1', cashierId: 'sara')
    ..lines.add(OrderLine(
        productId: 1, name: 'Margherita pizza', quantity: 2, unitPrice: 125));

  List<int> slip({required String profile}) => ReceiptBuilder(
        shopName: 'Test Shop',
        formatAmount: (v) => v.toStringAsFixed(2),
      ).build(sale()).toList();

  /// The document's own bytes with a profile published, since that is how a shop
  /// sets it: the layouts never take a size argument.
  List<int> slipWith(EscPosTextScale scale) {
    EscPosPrintProfile.shared = EscPosPrintProfile(textScale: scale);
    addTearDown(() => EscPosPrintProfile.shared = EscPosPrintProfile());
    return slip(profile: scale.name);
  }

  bool containsBytes(List<int> haystack, List<int> needle) {
    for (var i = 0; i + needle.length <= haystack.length; i++) {
      var hit = true;
      for (var j = 0; j < needle.length; j++) {
        if (haystack[i + j] != needle[j]) {
          hit = false;
          break;
        }
      }
      if (hit) return true;
    }
    return false;
  }

  /// How wide the layout believes the roll is: the separator rule is drawn to
  /// exactly the column count, so it is the honest measure. (A plain line of text
  /// has never been width-aware; the printer wraps that, as it always has.)
  int layoutWidth(List<int> bytes) => strippedText(bytes)
      .split('\n')
      .where((l) => l.isNotEmpty && l.split('').every((c) => c == '-'))
      .fold(0, (w, l) => l.length > w ? l.length : w);

  test('the normal profile prints exactly what it always printed', () {
    final bytes = slipWith(EscPosTextScale.normal);
    // ESC ! is the only size instruction on a normal slip, as it has always been.
    expect(containsBytes(bytes, const [0x1d, 0x21]), isFalse);
    expect(containsBytes(bytes, const [0x1b, 0x21]), isTrue);
    expect(layoutWidth(bytes), 42);
  });

  test('tall doubles the height and leaves the layout alone', () {
    final bytes = slipWith(EscPosTextScale.tall);
    // GS ! n, width 1 height 2.
    expect(containsBytes(bytes, const [0x1d, 0x21, 0x01]), isTrue);
    expect(layoutWidth(bytes), 42,
        reason: 'a taller character is no wider, so the roll still holds 42');
    expect(strippedText(bytes), contains('Margherita pizza'));
  });

  test('large halves the line so the amount column stays on the paper', () {
    final bytes = slipWith(EscPosTextScale.large);
    // GS ! n, width 2 height 2.
    expect(containsBytes(bytes, const [0x1d, 0x21, 0x11]), isTrue);
    expect(layoutWidth(bytes), 21);
    // The money still ends the line rather than being pushed off it.
    final total = strippedText(bytes)
        .split('\n')
        .firstWhere((l) => l.startsWith('TOTAL'));
    expect(total, hasLength(21));
    expect(total, endsWith('250.00'));
  });

  test('an emphasised line multiplies the base rather than cancelling it', () {
    EscPosPrintProfile.shared =
        EscPosPrintProfile(textScale: EscPosTextScale.tall);
    addTearDown(() => EscPosPrintProfile.shared = EscPosPrintProfile());
    final p = EscPos(columns: 42)..reset();
    p.size(doubleHeight: true).line('BIG');
    final bytes = p.build();
    // Base 2 high times the line's own 2 is 4 high: GS ! with height nibble 3.
    expect(containsBytes(bytes, const [0x1d, 0x21, 0x03]), isTrue);
    // And back to the document's own size, not to one by one.
    p.size();
    expect(containsBytes(p.build(), const [0x1d, 0x21, 0x01]), isTrue);
  });

  test('a rendered line is told the size the bytes would have printed at', () {
    EscPosPrintProfile.shared = EscPosPrintProfile(
        textScale: EscPosTextScale.tall, rasterUnmappable: true);
    addTearDown(() => EscPosPrintProfile.shared = EscPosPrintProfile());
    final p = EscPos(columns: 42)..reset();
    p.size(doubleHeight: true).line('شاورما');
    final request = p.deferred.single.request;
    expect(request.heightScale, 2, reason: 'the document is set tall');
    expect(request.doubleHeight, isTrue, reason: 'the line emphasised itself');
    expect(request.totalHeightScale, 4);
    expect(request.totalWidthScale, 1);
  });
}
