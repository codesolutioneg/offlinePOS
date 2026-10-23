import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/audit/audit_log.dart';
import 'package:offline_pos/core/cloud/cloud_backup_service.dart';
import 'package:offline_pos/core/cloud/cloud_backup_state.dart';
import 'package:offline_pos/core/cloud/cloud_secrets.dart';
import 'package:offline_pos/core/cloud/cloud_sync_service.dart';
import 'package:offline_pos/core/cloud/cloud_sync_state.dart';
import 'package:offline_pos/core/cloud/report_lookups.dart';
import 'package:offline_pos/core/db/attendance_store.dart';
import 'package:offline_pos/core/db/database.dart';
import 'package:offline_pos/core/db/order_store.dart';
import 'package:offline_pos/core/db/shift_store.dart';
import 'package:offline_pos/domain/catalogue.dart';
import 'package:offline_pos/domain/order.dart';

import '../db/sqlite_loader.dart';

/// A till with a few days of trade, paired to a real server and synced, so the
/// reports site has something to show. Skipped unless pointed at one:
///
/// ```
/// flutter test test/cloud/live_sync_test.dart \
///   --dart-define=CLOUD_E2E_URL=http://127.0.0.1:4555 \
///   --dart-define=CLOUD_E2E_CODE=<branch pairing code>
/// ```
const _url = String.fromEnvironment('CLOUD_E2E_URL');
const _code = String.fromEnvironment('CLOUD_E2E_CODE');

void main() {
  setUpAll(useSystemSqlite);

  test('a till with three days of trade syncs to the server', () async {
    final dir = Directory.systemTemp.createTempSync('pos-live-sync');
    final db = Db.open('${dir.path}${Platform.pathSeparator}pos.db');
    addTearDown(() {
      db.close();
      dir.deleteSync(recursive: true);
    });
    const device = 'live-till-1';
    final orders = OrderStore(db, ownDeviceId: device);
    final shifts = ShiftStore(db);
    final attendance = AttendanceStore(db);
    final audit = AuditLog(db);

    const menu = [
      (1, 'Koshary', 45.0, 10),
      (2, 'Falafel sandwich', 15.0, 10),
      (3, 'Tea', 10.0, 20),
      (4, 'Mango juice', 30.0, 20),
      (5, 'Om Ali', 40.0, 30),
    ];
    final now = DateTime.now();
    var n = 0;
    for (var day = 2; day >= 0; day--) {
      final opened = DateTime(now.year, now.month, now.day - day, 9).toUtc();
      final shift = shifts.openShift(
          openingFloat: 500, cashierId: 'sara', id: 'SH-live-$day', at: opened);
      db.raw.execute("UPDATE shifts SET movements = ? WHERE id = ?", [
        '[{"type":"out","amount":${60 + day * 5},"reason":"Gas","category":"Supplies","at":"${opened.add(const Duration(hours: 2)).toIso8601String()}"}]',
        shift.id,
      ]);
      attendance.applyRemote({
        'staff_id': 'sara',
        'clock_in': opened.subtract(const Duration(minutes: 5)).toIso8601String(),
        'clock_out': opened.add(const Duration(hours: 9)).toIso8601String(),
      });
      for (var i = 0; i < 12; i++) {
        final at = opened.add(Duration(minutes: 20 + i * 35));
        if (at.isAfter(now.toUtc())) break;
        n++;
        final order = Order(
          deviceId: device,
          cashierId: i.isEven ? 'sara' : 'omar',
          createdAt: at,
          type: OrderType.values[i % 3],
          tableLabel: i % 3 == 0 ? 'T${i + 1}' : null,
          orderNo: '$n',
        );
        for (var k = 0; k < 1 + i % 3; k++) {
          final (id, name, price, category) = menu[(i + k) % menu.length];
          order.lines.add(OrderLine(
              productId: id,
              name: name,
              quantity: 1 + (k % 2).toDouble(),
              unitPrice: price,
              categoryId: category));
        }
        order.payments.add(OrderPayment(
            methodId: i % 4 == 0 ? -2 : -1,
            amount: order.total,
            label: i % 4 == 0 ? 'Card' : 'Cash'));
        order.state = OrderState.paid;
        orders.save(order, announce: false);
        if (i == 5) audit.record('omar', 'line.voided', detail: '${order.uuid}|Tea x1|customer changed mind');
      }
      if (day > 0) shifts.closeShift(countedCash: 1500, at: opened.add(const Duration(hours: 9)));
    }

    final secrets = MemoryCloudSecrets();
    final backup = CloudBackupService(
      db: db,
      state: MemoryCloudBackupStateStore(),
      secrets: secrets,
      deviceId: device,
      appVersion: 'live-test',
      deviceName: () => 'Live test till',
    );
    await backup.pair(url: _url, pairCode: _code);
    final sync = CloudSyncService(
      db: db,
      state: MemoryCloudSyncStateStore(),
      deviceId: device,
      connection: backup.connectionDetails,
      lookups: () => const ReportLookups(
        shopName: 'Demo shop',
        categories: [
          Category(id: 10, name: 'Sandwiches & mains', sequence: 1),
          Category(id: 20, name: 'Drinks', sequence: 2),
          Category(id: 30, name: 'Desserts', sequence: 3),
        ],
        costs: {1: 18, 2: 5, 3: 2, 4: 9, 5: 14},
        staffNames: {'sara': 'Sara', 'omar': 'Omar'},
        cashTenderIds: {-1},
      ),
    );
    expect(await sync.runNow(), CloudSyncOutcome.synced, reason: '${sync.status().lastError}');
    expect(sync.pending, 0);
    expect(await sync.runNow(), CloudSyncOutcome.idle);
  }, skip: _url.isEmpty || _code.isEmpty ? 'needs CLOUD_E2E_URL and CLOUD_E2E_CODE' : false);
}
