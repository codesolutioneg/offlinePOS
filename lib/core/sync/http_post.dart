import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;

import 'odoo_sender.dart';

/// A real [HttpPost] over dart:io, capturing response headers so the sender can
/// read the session cookie Odoo sets on authenticate.
///
/// Kept tiny and dependency-free; the sender takes this as an injected function so
/// tests can substitute a fake with no socket.
Future<HttpReply> httpPost(Uri url, Map<String, String> headers, String body) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
  try {
    final req = await client.postUrl(url);
    headers.forEach(req.headers.set);
    req.add(utf8.encode(body));
    final res = await req.close().timeout(const Duration(seconds: 30));
    final text = await res.transform(utf8.decoder).join();
    final h = <String, String>{};
    res.headers.forEach((name, values) => h[name.toLowerCase()] = values.join(','));
    return HttpReply(res.statusCode, text, headers: h);
  } finally {
    client.close(force: true);
  }
}

/// The [HttpPost] every Odoo call goes through: [httpPost] when this build carries
/// no pins for the server, the pinned one when it does.
///
/// Chosen once, at wiring time, so the decision is visible in one place rather than
/// re-derived per call, and so a shop with no pins configured runs exactly the code
/// it ran before.
HttpPost odooPost(Set<String> certificateSha256) => certificateSha256.isEmpty
    ? httpPost
    : PinnedSyncTransport(certificateSha256: certificateSha256).post;

/// [httpPost] with the server's certificate checked against a pin, the same digest
/// of the same DER the update channel pins (see PinnedUpdateTransport).
///
/// This is the path that carries the shared integration login and, at close, the
/// day's takings. Without a pin those go to whatever chain the device happens to
/// trust, which on a shop LAN means whatever the local router resolves and whatever
/// CA an operator installed. docs/SECURITY.md asks for pinning on the API.
///
/// dart:io reports the certificate with the response, so the check lands before any
/// reply is read, parsed, or believed about a session. A wrong certificate therefore
/// never yields a working session or a booked sale, and every later call is refused
/// the same way.
class PinnedSyncTransport {
  /// [certificateSha256] holds lowercase hex digests of the DER form of the
  /// certificates this till will talk to. More than one so a rotation can be staged:
  /// ship the new pin, then swap the certificate.
  ///
  /// An empty set is a build mistake here rather than a quiet unpinned mode. Whether
  /// a build pins at all is [odooPost]'s decision, and it answers "no pins" by
  /// handing back the plain transport instead of a pinning one that pins nothing.
  ///
  /// [openClient] exists for tests. It is a factory, not a client, because a client
  /// per call and force-closed is what [httpPost] does today and a pinned build must
  /// not change that.
  PinnedSyncTransport({
    required Set<String> certificateSha256,
    HttpClient Function()? openClient,
  })  : _pins = {for (final p in certificateSha256) p.trim().toLowerCase()},
        _openClient = openClient ?? HttpClient.new {
    if (_pins.isEmpty) {
      throw ArgumentError.value(certificateSha256, 'certificateSha256',
          'at least one certificate pin is required');
    }
  }

  final Set<String> _pins;
  final HttpClient Function() _openClient;

  /// Same signature, same timeouts and same header handling as [httpPost], so the
  /// only difference a pinned build sees is the refusal.
  ///
  /// Throws on a certificate that does not match. The sender turns anything thrown
  /// here into a transient error, which is what a queued sale needs: kept and
  /// retried, never parked as if the server had refused the money.
  Future<HttpReply> post(Uri url, Map<String, String> headers, String body) async {
    if (url.scheme != 'https') {
      // There is no certificate to check on cleartext, so a pinned till pointed at
      // http:// would be pinned in name only.
      throw const HttpException('a pinned till syncs over https only');
    }
    final client = _openClient()..connectionTimeout = const Duration(seconds: 20);
    try {
      final req = await client.postUrl(url);
      headers.forEach(req.headers.set);
      req.add(utf8.encode(body));
      final res = await req.close().timeout(const Duration(seconds: 30));

      final certificate = res.certificate;
      if (certificate == null || !_pins.contains(_digest(certificate))) {
        // Nothing is read from a connection that failed the pin: no body for the
        // JSON parser, no Set-Cookie for the session. The force-close below drops
        // the connection with the reply still unread.
        throw const HttpException('Odoo host presented an unpinned certificate');
      }

      final text = await res.transform(utf8.decoder).join();
      final h = <String, String>{};
      res.headers.forEach((name, values) => h[name.toLowerCase()] = values.join(','));
      return HttpReply(res.statusCode, text, headers: h);
    } finally {
      client.close(force: true);
    }
  }

  static String _digest(X509Certificate certificate) =>
      crypto.sha256.convert(certificate.der).toString();
}
