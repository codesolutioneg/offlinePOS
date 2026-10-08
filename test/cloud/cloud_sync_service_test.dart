import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:offline_pos/core/audit/audit_log.dart';
import 'package:offline_pos/core/cloud/cloud_client.dart';
import 'package:offline_pos/core/cloud/cloud_sync_service.dart';
import 'package:offline_pos/core/cloud/cloud_sync_state.dart';
import 'package:offline_pos/core/cloud/report_lookups.dart';
import 'package:offline_pos/core/db/database.dart';
import 'package:offline_pos/core/db/stress_purge.dart';
import 'package:offline_pos/domain/catalogue.dart';

import '../db/sqlite_loader.dart';

/// The server's sync route, in memory: what it holds, keyed the way it keys.
class FakeSync {
  bool offline = false;
  final Map<String, Map<String, Object?>> held = {};
  final List<List<Map<String, Object?>>> batches = [];

  /// Runs while a batch is on the wire, before the server answers.
  void Function()? during;

  Future<http.Response> handle(http.Request r) async {
    if (offline) throw const SocketException('no route to host');
    if (r.headers['authorization'] == null) {
      return http.Response(jsonEncode({'error': 'device is not paired'}), 401);
    }
    final records = ((jsonDecode(r.body) as Map)['records'] as List)
        .cast<Map<String, dynamic>>();
    during?.call();
    batches.add(records);
    for (final rec in records) {
      held['${rec['kind']}/${rec['key']}'] = rec;
    }
    return http.Response(jsonEncode({'stored': records.length}), 200,
        headers: {'content-type': 'application/json'});
  }

  Map<String, Object?>? payload(String kind, String key) =>
      (held['$kind/$key']?['payload'] as Map?)?.cast<String, Object?>();
}

void main() {
  late Directory dir;
  late Db db;
  late FakeSync server;
  late MemoryCloudSyncStateStore state;
  String? token;
  var menu = const ReportLookups(shopName: 'Cairo');

  setUpAll(useSystemSqlite);
  setUp(() {
    dir = Directory.systemTemp.createTempSync('pos-sync-test');
    db = Db.open('${dir.path}${Platform.pathSeparator}pos.db');
    server = FakeSync();
    state = MemoryCloudSyncStateStore();
    token = 'tok-1';
    menu = const ReportLookups(shopName: 'Cairo');
  });
  tearDown(() {
    db.close();
    dir.deleteSync(recursive: true);
  });

  CloudSyncService service({int batchSize = 500}) => CloudSyncService(
        db: db,
        state: state,
        deviceId: 'till-1',
        connection: () async =>
            token == null ? null : (url: 'https://cloud.test', token: token!),
        lookups: () => menu,
        clientFor: (url) => CloudClient(url, client: MockClient(server.handle)),
        batchSize: batchSize,
      );

  void sale(String uuid,
      {String device = 'till-1', String state = 'paid', String note = ''}) {
    db.raw.execute(
      'INSERT INTO orders (uuid, device_id, cashier_id, created_at, state, server_id, total, payload) '
      'VALUES (?, ?, ?, ?, ?, NULL, ?, ?) '
      'ON CONFLICT(uuid) DO UPDATE SET state = excluded.state, payload = excluded.payload',
      [
        uuid,
        device,
        'c1',
        '2026-10-08T10:00:00.000Z',
        state,
        50.0,
        jsonEncode({'uuid': uuid, 'state': state, 'note': note, 'total': 50.0}),
      ],
    );
  }

  int pending() =>
      db.raw.select('SELECT COUNT(*) AS c FROM cloud_pending').first['c'] as int;

  test('an unpaired till sends nothing and keeps nothing waiting', () async {
    token = null;
    sale('o1');
    expect(pending(), 1);
    expect(await service().runNow(), CloudSyncOutcome.notConfigured);
    expect(pending(), 0);
    expect(server.batches, isEmpty);
  });

  test('the first pass sends the whole history: own sales, drawers, clock-ins, audit',
      () async {
    token = null;
    sale('mine');
    sale('other-till', device: 'till-2');
    sale('tab', state: 'held');
    sale('lab', note: kStressNote);
    db.raw.execute(
        "INSERT INTO shifts (id, uuid, opened_at, closed_at, opening_float, cashier_id, movements, closing_counted) "
        "VALUES ('SH1', 'u-sh1', '2026-10-08T08:00:00.000Z', NULL, 100, 'c1', '[]', NULL)");
    db.raw.execute(
        "INSERT INTO attendance (staff_id, clock_in) VALUES ('c1', '2026-10-08T07:55:00.000Z')");
    AuditLog(db).record('c1', 'order.cancelled', detail: 'x|why');
    // Queued before pairing and forgotten: the history pass has to find it all.
    await service().runNow();
    expect(pending(), 0);

    token = 'tok-1';
    expect(await service().runNow(), CloudSyncOutcome.synced);
    expect(pending(), 0);
    expect(server.payload('order', 'mine')?['state'], 'paid');
    expect(server.held.containsKey('order/other-till'), isFalse);
    expect(server.held.containsKey('order/tab'), isFalse);
    expect(server.held.containsKey('order/lab'), isFalse);
    expect(server.payload('shift', 'till-1:SH1')?['opening_float'], 100);
    expect(server.held.containsKey('attendance/c1|2026-10-08T07:55:00.000Z'), isTrue);
    final audit = server.held.keys.where((k) => k.startsWith('audit/till-1:'));
    expect(audit, hasLength(1));
    expect(server.payload('shop', 'branch')?['name'], 'Cairo');
  });

  test('an idle till sends nothing more, and a change sends only itself', () async {
    sale('o1');
    final sync = service();
    expect(await sync.runNow(), CloudSyncOutcome.synced);
    final first = server.batches.length;

    expect(await sync.runNow(), CloudSyncOutcome.idle);
    expect(server.batches.length, first);

    sale('o2');
    expect(await sync.runNow(), CloudSyncOutcome.synced);
    expect(server.batches.length, first + 1);
    expect(server.batches.last.map((r) => r['key']), ['o2']);
  });

  test('a reopened sale is sent again so the site drops it', () async {
    sale('o1');
    await service().runNow();
    sale('o1', state: 'held');
    expect(pending(), 1);
    await service().runNow();
    expect(server.payload('order', 'o1')?['state'], 'held');
  });

  test('a changed menu is sent again, an unchanged one is not', () async {
    final sync = service();
    await sync.runNow();
    expect(await sync.runNow(), CloudSyncOutcome.idle);
    menu = const ReportLookups(
        shopName: 'Cairo', categories: [Category(id: 1, name: 'Drinks')]);
    expect(await sync.runNow(), CloudSyncOutcome.synced);
    expect(server.batches.last.map((r) => r['kind']), ['categories']);
    final back = ReportLookups.fromRecords([
      (kind: 'categories', payload: server.payload('categories', 'branch')!),
    ]);
    expect(back.categories.single.name, 'Drinks');
  });

  test('an outage keeps the changes waiting until the line is back', () async {
    sale('o1');
    server.offline = true;
    final sync = service();
    expect(await sync.runNow(), CloudSyncOutcome.failed);
    expect(pending(), greaterThan(0));
    expect(sync.status().lastError, isNotNull);

    server.offline = false;
    expect(await sync.runNow(), CloudSyncOutcome.synced);
    expect(pending(), 0);
    expect(server.held.containsKey('order/o1'), isTrue);
  });

  test('a sale changed while its batch was on the wire is sent again', () async {
    sale('o1');
    server.during = () {
      server.during = null;
      sale('o1', state: 'synced');
    };
    final sync = service();
    expect(await sync.runNow(), CloudSyncOutcome.synced);
    expect(server.payload('order', 'o1')?['state'], 'paid');
    expect(pending(), 1);
    await sync.runNow();
    expect(server.payload('order', 'o1')?['state'], 'synced');
    expect(pending(), 0);
  });

  test('a long history goes in batches', () async {
    for (var i = 0; i < 7; i++) {
      sale('o$i');
    }
    await service(batchSize: 3).runNow();
    expect(server.batches.where((b) => b.first['kind'] == 'order').map((b) => b.length),
        [3, 3, 1]);
    expect(pending(), 0);
  });

  test('pairing again queues the history again', () async {
    sale('o1');
    await service().runNow();
    server.held.clear();
    token = 'tok-2';
    await service().runNow();
    expect(server.held.containsKey('order/o1'), isTrue);
    expect(server.held.containsKey('shop/branch'), isTrue);
  });
}
