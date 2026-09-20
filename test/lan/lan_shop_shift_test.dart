import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/db/settings_store.dart';
import 'package:offline_pos/core/lan/lan_event.dart';
import 'package:offline_pos/core/lan/lan_shift_board.dart';
import 'package:offline_pos/core/lan/lan_wiring.dart';
import 'package:offline_pos/domain/table_section_config.dart';

import '../db/sqlite_loader.dart';
import 'shop.dart';

void main() {
  setUpAll(useSystemSqlite);

  late TestShop shop;
  setUp(() => shop = TestShop());
  tearDown(() => shop.close());

  void openShopShift(TestTill till, {required String date, String? cashier}) =>
      till.fabric.publish(
        LanEventKind.shiftLifecycle,
        LanNode.shopShiftRecord,
        LanShiftNotice(
          deviceId: till.deviceId,
          deviceName: till.name,
          businessDate: date,
          at: DateTime.utc(2026, 3, 1, 9),
          cashierId: cashier,
          action: LanShiftAction.open,
        ).toMap(),
      );

  void closeTheDay(TestTill till, {required String date, String? cashier}) =>
      till.fabric.publish(
        LanEventKind.shiftLifecycle,
        'day-close-${till.deviceId}',
        LanShiftNotice(
          deviceId: till.deviceId,
          deviceName: till.name,
          businessDate: date,
          at: DateTime.utc(2026, 3, 1, 23),
          cashierId: cashier,
          action: LanShiftAction.close,
        ).toMap(),
      );

  test('primary shop bundle makes secondary dishflow mirror ready', () async {
    final a = shop.add('till-a');
    final b = shop.add('till-b');
    a.settings.deviceRole = DeviceRole.primary;
    b.settings.deviceRole = DeviceRole.secondary;
    shop.introduceAll();

    a.settings.dishflowMirrorEnabled = true;
    a.settings.dishflowProjectId = 'odc-chat';
    a.settings.dishflowApiKey = 'key';
    a.settings.dishflowOdooConnectionId = 'conn1';
    a.settings.publishShopBundle();
    await shop.settle();

    expect(b.settings.dishflowMirrorReady, isTrue);
    expect(b.settings.dishflowProjectId, 'odc-chat');
    expect(b.settings.dishflowOdooConnectionId, 'conn1');
    expect(b.dishflow.isRegistered, isTrue);
  });

  test('opening a shift on A quiet-opens B', () async {
    final a = shop.add('till-a');
    final b = shop.add('till-b');
    shop.introduceAll();

    expect(b.shifts.currentOpenShift(), isNull);
    openShopShift(a, date: '2026-03-01', cashier: 'sara');
    await shop.settle();

    final open = b.shifts.currentOpenShift();
    expect(open, isNotNull);
    expect(open!.cashierId, 'sara');
    expect(open.openingFloat, 0);
  });

  test('closing on A quiet-closes B', () async {
    final a = shop.add('till-a');
    final b = shop.add('till-b');
    shop.introduceAll();

    b.shifts.openShift(openingFloat: 100, cashierId: 'local');
    expect(b.shifts.currentOpenShift(), isNotNull);

    closeTheDay(a, date: '2026-03-01');
    await shop.settle();

    expect(b.shifts.currentOpenShift(), isNull);
    expect(LanShiftBoard(b.settings).closedOn('2026-03-01'), isNotNull);
  });

  test('open after a partition lands once without duplicate drawers', () async {
    final a = shop.add('till-a');
    final b = shop.add('till-b');
    shop.introduceAll();
    shop.unreachable.add('till-b');

    openShopShift(a, date: '2026-03-01', cashier: 'sara');
    await shop.settle();
    expect(b.shifts.currentOpenShift(), isNull);

    shop.unreachable.remove('till-b');
    await shop.settle();
    expect(b.shifts.currentOpenShift()?.cashierId, 'sara');

    // Catch-up / second apply must not throw or open a second drawer.
    openShopShift(a, date: '2026-03-01', cashier: 'sara');
    await shop.settle();
    expect(b.shifts.currentOpenShift()?.cashierId, 'sara');
  });

  test('shop open clears the day-close nudge for that date', () async {
    final a = shop.add('till-a');
    final b = shop.add('till-b');
    shop.introduceAll();

    closeTheDay(a, date: '2026-03-01');
    await shop.settle();
    expect(LanShiftBoard(b.settings).closedOn('2026-03-01'), isNotNull);

    openShopShift(a, date: '2026-03-01', cashier: 'sara');
    await shop.settle();
    expect(LanShiftBoard(b.settings).closedOn('2026-03-01'), isNull);
    expect(b.shifts.currentOpenShift(), isNotNull);
  });
}
