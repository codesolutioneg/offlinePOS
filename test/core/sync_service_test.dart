import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/db/catalogue_store.dart';
import 'package:offline_pos/core/db/database.dart';
import 'package:offline_pos/core/db/sqlite_outbox_store.dart';
import 'package:offline_pos/core/sync/odoo_puller.dart';
import 'package:offline_pos/core/sync/outbox.dart';
import 'package:offline_pos/core/sync/sync_service.dart';
import 'package:offline_pos/domain/catalogue.dart';

import '../db/sqlite_loader.dart';

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
  late SqliteOutboxStore store;
  setUpAll(useSystemSqlite);
  setUp(() {
    db = Db.open(':memory:');
    cat = CatalogueStore(db);
    store = SqliteOutboxStore(db);
  });
  tearDown(() => db.close());

  /// The real outbox store, because it is where every number the service reports
  /// about the till comes from. A stand-in here would let the two drift.
  SyncService serviceWith({
    Map<String, OutboxSender> senders = const {},
    OdooPuller? puller,
    Outbox? outbox,
    Future<bool> Function()? probe,
  }) =>
      SyncService(
        outbox: outbox ?? Outbox(store: store, senders: senders),
        catalogue: cat,
        outboxStore: store,
        deviceId: 'till-7',
        appVersion: '1.2.3',
        puller: puller,
        probe: probe,
      );

  test('a never-pulled catalogue needs a refresh', () {
    expect(serviceWith().catalogueNeedsRefresh, isTrue);
  });

  test('a tick drains the outbox and refreshes the catalogue', () async {
    final outbox = Outbox(store: store, senders: {'order.push': (e) async {}});
    await outbox.enqueue('order.push', 'u1', {});
    final s = serviceWith(
      outbox: outbox,
      puller: pullerWith(const [Product(id: 1, name: 'A', price: 5)]),
    );
    await s.tick();
    // The sale and the heartbeat: the heartbeat has no sender, so only one went.
    expect(s.sentThisRun, 1);
    expect(cat.products().single.name, 'A');
    expect(s.state, SyncState.idle);
    expect(s.catalogueNeedsRefresh, isFalse);
  });

  test('a failing tick records the error instead of throwing', () async {
    final s = serviceWith(
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
    final s = serviceWith(puller: pullerWith(const []));
    await s.tick();
    expect(cat.products().single.name, 'Keep');
  });

  test('refresh never drains the outbox, so an order is not pushed off-shift', () async {
    // The license model books orders as one batch at shift close. The periodic
    // refresh must therefore touch reachability and the catalogue only, never send
    // a queued sale.
    var sent = 0;
    final outbox = Outbox(store: store, senders: {'order.push': (e) async => sent++});
    await outbox.enqueue('order.push', 'u1', {});
    final s = serviceWith(
      outbox: outbox,
      puller: pullerWith(const [Product(id: 1, name: 'A', price: 5)]),
      probe: () async => true,
    );
    await s.refresh();
    expect(sent, 0, reason: 'refresh must not push orders');
    expect(s.online.value, isTrue);
    // The order is still queued, ready for the close-of-shift flush.
    expect(store.pendingSalesCount, 1);
  });

  test('an unreachable probe marks the till offline and skips the pull', () async {
    var pulls = 0;
    final s = serviceWith(
      puller: OdooPuller(call: (model, m, a, k) async {
        if (model == 'product.product') pulls++;
        return const [];
      }),
      probe: () async => false,
    );
    await s.refresh();
    expect(s.online.value, isFalse);
    expect(pulls, 0, reason: 'nothing reachable, so no pull attempt');
  });

  test('a failing flush marks the till offline', () async {
    final bad = serviceWith(
      puller: OdooPuller(call: (a, b, c, d) async => throw Exception('down')),
    );
    await bad.flush();
    expect(bad.online.value, isFalse);
  });

  test('a successful flush marks the till online', () async {
    final ok = serviceWith(
      outbox: Outbox(store: store, senders: {'order.push': (e) async {}}),
      puller: pullerWith(const [Product(id: 1, name: 'A', price: 5)]),
    );
    await ok.flush();
    expect(ok.online.value, isTrue);
  });

  test('a fresh catalogue is not re-pulled', () async {
    var pulls = 0;
    final s = serviceWith(
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
