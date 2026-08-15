import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/printing/kitchen_ticket.dart';
import 'package:offline_pos/core/printing/receipt_builder.dart';
import 'package:offline_pos/domain/order.dart';

import 'strip_escpos.dart';

/// The slip that goes out with the bag. A driver reads it at a door, so it has to
/// carry the phone and the address, not just a name.
void main() {
  Order delivery({
    String? phone = '0100 123 4567',
    String? address = '12 Nile St, flat 4, Maadi',
    String? channel,
    String? companyNo,
    String? driver,
  }) =>
      Order(
        deviceId: 'till-1',
        cashierId: 'sara',
        type: OrderType.delivery,
        customerName: 'Nadia',
        customerPhone: phone,
        customerAddress: address,
        deliveryChannel: channel,
        companyOrderNo: companyNo,
        driverName: driver,
        deliveryCost: 20,
        lines: [OrderLine(productId: 1, name: 'Pizza', quantity: 1, unitPrice: 100)],
      );

  String receipt(Order o, {int columns = 42}) => strippedText(ReceiptBuilder(
        shopName: 'JOUMA',
        columns: columns,
        formatAmount: (v) => v.toStringAsFixed(2),
      ).build(o));

  String ticket(Order o) => strippedText(KitchenTicketBuilder().build(o));

  test('the receipt carries the phone and the address', () {
    final text = receipt(delivery());
    expect(text, contains('Customer: Nadia'));
    expect(text, contains('Phone: 0100 123 4567'));
    expect(text, contains('12 Nile St'));
    expect(text, contains('Maadi'));
  });

  test('a long address wraps instead of being cut short', () {
    final text = receipt(
        delivery(address: 'Building 44, second floor, apartment 12, Street 9, Maadi'),
        columns: 32);
    expect(text, contains('apartment 12'));
    expect(text, contains('Maadi'));
    for (final line in text.split('\n')) {
      expect(line.length, lessThanOrEqualTo(32));
    }
  });

  test('a counter sale prints no delivery block', () {
    final over = Order(
      deviceId: 'till-1',
      cashierId: 'sara',
      type: OrderType.takeaway,
      customerName: 'Nadia',
      customerPhone: '0100',
      lines: [OrderLine(productId: 1, name: 'Pizza', quantity: 1, unitPrice: 100)],
    );
    final text = receipt(over);
    expect(text, contains('Customer: Nadia'));
    expect(text, isNot(contains('Phone:')));
    expect(text, isNot(contains('Address:')));
  });

  test('a delivery with nothing captured prints no empty labels', () {
    final text = receipt(delivery(phone: null, address: null));
    expect(text, isNot(contains('Phone:')));
    expect(text, isNot(contains('Address:')));
    expect(text, isNot(contains('Channel:')));
    expect(text, isNot(contains('Driver:')));
  });

  test('the channel, its order number and the driver print when they are set', () {
    final text = receipt(
        delivery(channel: 'Talabat', companyNo: 'TLB-99182', driver: 'Hany'));
    expect(text, contains('Channel: Talabat #TLB-99182'));
    expect(text, contains('Driver: Hany'));
  });

  test('the kitchen ticket says who the bag is for and where it came from', () {
    final text = ticket(delivery(channel: 'Talabat', companyNo: 'TLB-99182'));
    expect(text, contains('DELIVERY'));
    expect(text, contains('For: Nadia'));
    expect(text, contains('Phone: 0100 123 4567'));
    expect(text, contains('Channel: Talabat #TLB-99182'));
  });

  test('a dine-in ticket is unchanged by any of this', () {
    final text = ticket(Order(
      deviceId: 'till-1',
      cashierId: 'sara',
      tableLabel: '4',
      customerName: 'Nadia',
      lines: [OrderLine(productId: 1, name: 'Pizza', quantity: 1, unitPrice: 100)],
    ));
    expect(text, contains('Table: 4'));
    expect(text, isNot(contains('For: Nadia')));
    expect(text, isNot(contains('Channel:')));
  });
}
