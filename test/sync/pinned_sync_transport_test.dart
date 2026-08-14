import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/sync/http_post.dart';
import 'package:offline_pos/core/sync/odoo_sender.dart';
import 'package:offline_pos/core/sync/outbox.dart';

/// The certificate a fake server presents. Only the DER bytes matter: the pin is a
/// digest of exactly those.
class FakeCertificate implements X509Certificate {
  FakeCertificate(this.der);
  @override
  final Uint8List der;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeHeaders implements HttpHeaders {
  FakeHeaders([this.values = const {}]);
  final Map<String, String> values;
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {}
  @override
  void forEach(void Function(String name, List<String> values) action) =>
      values.forEach((name, value) => action(name, [value]));
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A reply that records whether anything ever read its body, which is how the tests
/// prove a refused certificate's answer never reaches the parser.
class FakeResponse extends Stream<List<int>> implements HttpClientResponse {
  FakeResponse({
    required this.statusCode,
    required this.body,
    this.certificate,
    Map<String, String> replyHeaders = const {},
  }) : headers = FakeHeaders(replyHeaders);

  @override
  final int statusCode;
  final String body;
  @override
  final X509Certificate? certificate;
  @override
  final HttpHeaders headers;
  bool bodyRead = false;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    bodyRead = true;
    return Stream<List<int>>.value(utf8.encode(body)).listen(onData,
        onError: onError, onDone: onDone, cancelOnError: cancelOnError);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeRequest implements HttpClientRequest {
  FakeRequest(this._response);
  final FakeResponse _response;
  final List<int> sent = [];
  @override
  final HttpHeaders headers = FakeHeaders();
  @override
  void add(List<int> data) => sent.addAll(data);
  @override
  Future<HttpClientResponse> close() async => _response;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Answers per url, so a test can hand back a different certificate on a later call
/// the way a server whose certificate was swapped mid-shift would.
class FakeClient implements HttpClient {
  FakeClient(this._respond, {this.certificateFor});
  final FakeResponse Function(Uri url) _respond;

  /// What the fake server presents mid-handshake. Set it and the refusal happens
  /// before there is a request to write to, which is what dart:io does when no root
  /// store can verify the chain.
  final X509Certificate? Function(Uri url)? certificateFor;

  final List<FakeRequest> requests = [];
  int closes = 0;
  @override
  Duration? connectionTimeout;
  @override
  bool Function(X509Certificate certificate, String host, int port)?
      badCertificateCallback;
  @override
  Future<HttpClientRequest> postUrl(Uri url) async {
    final presented = certificateFor?.call(url);
    final gate = badCertificateCallback;
    if (presented != null && gate != null && !gate(presented, url.host, url.port)) {
      throw const HandshakeException('certificate refused during the handshake');
    }
    final request = FakeRequest(_respond(url));
    requests.add(request);
    return request;
  }

  @override
  void close({bool force = false}) => closes++;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class MemStore implements OutboxStore {
  final List<OutboxEntry> entries = [];
  final Set<int> sent = {};
  final Map<int, String> dead = {};
  int _n = 1;
  @override
  Future<void> append(String k, String u, Map<String, dynamic> p) async =>
      entries.add(OutboxEntry(id: _n++, kind: k, payloadUuid: u, payload: p));
  @override
  Future<List<OutboxEntry>> pending({int limit = 20}) async => entries
      .where((e) => !sent.contains(e.id) && !dead.containsKey(e.id))
      .take(limit)
      .toList();
  @override
  Future<void> markSent(int id) async => sent.add(id);
  @override
  Future<void> markFailed(int id, String err) async {}
  @override
  Future<void> markDead(int id, String reason) async => dead[id] = reason;
}

void main() {
  final ours = Uint8List.fromList(List<int>.generate(64, (i) => i));
  final stranger = Uint8List.fromList(List<int>.generate(64, (i) => 255 - i));
  final pin = crypto.sha256.convert(ours).toString();
  final url = Uri.parse('https://odoo.example/web/session/authenticate');

  FakeResponse reply(Uint8List der) => FakeResponse(
        statusCode: 200,
        body: '{"result":{"uid":7}}',
        certificate: FakeCertificate(der),
        replyHeaders: const {'Set-Cookie': 'session_id=abc; Path=/'},
      );

  test('a build with no pins keeps the plain transport, so an existing shop is unchanged', () {
    // Not "pins nothing": literally the same function, which is the only way to
    // promise a shop that was never given a pin still syncs.
    expect(odooPost(const {}), same(httpPost));
    expect(odooPost({pin}), isNot(same(httpPost)));
  });

  test('a pinning transport with no pins is a build mistake, not a silent unpinned mode', () {
    expect(() => PinnedSyncTransport(certificateSha256: const {}),
        throwsArgumentError);
  });

  test('a certificate that does not match the pin is refused with the reply unread', () async {
    final response = reply(stranger);
    final client = FakeClient((_) => response);
    final transport = PinnedSyncTransport(
        certificateSha256: {pin}, openClient: () => client);

    await expectLater(
        transport.post(url, const {'Content-Type': 'application/json'}, '{}'),
        throwsA(isA<HttpException>()));
    // No body for the parser and no Set-Cookie for the session: an attacker on the
    // path gets nothing believed, and the socket is dropped with the client.
    expect(response.bodyRead, isFalse);
    expect(client.closes, 1);
  });

  test('the pin is checked mid-handshake, so a stranger is never sent the login', () async {
    // The body of an authenticate call IS the shared integration password, so the
    // refusal has to land before anything is written, not on the reply that comes back.
    final client = FakeClient(
      (_) => reply(ours),
      certificateFor: (_) => FakeCertificate(stranger),
    );
    final transport =
        PinnedSyncTransport(certificateSha256: {pin}, openClient: () => client);

    await expectLater(
      transport.post(url, const {'Content-Type': 'application/json'},
          '{"params":{"login":"integration","password":"the shared secret"}}'),
      throwsA(isA<HandshakeException>()),
    );
    // No request object was ever handed out, so there was nothing to write the
    // password to.
    expect(client.requests, isEmpty);
  });

  test('a pinned certificate passes the handshake and the call goes through', () async {
    final client = FakeClient(
      (_) => reply(ours),
      certificateFor: (_) => FakeCertificate(ours),
    );
    final transport =
        PinnedSyncTransport(certificateSha256: {pin}, openClient: () => client);

    final res = await transport.post(url, const {}, '{"jsonrpc":"2.0"}');

    expect(res.statusCode, 200);
    expect(client.requests.single.sent, isNotEmpty);
  });

  test('the pin gate recognises our certificate and refuses a stranger', () {
    final transport = PinnedSyncTransport(certificateSha256: {pin});

    expect(transport.acceptCertificate(FakeCertificate(ours)), isTrue);
    expect(transport.acceptCertificate(FakeCertificate(stranger)), isFalse);
  });

  test('a certificate presenting no chain at all is refused too', () async {
    final client = FakeClient((_) => FakeResponse(statusCode: 200, body: '{}'));
    final transport = PinnedSyncTransport(
        certificateSha256: {pin}, openClient: () => client);

    await expectLater(transport.post(url, const {}, '{}'),
        throwsA(isA<HttpException>()));
  });

  test('a matching certificate is accepted, body and headers intact', () async {
    final client = FakeClient((_) => reply(ours));
    // Spelled as an installer would paste it, upper case and padded: the pin is a
    // digest, not a string a shop should have to normalise by hand.
    final transport = PinnedSyncTransport(
        certificateSha256: {'  ${pin.toUpperCase()}  '},
        openClient: () => client);

    final result = await transport.post(url, const {}, '{}');
    expect(result.statusCode, 200);
    expect(result.body, '{"result":{"uid":7}}');
    // Lower-cased keys, because the sender reads the session cookie by that name.
    expect(result.headers['set-cookie'], contains('session_id=abc'));
  });

  test('a pinned till does not fall back to cleartext', () async {
    final client = FakeClient((_) => reply(ours));
    final transport = PinnedSyncTransport(
        certificateSha256: {pin}, openClient: () => client);

    await expectLater(
        transport.post(Uri.parse('http://odoo.example/web/session/authenticate'),
            const {}, '{}'),
        throwsA(isA<HttpException>()));
    expect(client.requests, isEmpty);
  });

  test('a refused certificate is transient, so a queued sale is kept not parked', () async {
    // The certificate is swapped after the till has signed in, which is what a
    // machine-in-the-middle appearing mid-shift looks like from the till.
    var presented = ours;
    final client = FakeClient((u) => u.path.contains('authenticate')
        ? reply(presented)
        : FakeResponse(
            statusCode: 200,
            body: '{"result":[{"status":"created","id":9}]}',
            certificate: FakeCertificate(presented),
          ));
    final transport = PinnedSyncTransport(
        certificateSha256: {pin}, openClient: () => client);
    final sender = OdooSender(
        baseUrl: Uri.parse('https://odoo.example'),
        db: 'shop',
        post: transport.post);

    await sender.authenticate('integration', 'secret');
    expect(sender.isAuthenticated, isTrue);
    presented = stranger;

    final store = MemStore();
    final outbox =
        Outbox(store: store, senders: {'order.push': sender.orderSender});
    await outbox.enqueue('order.push', 'u1', {'uuid': 'u1'});

    // Nothing sent, nothing dead-lettered, the sale still first in the queue: the
    // money is kept until the till reaches its own server again.
    expect(await outbox.drain(), 0);
    expect(store.dead, isEmpty);
    expect((await store.pending()).single.payloadUuid, 'u1');
  });

  test('a refusal reaches the sender as transient, never as a rejection', () async {
    final client = FakeClient((_) => reply(stranger));
    final transport = PinnedSyncTransport(
        certificateSha256: {pin}, openClient: () => client);
    final sender = OdooSender(
        baseUrl: Uri.parse('https://odoo.example'),
        db: 'shop',
        post: transport.post);

    await expectLater(sender.authenticate('integration', 'secret'),
        throwsA(isA<TransientSyncError>()));
    expect(sender.isAuthenticated, isFalse);
  });
}
