import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/db/database.dart';
import 'package:offline_pos/core/db/schema.dart';
import 'package:offline_pos/core/db/settings_store.dart';
import 'package:offline_pos/core/i18n/l10n.dart';
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

  Widget app({LanFacts Function()? facts, Locale? locale}) => MaterialApp(
        locale: locale,
        supportedLocales: kSupportedLocales,
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: LanSettingsScreen(
          settings: settings,
          deviceId: 'device-abc-123',
          onChanged: () => changed++,
          facts: facts,
          nowFn: () => now,
        ),
      );

  /// Opens the screen on a till-sized surface. The default 800x600 test window is
  /// shorter than this page, and a ListView does not build what does not fit, so the
  /// peer list below the fold would read as missing rather than as off-screen.
  Future<void> open(WidgetTester t,
      {LanFacts Function()? facts, Locale? locale}) async {
    t.view.physicalSize = const Size(1200, 2400);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    await t.pumpWidget(app(facts: facts, locale: locale));
  }

  testWidgets('shows this device id and the devices it can see', (t) async {
    await open(t,
      facts: () => (
        servingAt: '10.0.0.5:45333',
        peers: [peer()],
        refused: const [],
        cursors: const {'till-b': 42},
        lastPassAt: now.subtract(const Duration(seconds: 3)),
        lastError: null,
      ),
    );

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
    await open(t);

    expect(find.byKey(const Key('lan-no-peers')), findsOneWidget);
    expect(find.text('not serving'), findsOneWidget);
    expect(find.text('never'), findsOneWidget);
    // Nothing went wrong, so there is nothing to report as having gone wrong.
    expect(find.byKey(const Key('lan-last-error')), findsNothing);
  });

  testWidgets('a peer on another data version is shown as turned away', (t) async {
    await open(t,
      facts: () => (
        servingAt: null,
        peers: const [],
        refused: [peer(deviceId: 'till-c', schema: Schema.version + 1)],
        cursors: const {},
        lastPassAt: null,
        lastError: 'Back till: connection refused',
      ),
    );

    expect(find.byKey(const Key('lan-last-error')), findsOneWidget);
    // Down past the peer list: an unfinished rollout is visible on the device
    // rather than only in the audit trail.
    await t.dragUntilVisible(find.byKey(const Key('lan-refused-till-c')),
        find.byType(ListView), const Offset(0, -200));
    expect(find.byKey(const Key('lan-refused-till-c')), findsOneWidget);
  });

  testWidgets('reads in Arabic, including the sentences', (t) async {
    await open(t, locale: const Locale('ar'));

    // A long label is where a translation key silently drifts from the string in
    // the widget, and the fallback would leave one English paragraph on an
    // otherwise Arabic screen.
    expect(find.text('شبكة المتجر'), findsOneWidget);
    expect(find.text('المشاركة مع الأجهزة الأخرى'), findsOneWidget);
    expect(
        find.text('لم يتم العثور على أجهزة أخرى بعد. هذا هو الوضع المتوقع لمتجر '
            'بكاشير واحد.'),
        findsOneWidget);
    expect(find.textContaining('البيع لا ينتظر هذه الميزة'), findsOneWidget);
  });

  testWidgets('sharing is off until it is switched on, and the choice sticks',
      (t) async {
    await open(t);
    expect(settings.lanEnabled(), isFalse);

    await t.tap(find.byKey(const Key('lan-enabled')));
    await t.pumpAndSettle();

    expect(settings.lanEnabled(), isTrue);
    expect(changed, 1);
  });

  testWidgets('naming the device persists it, and a blank name is no name',
      (t) async {
    await open(t);

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

  testWidgets('switching sharing on invents a shop key to pair the others with',
      (t) async {
    await open(t);
    expect(settings.lanShopKey, isNull);

    await t.tap(find.byKey(const Key('lan-enabled')));
    await t.pumpAndSettle();

    // Made here rather than on the next start, so whoever flicked the switch can
    // copy it to the other tills without restarting anything.
    final key = settings.lanShopKey;
    expect(key, isNotNull);
    expect(key!.length, greaterThan(20));
    // Shown, because it is only useful if someone can read it off this screen and
    // type it into the next till.
    expect(find.text(key), findsOneWidget);
  });

  testWidgets('pasting the first till key pairs this one to the same shop',
      (t) async {
    await open(t);

    await t.enterText(find.byKey(const Key('lan-shop-key')), 'the-first-till-key');
    await t.tap(find.byKey(const Key('lan-save-key')));
    await t.pumpAndSettle();

    expect(settings.lanShopKey, 'the-first-till-key');
    expect(changed, greaterThan(0));
  });

  testWidgets('a blank key is refused rather than stored as no pairing at all',
      (t) async {
    settings.lanShopKey = 'a-real-key';
    await open(t);

    await t.enterText(find.byKey(const Key('lan-shop-key')), '   ');
    await t.tap(find.byKey(const Key('lan-save-key')));
    await t.pumpAndSettle();

    // Saving nothing would leave the fabric unable to serve anyone, which is worse
    // than telling the manager the field is required.
    expect(settings.lanShopKey, 'a-real-key');
    expect(find.textContaining('shop key is needed'), findsOneWidget);
  });

  testWidgets('replacing the key asks first, because it unpairs the other devices',
      (t) async {
    settings.lanShopKey = 'the-old-key';
    await open(t);

    await t.tap(find.byKey(const Key('lan-new-key')));
    await t.pumpAndSettle();
    // Cancelled: nothing moves, so a mis-tap on a busy night costs nothing.
    await t.tap(find.text('Cancel'));
    await t.pumpAndSettle();
    expect(settings.lanShopKey, 'the-old-key');

    await t.tap(find.byKey(const Key('lan-new-key')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('lan-confirm-new-key')));
    await t.pumpAndSettle();

    expect(settings.lanShopKey, isNot('the-old-key'));
    expect(find.text(settings.lanShopKey!), findsOneWidget);
  });
}
