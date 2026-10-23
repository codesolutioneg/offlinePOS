import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/db/database.dart';
import 'package:offline_pos/core/db/sqlite_outbox_store.dart';
import 'package:offline_pos/core/sync/http_post.dart';
import 'package:offline_pos/core/sync/outbox.dart';

import '../db/sqlite_loader.dart';

/// M8: a reply that starts and then stops, as a dropped Wi-Fi or a hung proxy
/// leaves it, must end the read instead of holding the close and the queue open.
void main() {
  setUpAll(useSystemSqlite);

  test('a reply that stalls half way ends in a timeout, not a hang', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((req) async {
      req.response
        ..statusCode = 200
        ..contentLength = 1000
        ..write('{"partial":');
      await req.response.flush();
      // Never finishes: the headers are in, the body never ends.
    });
    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    final req = await client.postUrl(Uri.parse('http://127.0.0.1:${server.port}/'));
    final res = await req.close();

    await expectLater(
      readReply(res, timeout: const Duration(milliseconds: 300)),
      throwsA(isA<TimeoutException>()),
    );
  });

  test('a sale whose send timed out stays queued for the next try', () async {
    final db = Db.open(':memory:');
    addTearDown(db.close);
    final store = SqliteOutboxStore(db);
    final outbox = Outbox(store: store, senders: {
      'order.push': (_) => Future<void>.error(TimeoutException('reply stalled')),
    });
    await outbox.enqueue('order.push', 's-1', {'uuid': 's-1'});

    await outbox.drain();

    expect(store.pendingSalesCount, 1);
    expect(store.deadCount, 0, reason: 'a stalled line is not the server refusing');
  });
}
