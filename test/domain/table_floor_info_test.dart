import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/theme/app_colors.dart';
import 'package:offline_pos/core/theme/table_palette.dart';
import 'package:offline_pos/domain/order.dart';
import 'package:offline_pos/domain/table_floor_info.dart';

void main() {
  test('several tabs on one table sum money and take the strongest life', () {
    final unsent = Order(deviceId: 'a', cashierId: 's', tableLabel: '5')
      ..state = OrderState.held
      ..lines.add(OrderLine(
          productId: 1, name: 'A', quantity: 1, unitPrice: 10));
    final sent = Order(deviceId: 'a', cashierId: 's', tableLabel: '5')
      ..state = OrderState.held
      ..lines.add(OrderLine(
          productId: 2,
          name: 'B',
          quantity: 1,
          unitPrice: 20,
          printedToKitchen: true));
    final billed = Order(deviceId: 'a', cashierId: 's', tableLabel: '5')
      ..state = OrderState.held
      ..billPrintedAt = DateTime.utc(2026, 1, 1)
      ..lines.add(OrderLine(
          productId: 3, name: 'C', quantity: 1, unitPrice: 5));

    final info = TableFloorInfo.fromTabs([unsent, sent, billed]);
    expect(info.tabCount, 3);
    expect(info.total, 35);
    expect(info.life, TableFloorLife.billed);
  });

  test('the palette maps each derived life to its own colour', () {
    const palette = TablePalette();
    expect(palette.colorFor(null, occupied: false), AppColors.tableFree);
    expect(palette.colorFor(TableFloorLife.unsent, occupied: true),
        AppColors.tableOccupied);
    expect(palette.colorFor(TableFloorLife.sent, occupied: true),
        AppColors.tableSent);
    expect(palette.colorFor(TableFloorLife.billed, occupied: true),
        AppColors.tableBilled);
  });
}
