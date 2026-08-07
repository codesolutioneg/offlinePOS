import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/sync/odoo_sender.dart';
import 'package:offline_pos/core/sync/outbox.dart';

OdooSender sender(HttpPost post) =>
    OdooSender(baseUrl: Uri.parse('https://odoo.example'), db: 'prod', post: post);

OutboxEntry entry() =>
    OutboxEntry(id: 1, kind: 'order.push', payloadUuid: 'u1', payload: {'uuid': 'u1'});

void main() {
  test('authenticates and remembers the session', () async {
    final s = sender((u, h, b) async =>
        HttpReply(200, jsonEncode({'result': {'uid': 2}})));
    await s.authenticate('admin', 'pw');
    expect(s.isAuthenticated, isTrue);
  });

  test('wrong credentials are permanent, not retried forever', () async {
    final s = sender((u, h, b) async => HttpReply(200, jsonEncode({'result': {}})));
    expect(() => s.authenticate('admin', 'bad'), throwsA(isA<PermanentSyncError>()));
  });

  test('a dead socket is transient so the sale is never dropped', () async {
    final s = sender((u, h, b) async => throw Exception('connection refused'));
    expect(() => s.authenticate('a', 'b'), throwsA(isA<TransientSyncError>()));
  });

  test('5xx and 429 are transient, 4xx is permanent', () async {
    for (final code in [500, 503, 429]) {
      final s = sender((u, h, b) async => HttpReply(code, ''));
      expect(() => s.authenticate('a', 'b'), throwsA(isA<TransientSyncError>()),
          reason: 'HTTP $code');
    }
    final s = sender((u, h, b) async => HttpReply(400, ''));
    expect(() => s.authenticate('a', 'b'), throwsA(isA<PermanentSyncError>()));
  });

  test('an HTML body from a captive portal is transient, not a bad request', () async {
    final s = sender((u, h, b) async => HttpReply(200, '<html>Sign in to wifi</html>'));
    expect(() => s.authenticate('a', 'b'), throwsA(isA<TransientSyncError>()));
  });

  test('the order push carries the client uuid so a repeat is recognisable', () async {
    String? seen;
    final s = sender((u, h, b) async {
      final decoded = jsonDecode(b) as Map<String, dynamic>;
      if (u.path.contains('authenticate')) {
        return HttpReply(200, jsonEncode({'result': {'uid': 2}}));
      }
      final args = (decoded['params'] as Map)['args'] as List;
      seen = ((args.first as List).first as Map)['uuid'] as String;
      return HttpReply(200, jsonEncode({'result': 7}));
    });
    await s.authenticate('a', 'b');
    await s.orderSender(entry());
    expect(seen, 'u1');
  });

  test('pushing before authentication is transient, so it waits rather than fails', () async {
    final s = sender((u, h, b) async => HttpReply(200, jsonEncode({'result': 1})));
    expect(() => s.orderSender(entry()), throwsA(isA<TransientSyncError>()));
  });

  test('an expired session is transient and clears the login', () async {
    var calls = 0;
    final s = sender((u, h, b) async {
      calls++;
      if (calls == 1) return HttpReply(200, jsonEncode({'result': {'uid': 2}}));
      return HttpReply(200, jsonEncode({'error': {'message': 'Session expired'}}));
    });
    await s.authenticate('a', 'b');
    expect(() => s.orderSender(entry()), throwsA(isA<TransientSyncError>()));
    await Future<void>.delayed(Duration.zero);
    expect(s.isAuthenticated, isFalse);
  });

  test('a business rejection is permanent and surfaced', () async {
    var calls = 0;
    final s = sender((u, h, b) async {
      calls++;
      if (calls == 1) return HttpReply(200, jsonEncode({'result': {'uid': 2}}));
      return HttpReply(200, jsonEncode({'error': {'message': 'session already closed'}}));
    });
    await s.authenticate('a', 'b');
    expect(() => s.orderSender(entry()), throwsA(isA<PermanentSyncError>()));
  });
}
