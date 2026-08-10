import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/domain/identity.dart';
import 'package:offline_pos/domain/order.dart';

void main() {
  test('identity is unique and stable', () {
    final ids = List.generate(500, (_) => Uuid.v4());
    expect(ids.toSet().length, 500);
    expect(ids.first, matches(RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')));
  });

  test('a line keeps the identity it was created with', () {
    final line = OrderLine(productId: 1, name: 'Pizza', quantity: 1, unitPrice: 250);
    final again = OrderLine.fromMap(line.toMap());
    expect(again.uuid, line.uuid);
  });

  test('modifiers scale with the parent quantity', () {
    final line = OrderLine(
      productId: 1, name: 'Pizza', quantity: 2, unitPrice: 250,
      modifiers: [
        OrderModifier(modifierId: 1, name: 'Cheese', quantity: 1, unitPrice: 7),
        OrderModifier(modifierId: 2, name: 'Extra', quantity: 1, unitPrice: 25),
      ],
    );
    // 2 x (250 + 7 + 25)
    expect(line.total, 564);
  });

  test('an order survives a serialise/restore cycle intact', () {
    final order = Order(deviceId: 'till-1', cashierId: 'c1', lines: [
      OrderLine(productId: 1, name: 'Pizza', quantity: 1, unitPrice: 250, modifiers: [
        OrderModifier(modifierId: 1, name: 'Cheese', quantity: 1, unitPrice: 7),
      ]),
    ]);
    final restored = Order.fromMap(order.toMap());
    expect(restored.uuid, order.uuid);
    expect(restored.total, order.total);
    expect(restored.lines.single.modifiers.single.name, 'Cheese');
  });

  test('a modifier carries its product id to the server so it books as a line', () {
    final order = Order(deviceId: 'till-1', cashierId: 'c1', lines: [
      OrderLine(productId: 1, name: 'Pizza', quantity: 2, unitPrice: 250, modifiers: [
        // productId is the product behind the modifier; the server needs it to move
        // stock and invoice the extra, not just the modifier's own catalogue id.
        OrderModifier(modifierId: 1, productId: 88, name: 'Cheese', quantity: 1, unitPrice: 7),
      ]),
    ]);
    final restored = Order.fromMap(order.toMap());
    expect(restored.lines.single.modifiers.single.productId, 88);
    final sent = order.toServerPayload();
    final mod = ((sent['lines'] as List).first as Map)['modifiers'] as List;
    expect((mod.first as Map)['product_id'], 88);
  });

  test('the server id is a reference, never the identity', () {
    final order = Order(deviceId: 'till-1', cashierId: 'c1')..serverId = 42;
    final restored = Order.fromMap(order.toMap());
    expect(restored.serverId, 42);
    expect(restored.uuid, order.uuid);
  });
}
