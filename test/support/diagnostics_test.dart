import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/audit/audit_log.dart';
import 'package:offline_pos/core/db/catalogue_store.dart';
import 'package:offline_pos/core/db/database.dart';
import 'package:offline_pos/core/db/sqlite_outbox_store.dart';
import 'package:offline_pos/core/sync/outbox.dart';
import 'package:offline_pos/core/sync/sync_service.dart';
import 'package:offline_pos/features/support/diagnostics_screen.dart';

import '../db/sqlite_loader.dart';

void main() {
  late Db db;
  late SqliteOutboxStore store;
  late AuditLog audit;
  late SyncService sync;

  setUpAll(useSystemSqlite);
  setUp(() {
    db = Db.open(':memory:');
    store = SqliteOutboxStore(db);
    audit = AuditLog(db);
    sync = SyncService(
      outbox: Outbox(store: store, senders: const {}),
      catalogue: CatalogueStore(db),
      outboxStore: store,
      audit: audit,
      deviceId: 'till-7',
      appVersion: '1.2.3',
    );
  });
  tearDown(() => db.close());

  Widget app() => MaterialApp(
      home: DiagnosticsScreen(sync: sync, outboxStore: store));

  testWidgets('shows what support needs to identify the till', (t) async {
    await t.pumpWidget(app());
    expect(find.text('till-7'), findsOneWidget);
    expect(find.text('1.2.3'), findsOneWidget);
  });

  testWidgets('reports how many sales are waiting', (t) async {
    await store.append('order.push', 'a', {});
    await store.append('order.push', 'b', {});
    await t.pumpWidget(app());
    expect(t.widget<Text>(find.byKey(const Key('diag-pending'))).data, '2');
  });

  testWidgets('rejected sales are reported apart from waiting ones', (t) async {
    await store.append('order.push', 'a', {});
    await store.append('order.push', 'bad', {});
    await store.markDead(2, 'deleted product');
    await t.pumpWidget(app());
    // A rejection is money missing from the books, so it must not be hidden
    // inside the pending count.
    expect(t.widget<Text>(find.byKey(const Key('diag-pending'))).data, '1');
    expect(t.widget<Text>(find.byKey(const Key('diag-dead'))).data, '1');
  });

  testWidgets('a rejected sale can be retried from the till', (t) async {
    await store.append('order.push', 'bad', {});
    await store.markDead(1, 'deleted product');
    await t.pumpWidget(app());
    expect(find.text('deleted product'), findsOneWidget);
    await t.tap(find.text('Retry'));
    await t.pumpAndSettle();
    expect(store.deadCount, 0);
    expect(store.pendingCount, 1);
  });

  testWidgets('a till needing attention says so at the top', (t) async {
    await store.append('order.push', 'bad', {});
    await store.markDead(1, 'rejected');
    await t.pumpWidget(app());
    expect(find.byKey(const Key('attention')), findsOneWidget);
  });

  testWidgets('a healthy till shows no alarm', (t) async {
    await t.pumpWidget(app());
    expect(find.byKey(const Key('attention')), findsNothing);
  });

  testWidgets('the last sync error is surfaced verbatim', (t) async {
    await sync.tick();
    await t.pumpWidget(app());
    // No senders registered and nothing queued: still healthy, no error shown.
    expect(find.byKey(const Key('diag-last-error')), findsNothing);
  });

  testWidgets('sync can be forced by hand during a support call', (t) async {
    await t.pumpWidget(app());
    await t.tap(find.byKey(const Key('sync-now')));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('sync-now')), findsOneWidget);
  });
}
