import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/domain/catalogue.dart';
import 'package:offline_pos/domain/order.dart';
import 'package:offline_pos/features/reports/driver_sales_analysis.dart';

void main() {
  final food = Category(id: 1, name: 'Food');
  final burgers = Category(id: 2, name: 'Burgers', parentId: 1);
  final drinks = Category(id: 3, name: 'Beverages');
  final soda = Category(id: 4, name: 'Soda', parentId: 3);

  Order delivery({
    required String driverId,
    required String driverName,
    int guests = 1,
    required List<OrderLine> lines,
  }) =>
      Order(
        deviceId: 't1',
        cashierId: 'c1',
        type: OrderType.storeDelivery,
        state: OrderState.paid,
        driverId: driverId,
        driverName: driverName,
        guestCount: guests,
        lines: lines,
      );

  test('rolls delivery sales by driver and menu type for all drivers', () {
    final orders = [
      delivery(
        driverId: 'd1',
        driverName: 'yaser',
        guests: 2,
        lines: [
          OrderLine(
              productId: 10,
              name: 'Burger',
              quantity: 2,
              unitPrice: 100,
              categoryId: burgers.id),
          OrderLine(
              productId: 11,
              name: 'Cola',
              quantity: 1,
              unitPrice: 20,
              categoryId: soda.id),
        ],
      ),
      delivery(
        driverId: 'd2',
        driverName: 'mostafa',
        lines: [
          OrderLine(
              productId: 10,
              name: 'Burger',
              quantity: 1,
              unitPrice: 100,
              categoryId: burgers.id),
        ],
      ),
      // Dine-in ignored.
      Order(
        deviceId: 't1',
        cashierId: 'c1',
        type: OrderType.dineIn,
        state: OrderState.paid,
        driverId: 'd1',
        driverName: 'yaser',
        lines: [
          OrderLine(productId: 10, name: 'Burger', quantity: 1, unitPrice: 50),
        ],
      ),
    ];

    final blocks = driverSalesAnalysis(
      orders,
      [food, burgers, drinks, soda],
    );
    expect(blocks, hasLength(2));
    expect(blocks.first.driverName, 'yaser');
    expect(blocks.first.checks, 1);
    expect(blocks.first.customers, 2);
    expect(blocks.first.totalSales, closeTo(220, 0.01));
    expect(blocks.first.groups.map((g) => g.groupName).toList(),
        containsAll(['Food', 'Beverages']));

    final only = driverSalesAnalysis(
      orders,
      [food, burgers, drinks, soda],
      driverId: 'd2',
    );
    expect(only, hasLength(1));
    expect(only.single.driverName, 'mostafa');
    expect(only.single.totalSales, closeTo(100, 0.01));
  });

  test('matches a driver by stamped name when id differs', () {
    final order = delivery(
      driverId: 'old-id',
      driverName: 'Yaser',
      lines: [
        OrderLine(
            productId: 10,
            name: 'Burger',
            quantity: 1,
            unitPrice: 50,
            categoryId: burgers.id),
      ],
    );
    expect(
      orderBelongsToDriver(order, driverId: 'new-id', driverName: 'yaser'),
      isTrue,
    );
    final blocks = driverSalesAnalysis(
      [order],
      [food, burgers],
      driverId: 'new-id',
      driverName: 'yaser',
    );
    expect(blocks, hasLength(1));
    expect(blocks.single.totalSales, closeTo(50, 0.01));
  });
}
