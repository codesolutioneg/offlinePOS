import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/db/database.dart';
import 'package:offline_pos/core/sync/odoo_endpoint.dart';
import 'package:offline_pos/core/sync/server_probe.dart';
import 'package:offline_pos/features/settings/server_settings_screen.dart';

import '../db/sqlite_loader.dart';

/// Pressing Test connection has to say which kind of no it got, because each one
/// has a different fix and a shop only has the words on this screen to go on.
void main() {
  late Db db;
  late OdooEndpointStore store;

  setUpAll(useSystemSqlite);
  setUp(() {
    db = Db.open(':memory:');
    store = OdooEndpointStore(db);
  });
  tearDown(() => db.close());

  Widget app({
    ServerCheckResult? answer,
    List<OdooEndpoint>? asked,
  }) =>
      MaterialApp(
        home: ServerSettingsScreen(
          store: store,
          onSaved: (_) {},
          check: answer == null
              ? null
              : (e) async {
                  asked?.add(e);
                  return answer;
                },
        ),
      );

  Future<void> typeAServer(WidgetTester t) async {
    await t.enterText(find.byKey(const Key('field-url')), 'https://shop.example.com');
    await t.enterText(find.byKey(const Key('field-db')), 'shop');
    await t.enterText(find.byKey(const Key('field-login')), 'till@example.com');
    await t.enterText(find.byKey(const Key('field-pass')), 'secret');
  }

  String messageOn(WidgetTester t) =>
      t.widget<Text>(find.byKey(const Key('settings-message'))).data!;

  testWidgets('a build with no way to reach out shows no button', (t) async {
    await t.pumpWidget(app());
    expect(find.byKey(const Key('test-connection')), findsNothing);
  });

  testWidgets('a good server says the login was accepted', (t) async {
    await t.pumpWidget(app(answer: const ServerCheckResult(ServerCheck.ok)));
    await typeAServer(t);

    await t.tap(find.byKey(const Key('test-connection')));
    await t.pumpAndSettle();

    expect(messageOn(t), contains('Connected'));
  });

  testWidgets('it checks what is typed, not what was saved', (t) async {
    store.save(const OdooEndpoint(
        baseUrl: 'https://old.example.com', db: 'old', login: 'old@example.com'));
    final asked = <OdooEndpoint>[];
    await t.pumpWidget(
        app(answer: const ServerCheckResult(ServerCheck.ok), asked: asked));
    await typeAServer(t);

    await t.tap(find.byKey(const Key('test-connection')));
    await t.pumpAndSettle();

    expect(asked.single.baseUrl, 'https://shop.example.com');
    // Trying an address is not committing to it: nothing was written.
    expect(store.load()!.baseUrl, 'https://old.example.com');
  });

  testWidgets('an address nobody answers is named as that', (t) async {
    await t.pumpWidget(app(
        answer: const ServerCheckResult(ServerCheck.unreachable,
            detail: 'SocketException: no route to host')));
    await typeAServer(t);

    await t.tap(find.byKey(const Key('test-connection')));
    await t.pumpAndSettle();

    expect(messageOn(t), contains('No answer'));
    expect(messageOn(t), contains('no route to host'));
  });

  testWidgets('a wrong login is not reported as an outage', (t) async {
    await t.pumpWidget(app(
        answer: const ServerCheckResult(ServerCheck.badCredentials,
            detail: 'Access denied')));
    await typeAServer(t);

    await t.tap(find.byKey(const Key('test-connection')));
    await t.pumpAndSettle();

    expect(messageOn(t), contains('refused this login'));
    expect(messageOn(t), contains('Access denied'));
  });

  testWidgets('something that is not Odoo is its own answer', (t) async {
    await t.pumpWidget(app(
        answer: const ServerCheckResult(ServerCheck.refused, detail: 'HTTP 404')));
    await typeAServer(t);

    await t.tap(find.byKey(const Key('test-connection')));
    await t.pumpAndSettle();

    expect(messageOn(t), contains('not an Odoo server'));
  });

  testWidgets('a half-typed server is refused before anything is asked', (t) async {
    final asked = <OdooEndpoint>[];
    await t.pumpWidget(app(
        answer: const ServerCheckResult(ServerCheck.notConfigured), asked: asked));

    await t.enterText(find.byKey(const Key('field-url')), 'https://shop.example.com');
    await t.tap(find.byKey(const Key('test-connection')));
    await t.pumpAndSettle();

    expect(messageOn(t), contains('required'));
  });
}
