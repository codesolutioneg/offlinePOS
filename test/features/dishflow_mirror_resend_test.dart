import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/db/database.dart';
import 'package:offline_pos/core/db/settings_store.dart';
import 'package:offline_pos/core/sync/dishflow_mirror.dart';
import 'package:offline_pos/domain/order.dart';
import 'package:offline_pos/features/settings/dishflow_mirror_settings_screen.dart';

import '../db/sqlite_loader.dart';

/// The catch-up button on the mirror settings: checks, confirms, then queues.
void main() {
  late Db db;
  late SettingsStore settings;
  late DishflowResendPlan nextPlan;
  DishflowResendPlan? resent;

  setUpAll(useSystemSqlite);
  setUp(() {
    db = Db.open(':memory:');
    settings = SettingsStore(db)
      ..dishflowMirrorEnabled = true
      ..dishflowProjectId = 'odc-chat'
      ..dishflowApiKey = 'key'
      ..dishflowOdooConnectionId = 'conn1';
    resent = null;
    final view = TestWidgetsFlutterBinding.instance.platformDispatcher.views.first;
    view.physicalSize = const Size(1000, 2000);
    view.devicePixelRatio = 1;
    addTearDown(view.resetPhysicalSize);
    addTearDown(view.resetDevicePixelRatio);
  });
  tearDown(() => db.close());

  Order order(String uuid) =>
      Order(uuid: uuid, deviceId: 'till1', cashierId: 'c1');

  Widget app() => MaterialApp(
        home: DishflowMirrorSettingsScreen(
          settings: settings,
          onChanged: () {},
          planResend: () => nextPlan,
          resend: (p) async {
            resent = p;
            return p.toSend.length;
          },
        ),
      );

  testWidgets('shows the counts, then queues on confirm', (t) async {
    nextPlan = DishflowResendPlan(
      shiftOpen: true,
      toSend: [order('a'), order('b')],
      sent: 3,
      waiting: 1,
      refused: 0,
    );
    await t.pumpWidget(app());
    await t.tap(find.byKey(const Key('dishflow-resend')));
    await t.pumpAndSettle();

    expect(find.textContaining('open shift: 6'), findsOneWidget);
    expect(find.textContaining('Will send now: 2'), findsOneWidget);
    await t.tap(find.byKey(const Key('dishflow-resend-confirm')));
    await t.pumpAndSettle();

    expect(resent, same(nextPlan));
    expect(find.textContaining('2 sales queued'), findsOneWidget);
  });

  testWidgets('unsaved edits are refused before anything is queued', (t) async {
    nextPlan = DishflowResendPlan(
      shiftOpen: true,
      toSend: [order('a')],
      sent: 0,
      waiting: 0,
      refused: 0,
    );
    await t.pumpWidget(app());
    await t.enterText(find.byKey(const Key('dishflow-connection')), 'other');
    await t.tap(find.byKey(const Key('dishflow-resend')));
    await t.pumpAndSettle();

    expect(find.text('Save the settings first.'), findsOneWidget);
    expect(resent, isNull);
  });

  testWidgets('says so when everything is already with Dishflow', (t) async {
    nextPlan = const DishflowResendPlan(
      shiftOpen: true,
      toSend: [],
      sent: 4,
      waiting: 0,
      refused: 0,
    );
    await t.pumpWidget(app());
    await t.tap(find.byKey(const Key('dishflow-resend')));
    await t.pumpAndSettle();

    expect(find.textContaining('All 4 sales'), findsOneWidget);
    expect(resent, isNull);
  });

  testWidgets('no open shift, nothing to send', (t) async {
    nextPlan = const DishflowResendPlan.noShift();
    await t.pumpWidget(app());
    await t.tap(find.byKey(const Key('dishflow-resend')));
    await t.pumpAndSettle();

    expect(find.text('No shift is open on this till.'), findsOneWidget);
    expect(resent, isNull);
  });
}
