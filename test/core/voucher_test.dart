import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/vouchers/code128.dart';
import 'package:offline_pos/core/vouchers/voucher_book.dart';
import 'package:offline_pos/core/vouchers/voucher_client.dart';
import 'package:offline_pos/core/vouchers/voucher_code.dart';
import 'package:offline_pos/core/vouchers/voucher_http.dart';
import 'package:offline_pos/domain/order.dart';

void main() {
  test('the cashier types the printed number, and 01 is the same as 1', () {
    expect(VoucherCode.issue(1).code, '1');
    expect(VoucherCode.parse('1')?.serial, 1);
    expect(VoucherCode.parse('01')?.code, '1');
    expect(VoucherCode.parse('18')?.serial, 18);
    expect(VoucherCode.parse('0'), isNull);
    expect(VoucherCode.parse(''), isNull);
  });

  test('the book gives a code once, then says it was used', () async {
    final book = await _book();
    final code = VoucherCode.issue(1523).code;
    final first = await book.redeem(
      branchKey: 'branch',
      rawCode: code,
      customerName: 'Ali',
      orderUuid: 'order-1',
      orderNo: '100',
      cashier: 'Sara',
    );
    expect(first.ok, isTrue);
    expect(first.percent, 15);
    expect(first.code, code);

    final again = await book.redeem(
      branchKey: 'branch',
      rawCode: code,
      customerName: 'Ali',
      orderUuid: 'order-1',
    );
    expect(again.ok, isTrue);

    final other = await book.redeem(
      branchKey: 'branch',
      rawCode: code,
      customerName: 'Mona',
      orderUuid: 'order-2',
    );
    expect(other.ok, isFalse);
    expect(other.error, 'used');

    final paid = await book.confirm(
      branchKey: 'branch',
      rawCode: code,
      orderUuid: 'order-1',
      discountAmount: 30,
      orderNo: '100',
    );
    expect(paid.ok, isTrue);
    final released = await book.release(
      branchKey: 'branch',
      rawCode: code,
      orderUuid: 'order-1',
    );
    expect(released.error, 'used');

    final rows = await book.report();
    expect(rows.single.customerName, 'Ali');
    expect(rows.single.branchName, 'Local');
    expect(rows.single.status, 'used');
    expect(rows.single.discountAmount, 30);
  });

  test('cancelling a bill frees the code, and a dead hold expires', () async {
    final book = await _book();
    var now = DateTime.utc(2026, 1, 1, 8);
    book.clock = () => now;
    final code = VoucherCode.issue(7).code;
    await book.redeem(
      branchKey: 'branch',
      rawCode: code,
      customerName: 'Ali',
      orderUuid: 'order-1',
    );
    final freed = await book.release(
      branchKey: 'branch',
      rawCode: code,
      orderUuid: 'order-1',
    );
    expect(freed.ok, isTrue);
    final reused = await book.redeem(
      branchKey: 'branch',
      rawCode: code,
      customerName: 'Mona',
      orderUuid: 'order-2',
    );
    expect(reused.ok, isTrue);

    now = now.add(const Duration(hours: 13));
    final taken = await book.redeem(
      branchKey: 'branch',
      rawCode: code,
      customerName: 'Hany',
      orderUuid: 'order-3',
    );
    expect(taken.ok, isTrue);
  });

  test('a till redeem through HTTP then a second branch is refused', () async {
    final book = await _book();
    final server = await serveVouchers(book, port: 0);
    addTearDown(server.close);
    final client = VoucherClient(
      baseUrl: 'http://127.0.0.1:${server.port}',
      branchKey: 'branch',
    );
    addTearDown(client.close);
    final code = VoucherCode.issue(1).code;
    final first = await client.redeem(
      code: code,
      customerName: 'Ali',
      orderUuid: 'order-1',
      cashier: 'Sara',
    );
    expect(first.ok, isTrue);
    expect(first.percent, 15);

    final second = VoucherClient(
      baseUrl: 'http://127.0.0.1:${server.port}',
      branchKey: 'branch',
    );
    addTearDown(second.close);
    final used = await second.redeem(
      code: code,
      customerName: 'Mona',
      orderUuid: 'order-2',
    );
    expect(used.ok, isFalse);
    expect(used.error, 'used');
    expect(voucherFailure(used.error), 'This voucher was used before');
  });

  test('a mistyped code never asks the server', () async {
    final client = VoucherClient(baseUrl: 'http://127.0.0.1:1', branchKey: 'branch');
    addTearDown(client.close);
    final reply = await client.redeem(
      code: '0',
      customerName: 'Ali',
      orderUuid: 'order-1',
    );
    expect(reply.error, 'invalid');
  });

  test('the voucher stays off the Odoo payload and on the local order', () {
    final order = Order(
      deviceId: 'till',
      cashierId: 'sara',
      voucherCode: '18',
      voucherCustomerName: 'Ali',
      lines: [
        OrderLine(productId: 1, name: 'Pizza', quantity: 1, unitPrice: 100),
      ],
    )..discountPercent = 15;
    final local = order.toMap();
    expect(local['voucher_code'], '18');
    expect(local['voucher_customer_name'], 'Ali');
    final wire = order.toServerPayload();
    expect(wire.containsKey('voucher_code'), isFalse);
    expect(wire['discount_amount'], greaterThan(0));
    final restored = Order.fromMap(local);
    expect(restored.voucherCode, '18');
    expect(restored.voucherCustomerName, 'Ali');
  });

  test('a code outside the added numbers is refused', () async {
    final dir = await Directory.systemTemp.createTemp('vouchers');
    final book = await VoucherBook.open(File('${dir.path}/vouchers.json'));
    await book.ensureBootstrap(adminKey: 'admin', branchKey: 'branch');
    final code = VoucherCode.issue(10).code;
    final before = await book.redeem(
      branchKey: 'branch',
      rawCode: code,
      customerName: 'Ali',
      orderUuid: 'order-1',
    );
    expect(before.error, 'invalid');
    expect(await book.addRange(10, 20), isNull);
    expect(await book.addRange(10, 20), isNull);
    expect(book.ranges, hasLength(1));
    final after = await book.redeem(
      branchKey: 'branch',
      rawCode: code,
      customerName: 'Ali',
      orderUuid: 'order-1',
    );
    expect(after.ok, isTrue);
    await book.removeRange(0);
    expect(book.ranges, isEmpty);
  });

  test('a discount type sets the percent for its numbers', () async {
    final dir = await Directory.systemTemp.createTemp('vouchers');
    final book = await VoucherBook.open(File('${dir.path}/vouchers.json'));
    await book.ensureBootstrap(adminKey: 'admin', branchKey: 'branch');
    expect(await book.addDiscount('', 20), 'discount');
    expect(await book.addDiscount('Staff', 0), 'discount');
    expect(await book.addDiscount('Staff', 20), isNull);
    expect(await book.addDiscount('Staff', 25), isNull);
    expect(book.discounts, hasLength(1));
    expect(book.discounts.single.percent, 25);
    final id = book.discounts.single.id;
    expect(await book.addRange(10, 20, discountId: id), isNull);
    expect(await book.addRange(30, 40), isNull);
    final staff = await book.redeem(
      branchKey: 'branch',
      rawCode: VoucherCode.issue(10).code,
      customerName: '0100',
      orderUuid: 'order-1',
    );
    expect(staff.percent, 25);
    final plain = await book.redeem(
      branchKey: 'branch',
      rawCode: VoucherCode.issue(30).code,
      customerName: '0100',
      orderUuid: 'order-2',
    );
    expect(plain.percent, 15);
    await book.removeDiscount(0);
    expect(book.percentOf(book.ranges.first), 15);
  });

  test('a number saved with the old check digit is the plain serial', () async {
    final dir = await Directory.systemTemp.createTemp('vouchers');
    final file = File('${dir.path}/vouchers.json');
    await file.writeAsString(jsonEncode({
      'percent': 15,
      'adminKey': 'admin',
      'branches': [
        {'name': 'Main', 'key': 'branch'}
      ],
      'ranges': [
        {'from': 1, 'to': 30000}
      ],
      'vouchers': {
        '18': {
          'serial': 1,
          'status': 'used',
          'branch_name': 'Main',
          'customer_name': '2',
          'order_uuid': 'order-old',
          'order_no': '117',
          'cashier': 'mostafa',
          'held_at': '2026-10-24T01:05:00.000Z',
          'used_at': '2026-10-24T01:05:00.000Z',
        }
      },
    }));
    final book = await VoucherBook.open(file);
    final rows = await book.report();
    expect(rows.single.code, '1');
    expect(rows.single.serial, 1);
    final again = await book.redeem(
      branchKey: 'branch',
      rawCode: '1',
      customerName: '2',
      orderUuid: 'order-new',
    );
    expect(again.error, 'used');
    final neighbour = await book.redeem(
      branchKey: 'branch',
      rawCode: '18',
      customerName: '2',
      orderUuid: 'order-18',
    );
    expect(neighbour.ok, isTrue);
    expect(neighbour.serial, 18);
  });

  test('a phone claims one cheque, and the branch scan uses that number', () async {
    final book = await _book();
    final first = await book.claimOffer('+20 100 123 4567');
    expect(first.ok, isTrue);
    expect(first.serial, 1);
    expect(first.customerName, '1001234567');
    expect(first.expiresLabel, '30/12/2026');
    final again = await book.claimOffer('01001234567');
    expect(again.serial, 1);
    final other = await book.claimOffer('01009876543');
    expect(other.serial, 2);

    final scanned = await book.redeem(
      branchKey: 'branch',
      rawCode: '1',
      customerName: '',
      orderUuid: 'order-scan',
    );
    expect(scanned.ok, isTrue);
    expect(scanned.customerName, '1001234567');
    expect(scanned.percent, 15);

    final released = await book.release(
      branchKey: 'branch',
      rawCode: '1',
      orderUuid: 'order-scan',
    );
    expect(released.ok, isTrue);
    final kept = await book.claimOffer('1001234567');
    expect(kept.serial, 1);

    final usedUp = await book.redeem(
      branchKey: 'branch',
      rawCode: '1',
      customerName: '',
      orderUuid: 'order-pay',
    );
    await book.confirm(
      branchKey: 'branch',
      rawCode: '1',
      orderUuid: 'order-pay',
      discountAmount: 10,
    );
    final afterPay = await book.claimOffer('1001234567');
    expect(afterPay.error, 'used');
    expect(code128Svg('1'), contains('<rect'));
    expect(usedUp.ok, isTrue);
  });
}

Future<VoucherBook> _book() async {
  final dir = await Directory.systemTemp.createTemp('vouchers');
  final book = await VoucherBook.open(File('${dir.path}/vouchers.json'));
  await book.ensureBootstrap(adminKey: 'admin', branchKey: 'branch', branchName: 'Local');
  await book.addRange(1, 30000);
  return book;
}
