import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;

/// HTTPS fetches for the update channel, against pinned certificates.
///
/// docs/SECURITY.md requires certificate pinning, and the update channel is where
/// it matters most: a till on a shop LAN resolves names through whatever the local
/// router says, and a device with an operator-installed CA trusts a certificate the
/// vendor never issued. Pinning removes the public CA set from the decision.
///
/// The signature on the manifest is still the thing that decides what gets
/// installed. Pinning is the outer layer: it stops an attacker on the path from
/// being able to answer at all, so a forged manifest never even reaches the
/// verifier.
class PinnedUpdateTransport {
  /// [certificateSha256] holds lowercase hex digests of the DER form of the
  /// certificates this client will talk to. More than one so a rotation can be
  /// staged: ship the new pin, then swap the certificate.
  ///
  /// There is no "empty means do not pin" mode. An update channel configured
  /// without pins is one an attacker on the path can answer for, and a silent
  /// downgrade to the public CA set is exactly the failure this is here to stop.
  PinnedUpdateTransport({
    required Set<String> certificateSha256,
    this.timeout = const Duration(seconds: 30),
    HttpClient? client,
  })  : _pins = {for (final p in certificateSha256) p.trim().toLowerCase()},
        _client = client ?? HttpClient() {
    if (_pins.isEmpty) {
      throw ArgumentError.value(certificateSha256, 'certificateSha256',
          'at least one certificate pin is required');
    }
    _client.connectionTimeout = timeout;
    // The pin is the whole check, and it happens below on the certificate the
    // server actually presented. Accepting a chain the public CA set rejects here
    // would widen trust, so this stays at the default of refusing.
  }

  final Set<String> _pins;
  final Duration timeout;
  final HttpClient _client;

  Future<String> fetchText(Uri url) async =>
      utf8.decode(await fetchBytes(url));

  Future<List<int>> fetchBytes(Uri url) async {
    if (url.scheme != 'https') {
      throw ArgumentError.value(url.toString(), 'url', 'must be https');
    }
    final request = await _client.getUrl(url).timeout(timeout);
    final response = await request.close().timeout(timeout);

    final certificate = response.certificate;
    if (certificate == null || !_pins.contains(_digest(certificate))) {
      // Nothing is read from a connection that failed the pin, so a body from an
      // unexpected certificate never reaches the parser.
      response.detachSocket().then((s) => s.destroy(), onError: (_) {});
      throw const HttpException('update host presented an unpinned certificate');
    }

    if (response.statusCode != 200) {
      throw HttpException('update host answered ${response.statusCode}');
    }

    final bytes = <int>[];
    await for (final chunk in response) {
      bytes.addAll(chunk);
    }
    return bytes;
  }

  static String _digest(X509Certificate certificate) =>
      crypto.sha256.convert(certificate.der).toString();
}
