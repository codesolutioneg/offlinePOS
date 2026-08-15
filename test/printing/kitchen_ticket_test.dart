import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/printing/kitchen_ticket.dart';
import 'package:offline_pos/domain/order.dart';

import 'strip_escpos.dart';

void main() {
  OrderLine line(int productId, {int? categoryId, String name = 'Item'}) => OrderLine(
        productId: productId,
        name: name,
        quantity: 1,
        unitPrice: 0,
        categoryId: categoryId,
      );

  group('routeToStations', () {
    test('an unmapped line falls back to the default kitchen station', () {
      final l = line(1, categoryId: 5);
      final routed = routeToStations([l]);
      expect(routed, {'kitchen': [l]});
    });

    test('a custom fallback station is used when nothing else routes the line', () {
      final l = line(1, categoryId: 5);
      final routed = routeToStations([l], fallbackStation: 'expo');
      expect(routed, {'expo': [l]});
    });

    test('a category mapped to one station routes its lines there', () {
      final mains = line(1, categoryId: 1);
      final drinks = line(2, categoryId: 2);
      final routed = routeToStations(
        [mains, drinks],
        categoryToStations: {1: ['grill'], 2: ['bar']},
      );
      expect(routed['grill'], [mains]);
      expect(routed['bar'], [drinks]);
    });

    test('a category mapped to several stations puts its line under every one', () {
      final shared = line(1, categoryId: 1);
      final routed = routeToStations(
        [shared],
        categoryToStations: {1: ['grill', 'expo']},
      );
      expect(routed['grill'], [shared]);
      expect(routed['expo'], [shared]);
      // The same OrderLine instance is shared across stations rather than
      // copied, so marking it fired at one printer must not silently mark it
      // fired for the others too - that is the caller's job to get right, but
      // this test pins that the reference is genuinely the same object.
      expect(identical(routed['grill']!.single, routed['expo']!.single), isTrue);
    });

    test('a product override wins over its category routing', () {
      final special = line(1, categoryId: 1);
      final routed = routeToStations(
        [special],
        categoryToStations: {1: ['grill']},
        productToStations: {1: ['bar']},
      );
      expect(routed.containsKey('grill'), isFalse);
      expect(routed['bar'], [special]);
    });

    test('a product override to several stations fans the line out to all of them', () {
      final special = line(7, categoryId: 1);
      final routed = routeToStations(
        [special],
        categoryToStations: {1: ['grill']},
        productToStations: {7: ['bar', 'expo']},
      );
      expect(routed.containsKey('grill'), isFalse);
      expect(routed['bar'], [special]);
      expect(routed['expo'], [special]);
    });

    test('an empty category station list falls back rather than dropping the line', () {
      final l = line(1, categoryId: 1);
      final routed = routeToStations([l], categoryToStations: {1: const []});
      expect(routed['kitchen'], [l]);
    });

    test('lines for different stations do not leak into each other\'s lists', () {
      final a = line(1, categoryId: 1);
      final b = line(2, categoryId: 2);
      final c = line(3, categoryId: 1);
      final routed = routeToStations(
        [a, b, c],
        categoryToStations: {1: ['grill'], 2: ['bar']},
      );
      expect(routed['grill'], [a, c]);
      expect(routed['bar'], [b]);
    });
  });

  group('the number on the paper', () {
    Order numbered({String? orderNo}) => Order(
          deviceId: 'till-1',
          cashierId: 'sara',
          orderNo: orderNo,
          lines: [OrderLine(productId: 1, name: 'Pizza', quantity: 1, unitPrice: 100)],
        );

    test('the kitchen ticket carries the number the counter will call', () {
      final text =
          strippedText(KitchenTicketBuilder().build(numbered(orderNo: '1508-007-A1B')));
      expect(text, contains('#1508-007-A1B'));
    });

    test('a cancel slip names the same order the kitchen was given', () {
      final order = numbered(orderNo: '1508-007-A1B');
      final text = strippedText(
          KitchenTicketBuilder().buildVoid(order, order.lines.first, 'wrong table'));
      expect(text, contains('#1508-007-A1B'));
    });

    test('an unnumbered order still prints a reference', () {
      final order = numbered();
      final text = strippedText(KitchenTicketBuilder().build(order));
      expect(text, contains('#${order.displayNo}'));
    });
  });
}
