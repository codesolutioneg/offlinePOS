import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/db/data_reset.dart';
import 'package:offline_pos/core/lan/lan_event.dart';
import 'package:offline_pos/domain/order.dart';

import '../db/sqlite_loader.dart';
import 'shop.dart';

/// Clearing a trial's orders off every till, and deleting one till's data outright.
void main() {
  setUpAll(useSystemSqlite);

  late TestShop shop;
  setUp(() => shop = TestShop());
  tearDown(() => shop.close());

  Order rung(String deviceId, DateTime at, {String table = '5'}) => Order(
        deviceId: deviceId,
        cashierId: 'ana',
        tableLabel: table,
        createdAt: at,
      )
        ..state = OrderState.held
        ..lines.add(OrderLine(productId: 1, name: 'Pizza', quantity: 1, unitPrice: 100));

  /// What the till that pressed the button does, as the settings screen does it.
  void wipeEverywhere(TestTill till, DateTime now) {
    wipeOrderHistory(till.db);
    till.settings.historyWipedAt = now;
    till.settings.resetOrderNumbers();
    till.fabric.publish(LanEventKind.historyWipe, 'history-wipe',
        {'before': now.toIso8601String()});
  }

  test('a wipe on one till clears the orders on the other', () async {
    final a = shop.add('till-a');
    final b = shop.add('till-b');
    shop.introduceAll();
    final t0 = DateTime.utc(2026, 3, 1, 12);
    a.orders.save(rung('till-a', t0, table: '1'));
    b.orders.save(rung('till-b', t0, table: '2'));
    await shop.settle();
    expect(a.orders.heldAnywhere(), hasLength(2));
    expect(b.orders.heldAnywhere(), hasLength(2));

    wipeEverywhere(a, t0.add(const Duration(hours: 1)));
    await shop.settle();

    expect(a.orders.heldAnywhere(), isEmpty);
    expect(b.orders.heldAnywhere(), isEmpty);
    expect(b.settings.historyWipedAt, t0.add(const Duration(hours: 1)));
  });

  test('a sale rung after the wipe moment survives on a till that heard late',
      () async {
    final a = shop.add('till-a');
    final b = shop.add('till-b');
    shop.introduceAll();
    final t0 = DateTime.utc(2026, 3, 1, 12);
    final wipeAt = t0.add(const Duration(hours: 1));
    b.orders.save(rung('till-b', t0, table: '2'));
    await shop.settle();

    shop.unreachable.add('till-b');
    wipeEverywhere(a, wipeAt);
    final kept = rung('till-b', wipeAt.add(const Duration(minutes: 5)), table: '3');
    b.orders.save(kept);
    shop.unreachable.remove('till-b');
    await shop.settle();

    expect(b.orders.heldAnywhere().map((o) => o.uuid), [kept.uuid]);
    expect(a.orders.heldAnywhere().map((o) => o.uuid), [kept.uuid]);
  });

  test('a wiped sale does not come back from a till that was away', () async {
    final a = shop.add('till-a');
    final b = shop.add('till-b');
    shop.introduceAll();
    final t0 = DateTime.utc(2026, 3, 1, 12);
    shop.unreachable.add('till-b');
    b.orders.save(rung('till-b', t0, table: '2'));

    wipeEverywhere(a, t0.add(const Duration(hours: 1)));
    shop.unreachable.remove('till-b');
    await shop.settle();

    expect(a.orders.heldAnywhere(), isEmpty);
    expect(b.orders.heldAnywhere(), isEmpty);
  });

  test('a till that joins after the wipe does not read the old sales', () async {
    final a = shop.add('till-a');
    final t0 = DateTime.utc(2026, 3, 1, 12);
    a.orders.save(rung('till-a', t0));
    wipeEverywhere(a, t0.add(const Duration(hours: 1)));

    final c = shop.add('till-c');
    shop.introduceAll();
    await shop.settle();

    expect(c.orders.heldAnywhere(), isEmpty);
  });

  test('catching up names the till that could not be reached', () async {
    final a = shop.add('till-a');
    shop.add('till-b');
    shop.add('till-c', name: 'Bar');
    shop.introduceAll();
    shop.unreachable.add('till-c');

    final failed = await a.fabric.catchUp(a.peers.all);

    expect(failed.keys, ['till-c']);
  });

  group('deleting this till\'s data', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('pos-reset-'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('nothing happens until a reset is staged', () async {
      final db = File('${dir.path}/pos.db')..writeAsStringSync('x');
      expect(await PendingReset(db.path).apply(), isFalse);
      expect(db.existsSync(), isTrue);
    });

    test('a staged reset deletes the database and its journals at launch', () async {
      final path = '${dir.path}/pos.db';
      for (final s in ['', '-wal', '-shm', '.restore']) {
        File('$path$s').writeAsStringSync('x');
      }
      final reset = PendingReset(path);
      await reset.stage();
      expect(reset.isStaged, isTrue);

      expect(await PendingReset(path).apply(), isTrue);

      for (final s in ['', '-wal', '-shm', '.restore', '.reset']) {
        expect(File('$path$s').existsSync(), isFalse, reason: 'pos.db$s');
      }
    });
  });
}
