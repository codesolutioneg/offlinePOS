import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:offline_pos/core/auth/fingerprint_agent_launcher.dart';
import 'package:offline_pos/core/auth/fingerprint_service.dart';
import 'package:offline_pos/core/auth/fingerprint_store.dart';
import 'package:offline_pos/core/db/database.dart';

import '../../db/sqlite_loader.dart';

/// A till joins with an empty bank, so nothing starts the reader at boot. The
/// first print that later arrives from another till must start it.
void main() {
  setUpAll(useSystemSqlite);

  late Db db;
  late int launches;
  late FingerprintStore store;

  setUp(() {
    db = Db.open(':memory:');
    launches = 0;
    store = FingerprintStore(
      db,
      service: FingerprintService(
        client: MockClient((_) async => http.Response('{}', 503)),
      ),
      launchAgent: () async {
        launches++;
        return false;
      },
    );
  });
  tearDown(() => db.close());

  test('a print from another till starts the agent', () async {
    store.applyRemote({
      'user_id': 'sara',
      'templates': [
        [1, 2, 3]
      ],
    });
    await pumpEventQueue();
    expect(launches, 1);
  });

  test('a cleared print on an empty bank starts nothing', () async {
    store.applyRemote({'user_id': 'sara', 'deleted': true});
    await pumpEventQueue();
    expect(launches, 0);
  });

  test('a push from this till, such as the sign-in prompt, starts nothing',
      () async {
    store.saveUserTemplates('sara', [
      [1, 2, 3]
    ], announce: false);
    await store.pushToAgent();
    expect(launches, 0);
  });

  // On Windows this would start the real agent script.
  test('overlapping starts share one launch', () {
    final a = FingerprintAgentLauncher(port: 9299).ensureRunning();
    final b = FingerprintAgentLauncher(port: 9299).ensureRunning();
    expect(identical(a, b), isTrue);
  }, skip: Platform.isWindows);
}
