import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/sync/dishflow_firestore_sender.dart';
import 'package:offline_pos/core/sync/dishflow_mirror.dart';
import 'package:offline_pos/core/sync/dishflow_sale_mapper.dart';
import 'package:offline_pos/domain/order.dart';

void main() {
  Order paidOrder() {
    final o = Order(
      uuid: '11111111-2222-3333-4444-555555555555',
      deviceId: 'till-A',
      cashierId: 'c1',
      type: OrderType.dineIn,
      orderNo: '1508-0007-A1B',
      tableLabel: 'T3',
      customerName: 'Sara',
      serviceChargePercent: 12,
      discountPercent: 10,
      discountReason: 'vip',
      lines: [
        OrderLine(
          productId: 10,
          odooProductId: 10,
          name: 'Burger',
          quantity: 2,
          unitPrice: 50,
          taxRate: 14,
        ),
      ],
      payments: const [
        OrderPayment(methodId: -1, amount: 100, label: 'Cash'),
      ],
    )..state = OrderState.paid;
    return o;
  }

  test('docId is stable for the same sale', () {
    final a = DishflowSaleMapper.docId(
      odooConnectionId: 'conn1',
      userId: 'offlinepos_till-A',
      orderId: '11111111-2222-3333-4444-555555555555',
      orderNumber: '1508-0007-A1B',
    );
    final b = DishflowSaleMapper.docId(
      odooConnectionId: 'conn1',
      userId: 'offlinepos_till-A',
      orderId: '11111111-2222-3333-4444-555555555555',
      orderNumber: '1508-0007-A1B',
    );
    expect(a, b);
    expect(a, 'conn1_offlinepos_till-A_1508-0007-A1B');
  });

  test('sales fields carry what Dishflow Flash reads', () {
    final o = paidOrder();
    final fields = DishflowSaleMapper.toSalesFields(
      o,
      odooConnectionId: 'conn1',
      userId: DishflowSaleMapper.mirrorUserId(o.deviceId),
      orderNumber: o.orderNo!,
      branchName: 'Madinaty',
    );
    expect(fields['status'], 'sale');
    expect(fields['source'], 'offline_pos');
    expect(fields['posOrderId'], o.uuid);
    expect(fields['orderNumber'], '1508-0007-A1B');
    expect(fields['odooConnectionId'], 'conn1');
    expect(fields['amount'], o.total);
    expect(fields['businessDateKey'], o.businessDay.key);
    expect(fields['sessionId'], 'session_${o.businessDay.key}_offlinepos');
    expect(fields['tableLabel'], 'T3');
    expect(fields['customer_name'], 'Sara');
    expect(fields['paymentMethod'], 'Cash');
    expect(fields['items'], isA<List>());
    expect((fields['items'] as List).single['productName'], 'Burger');
  });

  test('delivery orders stamp delivery_status', () {
    final o = paidOrder()..type = OrderType.delivery;
    final fields = DishflowSaleMapper.toSalesFields(
      o,
      odooConnectionId: 'c',
      userId: 'u',
      orderNumber: 'n',
    );
    expect(fields['delivery_status'], 'received');
    expect(fields['orderType'], 'delivery');
  });

  test('outbox payload keeps transport coords next to fields', () {
    final payload = DishflowSaleMapper.toOutboxPayload(
      paidOrder(),
      projectId: 'odc-chat',
      apiKey: 'key',
      odooConnectionId: 'conn1',
    );
    expect(payload['project_id'], 'odc-chat');
    expect(payload['api_key'], 'key');
    expect(payload['doc_id'], isNotEmpty);
    expect(payload['fields'], isA<Map>());
  });

  test('REST encode covers scalars lists and maps', () {
    final encoded = DishflowFirestoreSender.encodeValue({
      'amount': 12.5,
      'ok': true,
      'n': 3,
      'name': 'x',
      'items': [
        {'productName': 'A'},
      ],
    });
    expect(encoded['mapValue'], isNotNull);
    final fields =
        (encoded['mapValue'] as Map)['fields'] as Map<String, dynamic>;
    expect(fields['amount']['doubleValue'], 12.5);
    expect(fields['ok']['booleanValue'], isTrue);
    expect(fields['n']['integerValue'], '3');
    expect(fields['name']['stringValue'], 'x');
    expect(fields['items']['arrayValue'], isNotNull);
  });

  test('mirror kind is distinct from order.push', () {
    expect(DishflowMirror.kind, 'dishflow.sale.push');
    expect(DishflowMirror.kind, isNot(equals('order.push')));
  });
}
