import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/db/database.dart';
import 'package:offline_pos/core/db/sqlite_outbox_store.dart';
import 'package:offline_pos/core/sync/batch_push.dart';
import 'package:offline_pos/domain/order.dart';

import '../db/sqlite_loader.dart';

/// When the shift goes out as one sales order, and what happens when it does not
/// land. The money question here is a narrow one: nothing may be marked booked
/// that the server has not acknowledged.
void main() {
  late Db db;
  late SqliteOutboxStore store;
  late List<Map<String, dynamic>> sent;
  late List<String> marked;
  var merging = true;
  String? shift = 'shift-1';
  Object? failWith;

  setUpAll(useSystemSqlite);
  setUp(() {
    db = Db.open(':memory:');
    store = SqliteOutboxStore(db);
    sent = [];
    marked = [];
    merging = true;
    shift = 'shift-1';
    failWith = null;
  });
  tearDown(() => db.close());

  BatchPush pusher() => BatchPush(
        outboxStore: store,
        send: (uuid, payload) async {
          if (failWith != null) throw failWith!;
          sent.add(payload);
        },
        enabled: () => merging,
        batchUuid: () => shift,
        onOrderBooked: marked.add,
      );

  Future<Order> queueASale({double price = 100}) async {
    final o = Order(deviceId: 'till-1', cashierId: 'sara')
      ..lines.add(OrderLine(
          productId: 10, odooProductId: 10, name: 'Pizza', quantity: 1, unitPrice: price))
      ..state = OrderState.paid;
    o.payments = [OrderPayment(methodId: 1, amount: o.total, label: 'Cash')];
    await store.append('order.push', o.uuid, o.toServerPayload());
    return o;
  }

  test('two queued sales leave as one payload and are marked together', () async {
    final a = await queueASale();
    final b = await queueASale(price: 250);

    expect(await pusher().run(), isTrue);
    expect(sent, hasLength(1));
    expect(sent.single['uuid'], 'shift-1');
    expect(marked, [a.uuid, b.uuid]);
    expect(await store.pending(), isEmpty, reason: 'nothing left for the drain');
  });

  test('a failed send leaves every sale queued and nothing marked', () async {
    await queueASale();
    await queueASale(price: 250);
    failWith = StateError('the line went down mid-close');

    await expectLater(pusher().run(), throwsA(isA<StateError>()));
    expect(marked, isEmpty, reason: 'a sale is only booked when the server says so');
    expect(await store.pending(), hasLength(2),
        reason: 'the night has to still be there for the next attempt');
  });

  test('the switch off means the queue is left to the ordinary push', () async {
    await queueASale();
    await queueASale();
    merging = false;

    expect(await pusher().run(), isFalse);
    expect(sent, isEmpty);
    expect(await store.pending(), hasLength(2));
  });

  test('no shift is no key, and no key is no batch', () async {
    await queueASale();
    await queueASale();
    shift = null;

    expect(await pusher().run(), isFalse);
    expect(sent, isEmpty);
  });

  test('a queue longer than the bound goes out the ordinary way', () async {
    final small = BatchPush(
      outboxStore: store,
      send: (uuid, payload) async => sent.add(payload),
      enabled: () => true,
      batchUuid: () => 'shift-1',
      onOrderBooked: marked.add,
      maxOrders: 2,
    );
    for (var i = 0; i < 3; i++) {
      await queueASale();
    }

    expect(await small.run(), isFalse,
        reason: 'a window that was cut short would leave sales out of the batch');
    expect(sent, isEmpty);
    expect(await store.pending(limit: 10), hasLength(3));
  });

  test('a retry after a lost acknowledgement rebuilds the same key', () async {
    await queueASale();
    await queueASale(price: 250);
    failWith = StateError('timed out waiting for the answer');
    await expectLater(pusher().run(), throwsA(isA<StateError>()));

    failWith = null;
    expect(await pusher().run(), isTrue);
    // The same night under the same key: what stops the server booking it twice.
    expect(sent.single['uuid'], 'shift-1');
  });
}
