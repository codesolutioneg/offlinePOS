// Drives the REAL OdooSender against a REAL Odoo build over HTTPS.
//
// Skipped unless STAGING_URL/DB/USER/PASS are passed via --dart-define, so the
// normal suite and CI never touch the network. This is the test that proves the
// app's own sender code works end to end, not a reimplementation of it.
//
// Run:
//   flutter test integration_test/staging_sync_test.dart \
//     --dart-define=STAGING_URL=https://<build>.dev.odoo.com \
//     --dart-define=STAGING_DB=<db> \
//     --dart-define=STAGING_USER=<login> \
//     --dart-define=STAGING_PASS=<password> \
//     --dart-define=STAGING_PRODUCT=<product_id> \
//     --dart-define=STAGING_CONFIG=<pos_config_id>
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/sync/odoo_sender.dart';
import 'package:offline_pos/core/sync/outbox.dart';
import 'package:offline_pos/domain/order.dart';

const _url = String.fromEnvironment('STAGING_URL');
const _db = String.fromEnvironment('STAGING_DB');
const _user = String.fromEnvironment('STAGING_USER');
const _pass = String.fromEnvironment('STAGING_PASS');
const _product = int.fromEnvironment('STAGING_PRODUCT');
const _config = int.fromEnvironment('STAGING_CONFIG');

/// A real HttpPost backed by dart:io, capturing the response headers the sender
/// now depends on for the session cookie.
Future<HttpReply> realPost(Uri url, Map<String, String> headers, String body) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
  try {
    final req = await client.postUrl(url);
    headers.forEach(req.headers.set);
    req.add(utf8.encode(body));
    final res = await req.close();
    final text = await res.transform(utf8.decoder).join();
    final h = <String, String>{};
    res.headers.forEach((name, values) => h[name.toLowerCase()] = values.join(','));
    return HttpReply(res.statusCode, text, headers: h);
  } finally {
    client.close(force: true);
  }
}

void main() {
  final configured = _url.isNotEmpty && _user.isNotEmpty && _product > 0;

  test('offlinePOS sender books an order on a real Odoo build over HTTPS', () async {
    final sender = OdooSender(baseUrl: Uri.parse(_url), db: _db, post: realPost);
    await sender.authenticate(_user, _pass);
    expect(sender.isAuthenticated, isTrue);

    final order = Order(deviceId: 'till-1', cashierId: 'sara', createdAt: DateTime.utc(2026, 3, 2, 19))
      ..lines.add(OrderLine(productId: _product, name: 'Test', quantity: 2, unitPrice: 100));
    final payload = order.toMap()..['config_id'] = _config;

    final entry = OutboxEntry(id: 1, kind: 'order.push', payloadUuid: order.uuid, payload: payload);

    // First push succeeds. This is the whole chain: real auth, real cookie capture,
    // real create_from_offline_pos over the wire.
    await sender.orderSender(entry);

    // A repeat must not double-book: the sender relies on the server recognising the
    // uuid. If the cookie were not being carried, this second call would fail auth
    // instead of returning cleanly.
    await sender.orderSender(entry);
  }, skip: configured ? false : 'staging creds not provided via --dart-define');
}
