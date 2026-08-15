import 'dart:convert';

import 'odoo_endpoint.dart';
import 'odoo_sender.dart';

/// What happened when this till reached for its server.
///
/// Four answers, because "cannot sync" sends support in four different directions:
/// nobody typed a server in, nothing answered the address, something answered but
/// not an Odoo that will talk to us, or the login is wrong. A single red cross would
/// have a shop restarting its router over a mistyped password.
enum ServerCheck {
  ok,
  notConfigured,
  unreachable,
  refused,
  badCredentials,
}

class ServerCheckResult {
  const ServerCheckResult(this.outcome, {this.detail});

  final ServerCheck outcome;

  /// A short line for the screen: the status code, or the server's own refusal.
  /// Never the request body, which carries the login.
  final String? detail;

  bool get isOk => outcome == ServerCheck.ok;
}

/// The one reachability probe this app has.
///
/// `version_info` answers on any running Odoo, books nothing and needs no session,
/// which is why the online badge rides on it every 20 seconds. The button on the
/// server screen asks the same question rather than inventing a second definition of
/// "up" that could disagree with the badge.
Future<bool> serverIsReachable(
  OdooEndpoint? endpoint,
  HttpPost post, {
  Duration timeout = const Duration(seconds: 6),
}) async {
  if (endpoint == null || !endpoint.isComplete) return false;
  try {
    final reply = await _versionInfo(endpoint, post, timeout);
    return reply.statusCode >= 200 && reply.statusCode < 500;
  } catch (_) {
    return false;
  }
}

/// The same probe, plus the one question it cannot answer: whether this till's login
/// is accepted. Only ever run from a button, never on a timer, because it
/// authenticates and a shared login is not something to hammer.
///
/// It changes nothing on the server: `version_info` reads a version and
/// `session/authenticate` opens a session, which the sync loop does anyway on its
/// first push.
Future<ServerCheckResult> checkServer(
  OdooEndpoint? endpoint,
  HttpPost post, {
  Duration timeout = const Duration(seconds: 8),
}) async {
  if (endpoint == null || !endpoint.isComplete) {
    return const ServerCheckResult(ServerCheck.notConfigured);
  }
  try {
    final reply = await _versionInfo(endpoint, post, timeout);
    if (reply.statusCode >= 500) {
      return ServerCheckResult(ServerCheck.refused,
          detail: 'HTTP ${reply.statusCode}');
    }
    if (reply.statusCode >= 400) {
      // Something is listening, but it is not answering an Odoo endpoint: a proxy,
      // a parked domain, the wrong path.
      return ServerCheckResult(ServerCheck.refused,
          detail: 'HTTP ${reply.statusCode}');
    }
  } catch (e) {
    return ServerCheckResult(ServerCheck.unreachable, detail: _short(e));
  }

  try {
    final reply = await post(
      Uri.parse(endpoint.baseUrl).resolve('/web/session/authenticate'),
      const {'Content-Type': 'application/json'},
      jsonEncode({
        'jsonrpc': '2.0',
        'method': 'call',
        'params': {
          'db': endpoint.db,
          'login': endpoint.login,
          'password': endpoint.password ?? '',
        },
      }),
    ).timeout(timeout);
    final body = jsonDecode(reply.body);
    if (body is! Map) {
      return const ServerCheckResult(ServerCheck.refused,
          detail: 'unexpected reply');
    }
    // A wrong database and a wrong password both come back as an error rather than
    // a session, and the server's own message is the useful half of it.
    final error = body['error'];
    if (error != null) {
      return ServerCheckResult(ServerCheck.badCredentials,
          detail: _messageOf(error));
    }
    final uid = (body['result'] as Map?)?['uid'];
    if (uid == null) {
      return const ServerCheckResult(ServerCheck.badCredentials,
          detail: 'login refused');
    }
    return const ServerCheckResult(ServerCheck.ok);
  } catch (e) {
    // The server answered the version probe a moment ago, so this is the login call
    // itself failing rather than the box being off.
    return ServerCheckResult(ServerCheck.unreachable, detail: _short(e));
  }
}

Future<HttpReply> _versionInfo(
        OdooEndpoint endpoint, HttpPost post, Duration timeout) =>
    post(
      Uri.parse(endpoint.baseUrl).resolve('/web/webclient/version_info'),
      const {'Content-Type': 'application/json'},
      '{"jsonrpc":"2.0","method":"call","params":{}}',
    ).timeout(timeout);

/// The server's own words for why it said no, without the stack of frames Odoo
/// wraps them in.
String _messageOf(Object? error) {
  if (error is Map) {
    final data = error['data'];
    if (data is Map && data['message'] is String) {
      return _trim(data['message'] as String);
    }
    if (error['message'] is String) return _trim(error['message'] as String);
  }
  return 'login refused';
}

/// One line, so a transport failure reads as a reason and not as a wall of text.
String _short(Object e) => _trim(e.toString());

String _trim(String s) {
  final line = s.trim().split('\n').first.trim();
  return line.length > 120 ? '${line.substring(0, 120)}...' : line;
}
