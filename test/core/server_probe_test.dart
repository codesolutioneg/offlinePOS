import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/sync/odoo_endpoint.dart';
import 'package:offline_pos/core/sync/odoo_sender.dart';
import 'package:offline_pos/core/sync/server_probe.dart';

/// "It does not sync" has four different fixes behind it, and a till that cannot
/// say which one it needs sends a shop looking at its router over a typo.
void main() {
  const endpoint = OdooEndpoint(
    baseUrl: 'https://shop.example.com',
    db: 'shop',
    login: 'till@example.com',
    password: 'secret',
  );

  /// A server that answers each path with what it is told to.
  HttpPost server({
    HttpReply? version,
    HttpReply? authenticate,
    Object? throwsOnVersion,
    Object? throwsOnAuthenticate,
    List<Uri>? calls,
  }) =>
      (uri, headers, body) async {
        calls?.add(uri);
        if (uri.path.contains('version_info')) {
          if (throwsOnVersion != null) throw throwsOnVersion;
          return version ?? const HttpReply(200, '{"result":{}}');
        }
        if (throwsOnAuthenticate != null) throw throwsOnAuthenticate;
        return authenticate ?? const HttpReply(200, '{"result":{"uid":2}}');
      };

  test('an unconfigured till says so rather than blaming the network', () async {
    final result = await checkServer(null, server());
    expect(result.outcome, ServerCheck.notConfigured);

    final half = await checkServer(
        const OdooEndpoint(baseUrl: 'https://shop.example.com', db: '', login: ''),
        server());
    expect(half.outcome, ServerCheck.notConfigured);
  });

  test('nothing answering is unreachable, with the reason', () async {
    final result = await checkServer(endpoint,
        server(throwsOnVersion: const SocketExceptionLike('no route to host')));

    expect(result.outcome, ServerCheck.unreachable);
    expect(result.detail, contains('no route to host'));
  });

  test('a server error is a refusal, not an outage', () async {
    final result = await checkServer(
        endpoint, server(version: const HttpReply(502, 'bad gateway')));

    expect(result.outcome, ServerCheck.refused);
    expect(result.detail, 'HTTP 502');
  });

  test('a page that is not Odoo is a refusal too', () async {
    final result = await checkServer(
        endpoint, server(version: const HttpReply(404, 'not found')));

    expect(result.outcome, ServerCheck.refused);
  });

  test('a wrong password is named as a wrong password', () async {
    final result = await checkServer(
      endpoint,
      server(
          authenticate: const HttpReply(
              200, '{"error":{"data":{"message":"Access denied"}}}')),
    );

    expect(result.outcome, ServerCheck.badCredentials);
    expect(result.detail, 'Access denied');
  });

  test('a wrong database is the server refusing the login, with its own words',
      () async {
    final result = await checkServer(
      endpoint,
      server(
          authenticate: const HttpReply(200,
              '{"error":{"data":{"message":"Database shop does not exist"}}}')),
    );

    expect(result.outcome, ServerCheck.badCredentials);
    expect(result.detail, 'Database shop does not exist');
  });

  test('a session with no uid is refused rather than read as success', () async {
    final result = await checkServer(
        endpoint, server(authenticate: const HttpReply(200, '{"result":{}}')));

    expect(result.outcome, ServerCheck.badCredentials);
  });

  test('a reachable server that takes the login is the only ok', () async {
    final calls = <Uri>[];
    final result = await checkServer(endpoint, server(calls: calls));

    expect(result.outcome, ServerCheck.ok);
    expect(result.isOk, isTrue);
    // The same version probe the badge uses, then the login, and nothing else: no
    // order is pushed and nothing is booked by pressing the button.
    expect(calls.map((u) => u.path),
        ['/web/webclient/version_info', '/web/session/authenticate']);
  });

  group('the badge probe', () {
    test('is the same version_info call and answers plainly', () async {
      expect(await serverIsReachable(endpoint, server()), isTrue);
      expect(
          await serverIsReachable(
              endpoint, server(version: const HttpReply(500, ''))),
          isFalse);
      expect(
          await serverIsReachable(
              endpoint, server(throwsOnVersion: const SocketExceptionLike('down'))),
          isFalse);
      expect(await serverIsReachable(null, server()), isFalse);
    });

    test('never authenticates, because it runs on a timer', () async {
      final calls = <Uri>[];
      await serverIsReachable(endpoint, server(calls: calls));
      expect(calls.map((u) => u.path), ['/web/webclient/version_info']);
    });

    test('a server that hangs is not online', () async {
      Future<HttpReply> hangs(Uri uri, Map<String, String> headers, String body) =>
          Completer<HttpReply>().future;
      expect(
          await serverIsReachable(endpoint, hangs,
              timeout: const Duration(milliseconds: 50)),
          isFalse);
    });
  });
}

/// Stands in for the transport failure a real socket throws, without needing one.
class SocketExceptionLike implements Exception {
  const SocketExceptionLike(this.message);
  final String message;
  @override
  String toString() => 'SocketException: $message';
}
