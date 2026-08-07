import 'dart:convert';
import 'dart:io';

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
