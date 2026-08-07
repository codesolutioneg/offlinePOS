import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/db/database.dart';
import 'package:offline_pos/core/sync/odoo_endpoint.dart';

import '../db/sqlite_loader.dart';

void main() {
  late Db db;
  late OdooEndpointStore store;
  setUpAll(useSystemSqlite);
  setUp(() { db = Db.open(':memory:'); store = OdooEndpointStore(db); });
  tearDown(() => db.close());

  test('a fresh till has no endpoint, so the outbox just accumulates', () {
    expect(store.load(), isNull);
    expect(store.isConfigured, isFalse);
  });

  test('an endpoint round-trips and stays a single row', () {
    store.save(const OdooEndpoint(baseUrl: 'https://a', db: 'd', login: 'u', password: 'p'));
    store.save(const OdooEndpoint(baseUrl: 'https://b', db: 'd2', login: 'u2'));
    final e = store.load()!;
    expect(e.baseUrl, 'https://b');
    expect(e.password, isNull); // overwritten, not merged
    expect(store.isConfigured, isTrue);
  });

  test('an incomplete endpoint is not considered configured', () {
    expect(const OdooEndpoint(baseUrl: '', db: 'd', login: 'u').isComplete, isFalse);
    expect(const OdooEndpoint(baseUrl: 'https://a', db: 'd', login: 'u').isComplete, isTrue);
  });

  test('clearing removes it', () {
    store.save(const OdooEndpoint(baseUrl: 'https://a', db: 'd', login: 'u'));
    store.clear();
    expect(store.isConfigured, isFalse);
  });
}
