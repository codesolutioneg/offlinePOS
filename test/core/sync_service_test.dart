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

/// A server that can be turned off and on inside a test, so a batch push can be
/// made to fail the way a shift close does at 11pm and then be allowed to succeed
/// on a later attempt.
class FlakyServer {
  bool down = true;
  int sends = 0;

  Future<void> send(OutboxEntry entry) async {
    if (down) throw Exception('server down');
    sends++;
  }
}

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
    Future<void> Function()? reconcile,
    Duration retryWindow = const Duration(hours: 12),
    Duration retryInterval = const Duration(minutes: 5),
    DateTime Function()? now,
  }) =>
      SyncService(
        outbox: outbox ?? Outbox(store: store, senders: senders),
        catalogue: cat,
        outboxStore: store,
        deviceId: 'till-7',
        appVersion: '1.2.3',
        puller: puller,
        probe: probe,
        reconcile: reconcile,
        retryWindow: retryWindow,
        retryInterval: retryInterval,
        now: now,
      );

  /// A till that closed its shift while the server was down: one sale still queued
  /// and a retry armed. This is the state the self-healing tests start from.
  Future<({SyncService sync, Outbox outbox, FlakyServer server})> armedTill({
    Duration retryWindow = const Duration(hours: 12),
    Duration retryInterval = const Duration(minutes: 5),
    DateTime Function()? now,
    Future<bool> Function()? probe,
  }) async {
    final server = FlakyServer();
    final outbox = Outbox(store: store, senders: {'order.push': server.send});
    await outbox.enqueue('order.push', 'u1', {});
    final sync = serviceWith(
      outbox: outbox,
      probe: probe,
      retryWindow: retryWindow,
      retryInterval: retryInterval,
      now: now,
    );
    await sync.flush();
    return (sync: sync, outbox: outbox, server: server);
  }

  test('a never-pulled catalogue needs a refresh', () {
    expect(serviceWith().catalogueNeedsRefresh, isTrue);
  });

  test('the background loop chases a price change within the half hour', () {
    // A price changed in Odoo used to sit unseen for six hours, which is most of a
    // service. The loop is read-only either way: this only says how often the menu
    // is re-read, never that anything is pushed.
    final s = serviceWith();
    expect(s.catalogueMaxAge, const Duration(minutes: 30));

    void pulledAgo(Duration age) => cat.replaceAll(
          categories: const [],
          products: const [Product(id: 1, name: 'A', price: 5)],
          groups: const [],
          productGroupIds: const {},
          refreshedAt: DateTime.now().toUtc().subtract(age),
        );

    pulledAgo(const Duration(minutes: 10));
    expect(s.catalogueNeedsRefresh, isFalse);
    pulledAgo(const Duration(minutes: 45));
    expect(s.catalogueNeedsRefresh, isTrue);
  });

  test('a batch push re-queues a paid sale that never reached the outbox', () async {
    // Simulates the app being killed between saving a paid sale and queuing it: the
    // reconcile hook re-enqueues it, so a flush still delivers it rather than
    // stranding money on the till.
    final outbox = Outbox(store: store, senders: {'order.push': (e) async {}});
    final s = serviceWith(
      outbox: outbox,
      reconcile: () async => outbox.enqueue('order.push', 'lost-1', {'uuid': 'lost-1'}),
    );
    expect(store.pendingSalesCount, 0); // nothing queued yet
    await s.flush();
    expect(s.sentThisRun, 1); // the reconciled sale was delivered
  });

  test('reconcilePending runs the hook so pending counts can be read after it', () async {
    var ran = 0;
    final s = serviceWith(reconcile: () async => ran++);
    await s.reconcilePending();
    expect(ran, 1);
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

  test('a forced refresh re-pulls a catalogue that is not stale yet', () async {
    // A price changed in Odoo this morning must not wait for the age gate to
    // expire, which is most of a service away.
    var pulls = 0;
    final s = serviceWith(
      puller: OdooPuller(call: (model, m, a, k) async {
        if (model == 'product.product') pulls++;
        return model == 'product.product'
            ? [{'id': 1, 'display_name': 'A', 'lst_price': 1, 'active': true}]
            : const [];
      }),
    );
    await s.refresh();
    expect(pulls, 1);
    expect(s.catalogueNeedsRefresh, isFalse, reason: 'the age gate is now shut');
    await s.refresh();
    expect(pulls, 1, reason: 'an ordinary pass still respects the age gate');
    expect(await s.refresh(force: true), RefreshOutcome.updated);
    expect(pulls, 2);
  });

  test('a forced refresh still never drains the outbox', () async {
    // The force flag opens the age gate and nothing else: orders leave this till
    // as one batch at shift close, whoever asked for the menu.
    var sent = 0;
    final outbox = Outbox(store: store, senders: {'order.push': (e) async => sent++});
    await outbox.enqueue('order.push', 'u1', {});
    final s = serviceWith(
      outbox: outbox,
      puller: pullerWith(const [Product(id: 1, name: 'A', price: 5)]),
      probe: () async => true,
    );
    await s.refresh(force: true);
    expect(sent, 0, reason: 'a forced refresh must not push orders either');
    expect(store.pendingSalesCount, 1);
  });

  test('a forced refresh with nothing reachable says so and keeps the prices',
      () async {
    cat.replaceAll(
      categories: const [], products: const [Product(id: 9, name: 'Keep', price: 1)],
      groups: const [], productGroupIds: const {},
      refreshedAt: DateTime.utc(2020),
    );
    final s = serviceWith(
      puller: pullerWith(const [Product(id: 1, name: 'A', price: 5)]),
      probe: () async => false,
    );
    expect(await s.refresh(force: true), RefreshOutcome.unreachable);
    expect(cat.products().single.name, 'Keep');
  });

  test('a flush that cannot deliver arms a retry', () async {
    // The shift close that fails is exactly when a person is least likely to be
    // watching, so the till has to remember the job is unfinished.
    final till = await armedTill();
    expect(till.server.sends, 0);
    expect(store.pendingSalesCount, 1, reason: 'the takings are still on the till');
    expect(till.sync.retryArmed, isTrue);
    expect(till.sync.retryArmedAt, isNotNull);
    expect(till.sync.retryArmedReason, isNotNull);
    expect(till.sync.retryAttempts, 0, reason: 'armed, not yet tried');
  });

  test('a timer pass drains the armed retry once the server is back', () async {
    final till = await armedTill(probe: () async => true);
    till.server.down = false;
    await till.sync.periodicPass();
    expect(till.server.sends, 1, reason: 'the orders went without anyone tapping sync');
    expect(store.pendingSalesCount, 0);
    expect(till.sync.retryAttempts, 1);
    expect(till.sync.lastRetryAt, isNotNull);
    expect(till.sync.retryArmed, isFalse);
    expect(till.sync.retryStoppedReason, contains('delivered'));
  });

  test('the armed retry paces itself instead of hammering a dead server', () async {
    var clock = DateTime.utc(2026, 1, 1, 23);
    final till = await armedTill(
      retryInterval: const Duration(minutes: 5),
      now: () => clock,
      probe: () async => true,
    );
    await till.sync.periodicPass();
    // The loop ticks every 20 s; the next few passes must not turn into attempts.
    await till.sync.periodicPass();
    await till.sync.periodicPass();
    expect(till.sync.retryAttempts, 1);
    clock = clock.add(const Duration(minutes: 6));
    await till.sync.periodicPass();
    expect(till.sync.retryAttempts, 2);
  });

  test('the armed retry gives up when its window closes', () async {
    var clock = DateTime.utc(2026, 1, 1, 23);
    final till = await armedTill(
      retryWindow: const Duration(hours: 12),
      now: () => clock,
      probe: () async => true,
    );
    till.server.down = false; // back up, but far too late to be this till's job
    clock = clock.add(const Duration(hours: 13));
    await till.sync.periodicPass();
    expect(till.server.sends, 0, reason: 'the window closed, so nothing is tried');
    expect(till.sync.retryArmed, isFalse);
    // Support has to be able to see it stopped, rather than a till that looks like
    // it is still trying.
    expect(till.sync.retryStoppedReason, contains('gave up'));
    expect(store.pendingSalesCount, 1, reason: 'the sale is still owed to Odoo');
  });

  test('the timer pass stands the retry down when nothing is left to send', () async {
    final till = await armedTill(probe: () async => true);
    till.server.down = false;
    // Emptied without a batch push, the way a drain from elsewhere can, so the
    // pass itself is what has to notice there is nothing to chase.
    await till.outbox.drain();
    await till.sync.periodicPass();
    expect(till.sync.retryArmed, isFalse);
    expect(till.sync.retryStoppedReason, contains('nothing left'));
    expect(till.sync.retryAttempts, 0, reason: 'nothing owed, so no attempt');
  });

  test('an offline pass makes no retry attempt at all', () async {
    final till = await armedTill(probe: () async => false);
    till.server.down = false; // the server is up; this till cannot see it
    await till.sync.periodicPass();
    expect(till.server.sends, 0, reason: 'the probe said offline, so no attempt');
    expect(till.sync.retryAttempts, 0);
    expect(till.sync.retryArmed, isTrue, reason: 'still owed, so still armed');
  });

  test('refresh never drains even while a retry is armed', () async {
    // The retry lives beside refresh, never inside it: orders are booked as one
    // batch on a single shared Odoo login, so the periodic read stays a read.
    final till = await armedTill(probe: () async => true);
    till.server.down = false;
    await till.sync.refresh();
    expect(till.server.sends, 0, reason: 'refresh must not push orders');
    expect(store.pendingSalesCount, 1);
    expect(till.sync.retryArmed, isTrue);
    expect(till.sync.retryAttempts, 0);
  });
}
