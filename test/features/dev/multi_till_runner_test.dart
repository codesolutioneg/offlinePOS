import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:offline_pos/core/cloud/report_lookups.dart';
import 'package:offline_pos/core/db/catalogue_store.dart';
import 'package:offline_pos/core/db/database.dart';
import 'package:offline_pos/domain/catalogue.dart';
import 'package:offline_pos/features/dev/multi_till/multi_till_runner.dart';

import '../../db/sqlite_loader.dart';

/// A shop with several points of sale: every till ends up with every sale over
/// the LAN, and each sale reaches the reports site once, from the till that rang it.
void main() {
  late Db db;
  late CatalogueStore catalogue;

  setUpAll(useSystemSqlite);
  setUp(() {
    db = Db.open(':memory:');
    catalogue = CatalogueStore(db)
      ..replaceAll(
        categories: const [Category(id: 1, name: 'Food')],
        products: const [
          Product(id: 11, name: 'Burger', price: 50, categoryId: 1),
          Product(id: 12, name: 'Fries', price: 20, categoryId: 1),
          Product(id: 13, name: 'Cola', price: 15, categoryId: 1),
          Product(id: 14, name: 'Free water', price: 0, categoryId: 1),
        ],
        groups: const [],
        productGroupIds: const {},
        refreshedAt: DateTime.now().toUtc(),
      );
  });
  tearDown(() => db.close());

  MultiTillDeps deps({http.Client? cloud}) => MultiTillDeps(
        catalogue: catalogue,
        staff: const ['ali', 'mona'],
        lookups: () => const ReportLookups(shopName: 'Test'),
        appVersion: 'test',
        cloudHttp: cloud,
      );

  test('every till holds every sale, with no Odoo and no upload', () async {
    final report = await MultiTillRunner(deps: deps(), pace: Duration.zero).run(
      const MultiTillConfig(tills: 3, cashiers: 2, sessions: 2, ordersPerSession: 5, sendToOdoo: false),
    );

    expect(report.problems, isEmpty);
    expect(report.rung, hasLength(30));
    expect(report.sessions, hasLength(6));
    expect(report.sessions.every((s) => s.orders == 5), isTrue);
    for (var i = 1; i <= 3; i++) {
      expect(report.replicated[i], 20, reason: 'POS $i holds the other two tills\' sales');
    }
  });

  test('each sale is uploaded once, by the till that rang it', () async {
    final paired = <String>[];
    final stored = <String, Set<String>>{};
    final server = MockClient((r) async {
      final body = jsonDecode(r.body) as Map<String, dynamic>;
      if (r.url.path == '/v1/devices/pair') {
        expect(body['pair_code'], 'BRANCH-CODE');
        paired.add(body['device_id'] as String);
        return http.Response(
            jsonEncode({'token': 'tok-${body['device_id']}', 'shop': {'name': 'Test'}}), 200,
            headers: {'content-type': 'application/json'});
      }
      final device = r.headers['authorization']!.split('tok-').last;
      final records = (body['records'] as List).cast<Map<String, dynamic>>();
      for (final rec in records.where((x) => x['kind'] == 'order')) {
        stored.putIfAbsent(rec['key'] as String, () => {}).add(device);
      }
      return http.Response(jsonEncode({'stored': records.length}), 200,
          headers: {'content-type': 'application/json'});
    });

    final report = await MultiTillRunner(deps: deps(cloud: server), pace: Duration.zero).run(
      const MultiTillConfig(
        tills: 4,
        cashiers: 2,
        sessions: 3,
        ordersPerSession: 4,
        sendToOdoo: false,
        cloudUrl: 'https://reports.test',
        pairCode: 'BRANCH-CODE',
      ),
    );

    expect(report.problems, isEmpty);
    expect(paired, unorderedEquals(['stress-pos-1', 'stress-pos-2', 'stress-pos-3', 'stress-pos-4']));
    expect(report.rung, hasLength(48));
    expect(stored.keys.toSet(), report.rung.keys.toSet());
    for (final e in stored.entries) {
      expect(e.value, {report.rung[e.key]}, reason: 'sale ${e.key} came from its own till only');
    }
    expect(report.duplicateUploads, 0);
    expect(report.missingUploads, 0);
  });

  test('tills run with the network down catch up once it is back, once each', () async {
    var online = false;
    final stored = <String, Set<String>>{};
    final server = MockClient((r) async {
      if (!online) throw http.ClientException('Failed host lookup: reports.test');
      final body = jsonDecode(r.body) as Map<String, dynamic>;
      if (r.url.path == '/v1/devices/pair') {
        return http.Response(
            jsonEncode({'token': 'tok-${body['device_id']}', 'shop': {'name': 'Test'}}), 200,
            headers: {'content-type': 'application/json'});
      }
      final device = r.headers['authorization']!.split('tok-').last;
      final records = (body['records'] as List).cast<Map<String, dynamic>>();
      for (final rec in records.where((x) => x['kind'] == 'order')) {
        stored.putIfAbsent(rec['key'] as String, () => {}).add(device);
      }
      return http.Response(jsonEncode({'stored': records.length}), 200,
          headers: {'content-type': 'application/json'});
    });

    final run = await MultiTillRunner(deps: deps(cloud: server), pace: Duration.zero).start(
      const MultiTillConfig(
        tills: 3,
        cashiers: 2,
        sessions: 2,
        ordersPerSession: 5,
        sendToOdoo: false,
        cloudUrl: 'https://reports.test',
        pairCode: 'BRANCH-CODE',
      ),
    );
    addTearDown(run.close);

    expect(run.settled, isFalse);
    expect(run.report.problems, isNotEmpty);
    expect(stored, isEmpty);

    // Still down: a retry changes nothing and loses nothing.
    await run.retry();
    expect(run.settled, isFalse);
    expect(run.report.missingUploads, 30);

    online = true;
    await run.retry();

    expect(run.settled, isTrue);
    expect(run.report.problems, isEmpty);
    expect(run.caughtUpAt, isNotNull);
    expect(stored.keys.toSet(), run.report.rung.keys.toSet());
    for (final e in stored.entries) {
      expect(e.value, {run.report.rung[e.key]}, reason: 'sale ${e.key} came from its own till only');
    }
  });
}
