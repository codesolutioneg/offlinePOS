import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/db/database.dart';
import 'package:offline_pos/core/db/schema.dart';
import 'package:offline_pos/core/db/settings_store.dart';
import 'package:offline_pos/core/lan/lan_peer.dart';
import 'package:offline_pos/core/lan/lan_wiring.dart';
import 'package:offline_pos/features/settings/lan_settings_screen.dart';

import '../db/sqlite_loader.dart';

void main() {
  late Db db;
  late SettingsStore settings;
  int changed = 0;

  setUpAll(useSystemSqlite);
  setUp(() {
    db = Db.open(':memory:');
    settings = SettingsStore(db);
    changed = 0;
  });
  tearDown(() => db.close());

  final now = DateTime.utc(2026, 1, 1, 9, 2);

  LanPeer peer({String deviceId = 'till-b', int schema = -1}) => LanPeer(
        deviceId: deviceId,
        name: 'Back till',
        host: '10.0.0.7',
        port: 45333,
        schemaVersion: schema < 0 ? Schema.version : schema,
        lastSeenAt: now.subtract(const Duration(seconds: 12)),
      );

  Widget app({LanFacts Function()? facts}) => MaterialApp(
        home: LanSettingsScreen(
          settings: settings,
          deviceId: 'device-abc-123',
          onChanged: () => changed++,
          facts: facts,
          nowFn: () => now,
        ),
      );

  testWidgets('shows this device id and the devices it can see', (t) async {
    await t.pumpWidget(app(
      facts: () => (
        servingAt: '10.0.0.5:45333',
        peers: [peer()],
        refused: const [],
        cursors: const {'till-b': 42},
        lastPassAt: now.subtract(const Duration(seconds: 3)),
        lastError: null,
      ),
    ));

    // The id is what support asks for first, so it is shown in full.
    expect(find.text('device-abc-123'), findsOneWidget);
    expect(find.text('10.0.0.5:45333'), findsOneWidget);
    // A peer, where it is, and how long ago it was last heard from: "is it working
    // right now" is the question the screen exists to answer.
    expect(find.byKey(const Key('lan-peer-till-b')), findsOneWidget);
    expect(find.text('Back till'), findsOneWidget);
    expect(find.textContaining('12s'), findsOneWidget);
    expect(find.textContaining('read to 42'), findsOneWidget);
    expect(find.byKey(const Key('lan-no-peers')), findsNothing);
  });

  testWidgets('a device on its own says so rather than looking broken', (t) async {
    await t.pumpWidget(app());

    expect(find.byKey(const Key('lan-no-peers')), findsOneWidget);
    expect(find.text('not serving'), findsOneWidget);
    expect(find.text('never'), findsOneWidget);
    // Nothing went wrong, so there is nothing to report as having gone wrong.
    expect(find.byKey(const Key('lan-last-error')), findsNothing);
  });

  testWidgets('a peer on another data version is shown as turned away', (t) async {
    await t.pumpWidget(app(
      facts: () => (
        servingAt: null,
        peers: const [],
        refused: [peer(deviceId: 'till-c', schema: Schema.version + 1)],
        cursors: const {},
        lastPassAt: null,
        lastError: 'Back till: connection refused',
      ),
    ));

    expect(find.byKey(const Key('lan-last-error')), findsOneWidget);
    // Down past the peer list: an unfinished rollout is visible on the device
    // rather than only in the audit trail.
    await t.dragUntilVisible(find.byKey(const Key('lan-refused-till-c')),
        find.byType(ListView), const Offset(0, -200));
    expect(find.byKey(const Key('lan-refused-till-c')), findsOneWidget);
  });

  testWidgets('sharing is off until it is switched on, and the choice sticks',
      (t) async {
    await t.pumpWidget(app());
    expect(settings.lanEnabled(), isFalse);

    await t.tap(find.byKey(const Key('lan-enabled')));
    await t.pumpAndSettle();

    expect(settings.lanEnabled(), isTrue);
    expect(changed, 1);
  });

  testWidgets('naming the device persists it, and a blank name is no name',
      (t) async {
    await t.pumpWidget(app());

    await t.enterText(find.byKey(const Key('lan-device-name')), 'Front till');
    await t.tap(find.byKey(const Key('lan-save-name')));
    await t.pumpAndSettle();

    expect(settings.lanDeviceName, 'Front till');
    expect(find.text('Saved'), findsOneWidget);

    await t.enterText(find.byKey(const Key('lan-device-name')), '   ');
    await t.tap(find.byKey(const Key('lan-save-name')));
    await t.pumpAndSettle();

    // Cleared rather than stored as blank, so the other devices fall back to
    // showing an id instead of an empty row.
    expect(settings.lanDeviceName, isNull);
  });
}
