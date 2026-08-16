import 'dart:convert';

import '../../domain/payload_balance.dart';
import 'odoo_site.dart';
import 'outbox.dart';

/// Thrown when the server is unreachable or replies with a transport-level error.
/// The outbox retries these forever: a sale is never dropped because a line was down.
class TransientSyncError implements Exception {
  TransientSyncError(this.message);
  final String message;
  @override
  String toString() => 'TransientSyncError: $message';
}

/// Thrown when the server understood the request and refused it. Retrying will not
/// help, so it is surfaced for a human instead of looping.
class PermanentSyncError implements Exception {
  PermanentSyncError(this.message);
  final String message;
  @override
  String toString() => 'PermanentSyncError: $message';
}

/// A refusal of one order becomes the outbox's parking signal, so a single bad
/// sale cannot strand a week of takings queued behind it.
PermanentlyRejected _park(String reason) => PermanentlyRejected(reason);

/// Minimal HTTP contract, so the sender can be tested without a socket.
typedef HttpPost = Future<HttpReply> Function(
    Uri url, Map<String, String> headers, String body);

class HttpReply {
  const HttpReply(this.statusCode, this.body, {this.headers = const {}});
  final int statusCode;
  final String body;

  /// Response headers, lower-cased keys. Needed to read the session cookie Odoo
  /// sets on authenticate: without carrying it back, every call after login is
  /// unauthenticated. A live round trip is the only thing that catches this; a
  /// fake that returns a body but no headers does not.
  final Map<String, String> headers;
}

/// Pushes queued orders to Odoo.
///
/// The order arrives carrying the client uuid it was created with, so the server can
/// recognise a repeat. That matters because a drain can be interrupted after the
/// server committed but before the acknowledgement was recorded, which means every
/// push must be safe to repeat.
/// The till id sent for order routing: the server books each offline order into
/// the pos.config whose "offline till id" equals this. Overridable per build with
/// --dart-define=OFFLINE_TILL_ID; defaults to the id the staging till is set to.
const String kOfflineTillId =
    String.fromEnvironment('OFFLINE_TILL_ID', defaultValue: 'till-1');

class OdooSender {
  OdooSender({
    required this.baseUrl,
    required this.db,
    required this.post,
    this.model = 'sale.order',
    this.method = 'create_from_offline_pos',
    this.tillId = kOfflineTillId,
    OdooSite Function()? site,
  }) : _site = site ?? _publishedSite;

  /// The shop's ids, read at push time. A function rather than a value because the
  /// sender outlives any one setting: a manager can name the branch after the till
  /// has been selling offline for a week, and those queued sales must still carry it.
  final OdooSite Function() _site;

  static OdooSite _publishedSite() => OdooSite.shared;

  final Uri baseUrl;
  final String db;
  final HttpPost post;
  final String model;
  final String method;

  /// Which pos.config this till's orders belong to, matched server-side.
  final String tillId;

  int? _uid;
  String? _sessionCookie;

  /// Authenticate and keep the session. Called by the sync loop when it has a line,
  /// never from a selling screen.
  Future<void> authenticate(String login, String password) async {
    final reply = await _call('/web/session/authenticate', {
      'db': db,
      'login': login,
      'password': password,
    });
    final uid = (reply['result'] as Map?)?['uid'];
    if (uid == null) {
      // Wrong credentials are permanent; a 5xx on the way there is not.
      throw PermanentSyncError('authentication rejected');
    }
    _uid = uid as int;
  }

  /// Extract the Odoo session id from a Set-Cookie header so it can be replayed on
  /// every later request. Odoo authenticates by cookie, not by a token in the body.
  void _captureCookie(HttpReply reply) {
    final raw = reply.headers['set-cookie'];
    if (raw == null) return;
    final match = RegExp(r'session_id=([^;]+)').firstMatch(raw);
    if (match != null) _sessionCookie = 'session_id=${match.group(1)}';
  }

  bool get isAuthenticated => _uid != null;

  /// An [OutboxSender] for 'order.push' entries.
  OutboxSender get orderSender => (OutboxEntry entry) async {
        if (!isAuthenticated) {
          // Not a refusal: the till simply has not signed in yet. Keep the sale.
          throw TransientSyncError('not authenticated yet');
        }
        try {
          // Route this order to the right pos.config: the server matches the
          // payload's device_id against each config's offline till id, unless the
          // shop named the point of sale outright below.
          final payload = Map<String, dynamic>.from(entry.payload);
          if (tillId.isNotEmpty) payload['device_id'] = tillId;
          // Which branch, point of sale and warehouse this sale belongs to. Stamped
          // here rather than when the sale was rung so it is the shop's current
          // answer, not the one in force during the outage.
          payload.addAll(_site().payloadFields);
          // The server totals the sale from the lines and settles it from the
          // payments. A payload where those two disagree either fails to book or
          // books for the wrong money, so it is stopped here and put in front of a
          // human rather than sent and hoped for. The sale itself is not lost: a
          // parked entry keeps its payload and shows on the diagnostics screen.
          final imbalance = payloadImbalanceReason(payload);
          if (imbalance != null) throw _park(imbalance);
          final reply = await _call('/web/dataset/call_kw', {
            'model': model,
            'method': method,
            'args': [
              [payload]
            ],
            'kwargs': {},
          });
          final result = reply['result'];
          if (result == null) {
            throw PermanentlyRejected('no result for ${entry.payloadUuid}');
          }
          // The module returns one status dict per order: created/duplicate mean the
          // sale is booked (a duplicate is a safe repeat, still an ack); rejected
          // means retrying cannot help (deleted product, locked period), so park it
          // rather than loop or silently drop a genuine sale.
          final status = result is List && result.isNotEmpty && result.first is Map
              ? (result.first as Map)['status']
              : null;
          if (status == 'rejected') {
            final message = (result.first as Map)['message']?.toString() ??
                'rejected by server';
            throw _park(message);
          }
        } on PermanentSyncError catch (e) {
          // The server understood the order and refused it. Retrying cannot help,
          // so park this one and let everything behind it through.
          throw _park(e.message);
        }
      };

  /// One authenticated `call_kw`, used for reads such as the catalogue pull.
  /// Returns the raw `result`. Authentication is the caller's responsibility,
  /// exactly like the order path, so a read never blocks a sale.
  Future<dynamic> callKw(String model, String method, List<dynamic> args,
      Map<String, dynamic> kwargs) async {
    final reply = await _call('/web/dataset/call_kw', {
      'model': model,
      'method': method,
      'args': args,
      'kwargs': kwargs,
    });
    return reply['result'];
  }

  Future<Map<String, dynamic>> _call(String path, Map<String, dynamic> params) async {
    final headers = {
      'Content-Type': 'application/json',
      'Cookie': ?_sessionCookie,
    };
    final body = jsonEncode({
      'jsonrpc': '2.0',
      'method': 'call',
      'params': params,
    });

    late HttpReply reply;
    try {
      reply = await post(baseUrl.resolve(path), headers, body);
    } catch (e) {
      // Socket-level failure: the normal state during an outage.
      throw TransientSyncError('$e');
    }

    // 5xx and 429 are worth retrying; a 4xx means we are asking wrongly.
    if (reply.statusCode >= 500 || reply.statusCode == 429) {
      throw TransientSyncError('HTTP ${reply.statusCode}');
    }
    if (reply.statusCode >= 400) {
      throw PermanentSyncError('HTTP ${reply.statusCode}');
    }

    final Map<String, dynamic> decoded;
    try {
      decoded = jsonDecode(reply.body) as Map<String, dynamic>;
    } catch (_) {
      // A captive portal or proxy returning HTML looks exactly like this. It is a
      // network condition, not a bad request, so it must be retried.
      throw TransientSyncError('response was not JSON');
    }

    _captureCookie(reply);

    final error = decoded['error'];
    if (error != null) {
      final message = (error is Map ? error['message'] : error).toString();
      // Odoo reports an expired session as an error payload, not a status code.
      if (message.contains('Session expired') || message.contains('SessionExpired')) {
        _uid = null;
        throw TransientSyncError('session expired');
      }
      throw PermanentSyncError(message);
    }
    return decoded;
  }
}
