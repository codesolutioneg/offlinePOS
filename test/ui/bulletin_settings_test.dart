import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/db/database.dart';
import 'package:offline_pos/core/db/settings_store.dart';
import 'package:offline_pos/features/settings/bulletin_settings_screen.dart';

import '../db/sqlite_loader.dart';

void main() {
  setUpAll(useSystemSqlite);

  testWidgets('switches save straight into settings', (t) async {
    final db = Db.open(':memory:');
    addTearDown(db.close);
    final settings = SettingsStore(db);
    var changed = 0;
    await t.pumpWidget(MaterialApp(
      home: BulletinSettingsScreen(settings: settings, onChanged: () => changed++),
    ));
    expect(find.byKey(const Key('bulletin-enabled')), findsOneWidget);
    expect(find.byKey(const Key('bulletin-row-open')), findsOneWidget);

    await t.tap(find.byKey(const Key('bulletin-row-open')));
    await t.pump();
    expect(settings.floorBulletinHidden, {'open'});

    await t.tap(find.byKey(const Key('bulletin-enabled')));
    await t.pump();
    expect(settings.floorBulletinEnabled, isFalse);

    await t.scrollUntilVisible(
        find.byKey(const Key('action-button-quit')), 200);
    await t.tap(find.byKey(const Key('action-button-quit')));
    await t.pump();
    expect(settings.floorActionsHidden, {'quit'});
    expect(changed, 3);
  });
}
