import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/db/catalogue_store.dart';
import 'package:offline_pos/core/db/database.dart';
import 'package:offline_pos/core/sync/odoo_puller.dart';
import 'package:offline_pos/core/sync/outbox.dart';
import 'package:offline_pos/core/sync/sync_service.dart';
import 'package:offline_pos/domain/catalogue.dart';

import '../db/sqlite_loader.dart';

class MemStore implements OutboxStore {
  final List<OutboxEntry> _e = [];
  final Set<int> _sent = {};
  int _n = 1;
  @override
  Future<void> append(String k, String u, Map<String, dynamic> p) async =>
      _e.add(OutboxEntry(id: _n++, kind: k, payloadUuid: u, payload: p));
  @override
  Future<List<OutboxEntry>> pending({int limit = 20}) async =>
      _e.where((x) => !_sent.contains(x.id)).take(limit).toList();
  @override
  Future<void> markSent(int id) async => _sent.add(id);
  @override
  Future<void> markFailed(int id, String e) async {}
}

OdooPuller pullerWith(List<Product> products) => OdooPuller(
      call: (model, method, args, kwargs) async => switch (model) {
        'product.product' => products
            .map((p) => {'id': p.id, 'display_name': p.name, 'lst_price': p.price,
                         'pos_categ_ids': const <int>[], 'active': true})
            .toList(),
        _ => const [],
      },
    );

void main() {
  late Db db;
  late CatalogueStore cat;
  setUpAll(useSystemSqlite);
  setUp(() {
    db = Db.open(':memory:');
    cat = CatalogueStore(db);
  });
  tearDown(() => db.close());

  test('a never-pulled catalogue needs a refresh', () {
    final s = SyncService(
        outbox: Outbox(store: MemStore(), senders: const {}), catalogue: cat);
    expect(s.catalogueNeedsRefresh, isTrue);
  });

  test('a tick drains the outbox and refreshes the catalogue', () async {
    final store = MemStore();
    final outbox = Outbox(store: store, senders: {'order.push': (e) async {}});
    await outbox.enqueue('order.push', 'u1', {});
    final s = SyncService(
      outbox: outbox,
      catalogue: cat,
      puller: pullerWith(const [Product(id: 1, name: 'A', price: 5)]),
    );
    await s.tick();
    expect(s.sentThisRun, 1);
    expect(cat.products().single.name, 'A');
    expect(s.state, SyncState.idle);
    expect(s.catalogueNeedsRefresh, isFalse);
  });

  test('a failing tick records the error instead of throwing', () async {
    final s = SyncService(
      outbox: Outbox(store: MemStore(), senders: const {}),
      catalogue: cat,
      puller: OdooPuller(call: (a, b, c, d) async => throw Exception('down')),
    );
    await s.tick();
    expect(s.state, SyncState.offline);
    expect(s.lastError, contains('down'));
  });

  test('an empty pull never wipes a catalogue the till is selling from', () async {
    cat.replaceAll(
      categories: const [], products: const [Product(id: 9, name: 'Keep', price: 1)],
      groups: const [], productGroupIds: const {},
      refreshedAt: DateTime.utc(2020),
    );
    final s = SyncService(
      outbox: Outbox(store: MemStore(), senders: const {}),
      catalogue: cat,
      puller: pullerWith(const []),
    );
    await s.tick();
    expect(cat.products().single.name, 'Keep');
  });

  test('a fresh catalogue is not re-pulled', () async {
    var pulls = 0;
    final s = SyncService(
      outbox: Outbox(store: MemStore(), senders: const {}),
      catalogue: cat,
      puller: OdooPuller(call: (model, m, a, k) async {
        if (model == 'product.product') pulls++;
        return model == 'product.product'
            ? [{'id': 1, 'display_name': 'A', 'lst_price': 1, 'active': true}]
            : const [];
      }),
    );
    await s.tick();
    await s.tick();
    expect(pulls, 1);
  });
}
