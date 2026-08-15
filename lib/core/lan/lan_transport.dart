import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../db/schema.dart';
import 'lan_applier.dart';
import 'lan_claim.dart';
import 'lan_credential.dart';
import 'lan_event.dart';
import 'lan_event_log.dart';
import 'lan_peer.dart';

/// A page of one peer's log, with the highest seq that page covers.
///
/// [highSeq] is not always the seq of the last event in [events]: a peer may hold
/// events this build cannot read, and the cursor still has to move past them or the
/// same page is fetched forever.
class LanPage {
  const LanPage({required this.events, required this.highSeq});

  static const LanPage empty = LanPage(events: [], highSeq: 0);

  final List<LanEvent> events;
  final int highSeq;
}

/// Fetches everything a peer has after [since]. Throws when the peer is
/// unreachable, which the fabric treats as "try again next pass".
typedef LanFetch = Future<LanPage> Function(LanPeer peer, int since);

/// Hands a peer some events immediately, so a second till is current in
/// milliseconds instead of on the next pull. Best-effort by design: the peer's own
/// cursor is durable, so a failed notify costs latency and nothing else.
typedef LanNotify = Future<void> Function(LanPeer peer, List<LanEvent> events);

/// What this till answers, as plain data. Deliberately free of dart:io so the
/// contract can be exercised without a socket: the HTTP server below is a thin
/// adapter over these two methods.
class LanReply {
  const LanReply(this.status, this.body);
  final int status;
  final Map<String, dynamic> body;
}

/// The two-request protocol a till serves to its peers: pull to catch up, notify to
/// keep up. Plain JSON over plain HTTP on the shop LAN.
///
/// Nothing here reaches a selling path. A request is handled on the event loop
/// between taps, and every failure is a status code plus a log line.
class LanProtocol {
  LanProtocol({
    required this.deviceId,
    required LanEventLog log,
    required LanApplier applier,
    required LanCredential credential,
    LanClaimDesk? claims,
    this.pageSize = 200,
    LanLog? onRefused,
  })  : _log = log,
        _applier = applier,
        _credential = credential,
        _claims = claims,
        _onRefused = onRefused;

  /// Everything a peer has after `since`.
  static const String eventsPath = '/lan/events';

  /// Events a peer is handing over right now.
  static const String notifyPath = '/lan/notify';

  /// A peer asking for a parked tab this till owns.
  ///
  /// Its own request rather than an event, because it is the one thing in the
  /// fabric that needs an answer: everything else is told, and this is asked. The
  /// ask is what makes the handover safe, so a till that cannot be reached simply
  /// keeps its tab.
  static const String claimPath = '/lan/claim';

  final String deviceId;
  final LanEventLog _log;
  final LanApplier _applier;
  final LanCredential _credential;

  /// Null on a device that hands nothing over (a kitchen screen owns no tabs).
  final LanClaimDesk? _claims;
  final int pageSize;
  final LanLog? _onRefused;

  LanReply handleGet(String path, Map<String, String> query, {String? auth}) {
    if (path != eventsPath) return const LanReply(404, {'error': 'unknown path'});
    final unpaired = _authRefusal(auth,
        method: 'GET',
        path: path,
        query: LanCredential.canonicalQuery(query),
        peer: query['peer']);
    if (unpaired != null) return unpaired;
    final refusal = _schemaRefusal(int.tryParse(query['schema'] ?? ''), query['peer']);
    if (refusal != null) return refusal;
    final since = int.tryParse(query['since'] ?? '') ?? 0;
    final events = _log.since(since, limit: pageSize);
    // The high-water mark is the log's own end when the page is short, so a peer
    // that has caught up stops asking for the same empty page.
    final last = _log.lastSeq;
    final highSeq = events.isEmpty
        ? (last > since ? last : since)
        : (events.last.seq >= last ? last : events.last.seq);
    return LanReply(200, {
      'device_id': deviceId,
      'schema': Schema.version,
      'high_seq': highSeq,
      'events': [for (final e in events) e.toMap()],
    });
  }

  LanReply handlePost(String path, String body, {String? auth}) {
    if (path != notifyPath && path != claimPath) {
      return const LanReply(404, {'error': 'unknown path'});
    }
    // Before the body is even parsed: an unpaired device gets no say in what this
    // till spends its time decoding.
    final unpaired = _authRefusal(auth, method: 'POST', path: path, body: body);
    if (unpaired != null) return unpaired;
    Map<String, dynamic> decoded;
    try {
      decoded = (jsonDecode(body) as Map).cast<String, dynamic>();
    } catch (e) {
      _onRefused?.call('lan.request.refused', 'unreadable notify body: $e');
      return const LanReply(400, {'error': 'unreadable body'});
    }
    final peer = decoded['device_id'];
    final refusal =
        _schemaRefusal(decoded['schema'] is int ? decoded['schema'] as int : null,
            peer is String ? peer : null);
    if (refusal != null) return refusal;
    if (peer is! String || peer.isEmpty) {
      return const LanReply(400, {'error': 'no device_id'});
    }
    if (path == claimPath) return _handleClaim(decoded, peer);
    final raw = decoded['events'];
    if (raw is! List) return const LanReply(400, {'error': 'no events'});
    final events = <LanEvent>[];
    var highSeq = 0;
    for (final entry in raw) {
      try {
        final event = LanEvent.fromMap((entry as Map).cast<String, dynamic>());
        if (event.seq > highSeq) highSeq = event.seq;
        events.add(event);
      } catch (e) {
        // One unreadable event does not spoil the page. It is logged and skipped,
        // and the cursor still advances past it: a till cannot be held up forever
        // by something it will never understand.
        _onRefused?.call('lan.event.refused', 'from $peer: $e');
        final seq = entry is Map ? entry['seq'] : null;
        if (seq is int && seq > highSeq) highSeq = seq;
      }
    }
    final applied = _applier.applyAll(peer, events, highSeq: highSeq);
    return LanReply(200, {'applied': applied});
  }

  /// Hand a parked tab to the peer asking for it, or say no and why.
  ///
  /// A refusal is 409 rather than an error: the peer asked a reasonable question
  /// and the answer is that the tab is not this till's to give. The answer carries
  /// the whole order so the claimer writes exactly what was let go of, rather than
  /// a version it happened to have replicated earlier.
  LanReply _handleClaim(Map<String, dynamic> decoded, String peer) {
    final desk = _claims;
    if (desk == null) {
      return const LanReply(409, {'error': 'this device hands nothing over'});
    }
    final uuid = decoded['order_uuid'];
    if (uuid is! String || uuid.isEmpty) {
      return const LanReply(400, {'error': 'no order_uuid'});
    }
    final cashier = decoded['cashier'];
    final result =
        desk.grant(uuid, peer, cashier: cashier is String ? cashier : null);
    final order = result.order;
    if (order == null) {
      return LanReply(409, {'error': result.detail ?? 'refused'});
    }
    return LanReply(200, {
      'device_id': deviceId,
      'schema': Schema.version,
      // Named so the claimer's audit entry can say where the tab came from without
      // having to trust its own idea of who owned it a moment ago.
      'order': {...order.toMap(), 'claim_from': deviceId},
    });
  }

  /// The first gate every request passes: proof the caller holds the shop key.
  ///
  /// Without this, matching the schema version was the whole entry test, which any
  /// device on the subnet can do. A guest phone could read the night's tabs off
  /// /lan/events, or push a floor plan and a pile of held orders into a till through
  /// /lan/notify. The stamp is checked against exactly this request, so it cannot be
  /// lifted off a pull and reused on a notify.
  LanReply? _authRefusal(
    String? presented, {
    required String method,
    required String path,
    String query = '',
    String body = '',
    String? peer,
  }) {
    final result = _credential.check(presented,
        method: method, path: path, query: query, body: body);
    if (result == LanAuth.ok) return null;
    _onRefused?.call(
      'lan.peer.refused',
      switch (result) {
        LanAuth.missing => '${peer ?? 'a device'} asked with no shop key at all',
        LanAuth.wrongKey =>
          '${peer ?? 'a device'} presented another shop\'s key, so it is paired '
              'somewhere else',
        LanAuth.staleClock => '${peer ?? 'a device'} stamped a request more than '
            '${LanCredential.clockTolerance.inMinutes} minutes out, so one of the '
            'two clocks is wrong',
        LanAuth.ok => '',
      },
    );
    return LanReply(401, {'error': result.name});
  }

  /// The second gate: a peer on another schema version is turned away before a single
  /// event is read, and told why in the log rather than left to look like a network
  /// problem.
  LanReply? _schemaRefusal(int? schema, String? peer) {
    if (schema == Schema.version) return null;
    _onRefused?.call(
      'lan.peer.refused',
      '${peer ?? 'a peer'} asked on schema ${schema ?? 'unstated'}, this till '
          'runs ${Schema.version}',
    );
    return LanReply(409, {'error': 'schema', 'schema': Schema.version});
  }
}

/// Serves [LanProtocol] over HTTP on the shop LAN.
///
/// Bound to the LAN address rather than to every interface, so this is a shop-floor
/// service and not something reachable from anywhere else the device happens to be
/// connected. A till that cannot find a LAN address does not open a socket at all.
class LanHost {
  LanHost({
    required LanProtocol protocol,
    this.port = 45333,
    LanLog? log,
    Future<HttpServer> Function(InternetAddress address, int port)? bind,
    Future<List<String>> Function()? localAddresses,
  })  : _protocol = protocol,
        _log = log,
        _bind = bind ?? HttpServer.bind,
        _localAddresses = localAddresses ?? lanAddresses;

  final LanProtocol _protocol;
  final int port;
  final LanLog? _log;
  final Future<HttpServer> Function(InternetAddress address, int port) _bind;
  final Future<List<String>> Function() _localAddresses;

  HttpServer? _server;

  /// The address this till is reachable on, or null while it is not serving.
  String? get host => _server?.address.address;

  /// The port actually bound, which is [port] unless the caller asked for 0 to let
  /// the machine choose. Shown on the LAN settings screen so support can see where
  /// the till is answering rather than assume.
  int? get boundPort => _server?.port;

  bool get isServing => _server != null;

  /// Never throws. A port already in use or an interface that vanished is logged
  /// and the till carries on selling with no fabric, which is the pre-fabric
  /// behaviour rather than a failure.
  Future<bool> start() async {
    if (_server != null) return true;
    final addresses = await _localAddresses();
    if (addresses.isEmpty) {
      _log?.call('lan.host.unavailable', 'no LAN address to bind to');
      return false;
    }
    try {
      final server = await _bind(InternetAddress(addresses.first), port);
      _server = server;
      server.listen(_serve, onError: (Object e) {
        _log?.call('lan.host.error', '$e');
      });
      return true;
    } catch (e) {
      _log?.call('lan.host.unavailable', 'cannot serve on ${addresses.first}:$port: $e');
      return false;
    }
  }

  Future<void> stop() async {
    final server = _server;
    _server = null;
    await server?.close(force: true);
  }

  Future<void> _serve(HttpRequest request) async {
    LanReply reply;
    try {
      final auth = request.headers.value(LanCredential.header);
      reply = switch (request.method) {
        'GET' => _protocol.handleGet(
            request.uri.path, request.uri.queryParameters, auth: auth),
        'POST' => _protocol.handlePost(
            request.uri.path, await utf8.decoder.bind(request).join(), auth: auth),
        _ => const LanReply(405, {'error': 'method'}),
      };
    } catch (e) {
      // A peer must never be able to take this till down with a request.
      _log?.call('lan.host.error', '${request.method} ${request.uri.path}: $e');
      reply = const LanReply(500, {'error': 'failed'});
    }
    try {
      request.response.statusCode = reply.status;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(reply.body));
      await request.response.close();
    } catch (_) {
      // The peer hung up mid-reply. It will ask again.
    }
  }
}

/// Talks to peers over HTTP. One short timeout for everything: this runs on a
/// background timer, and a till that fell off the switch must cost seconds, not a
/// stalled pass.
class LanHttpClient {
  LanHttpClient({required LanCredential credential, Duration? timeout, HttpClient? client})
      : timeout = timeout ?? const Duration(seconds: 3),
        _credential = credential,
        _client = client ?? HttpClient() {
    _client.connectionTimeout = this.timeout;
  }

  final Duration timeout;
  final LanCredential _credential;
  final HttpClient _client;

  Future<LanPage> fetch(LanPeer peer, int since) async {
    final query = {'since': '$since', 'schema': '${Schema.version}'};
    final url = peer.baseUrl
        .replace(path: LanProtocol.eventsPath, queryParameters: query);
    final body = await _send(
      'GET',
      url,
      null,
      _credential.stamp(
        method: 'GET',
        path: LanProtocol.eventsPath,
        query: LanCredential.canonicalQuery(query),
      ),
    );
    final decoded = (jsonDecode(body) as Map).cast<String, dynamic>();
    final raw = decoded['events'];
    final events = <LanEvent>[];
    if (raw is List) {
      for (final entry in raw) {
        // A page is applied as far as it can be read; the high-water mark below is
        // what moves the cursor past anything that could not be.
        try {
          events.add(LanEvent.fromMap((entry as Map).cast<String, dynamic>()));
        } catch (_) {
          continue;
        }
      }
    }
    final high = decoded['high_seq'];
    return LanPage(events: events, highSeq: high is int ? high : since);
  }

  Future<void> notify(LanPeer peer, List<LanEvent> events, String deviceId) async {
    if (events.isEmpty) return;
    final body = jsonEncode({
      'device_id': deviceId,
      'schema': Schema.version,
      'events': [for (final e in events) e.toMap()],
    });
    await _send(
      'POST',
      peer.baseUrl.replace(path: LanProtocol.notifyPath),
      body,
      // Signed over the body, so a peer cannot have its events swapped for someone
      // else's on the way in.
      _credential.stamp(
          method: 'POST', path: LanProtocol.notifyPath, body: body),
    );
  }

  /// Ask [peer] to hand over one parked tab, and answer with the order it let go
  /// of. Throws when the peer refuses or cannot be reached, which is exactly the
  /// case where the tab must stay where it is.
  Future<Map<String, dynamic>> claim(
    LanPeer peer, {
    required String orderUuid,
    required String deviceId,
    String? cashier,
  }) async {
    final body = jsonEncode({
      'device_id': deviceId,
      'schema': Schema.version,
      'order_uuid': orderUuid,
      'cashier': ?cashier,
    });
    final text = await _send(
      'POST',
      peer.baseUrl.replace(path: LanProtocol.claimPath),
      body,
      _credential.stamp(
          method: 'POST', path: LanProtocol.claimPath, body: body),
    );
    final decoded = (jsonDecode(text) as Map).cast<String, dynamic>();
    final order = decoded['order'];
    if (order is! Map) throw const FormatException('claim answered with no order');
    return order.cast<String, dynamic>();
  }

  Future<String> _send(String method, Uri url, String? body, String stamp) async {
    final request = await _client.openUrl(method, url).timeout(timeout);
    request.headers.set(LanCredential.header, stamp);
    if (body != null) {
      request.headers.contentType = ContentType.json;
      request.write(body);
    }
    final response = await request.close().timeout(timeout);
    final text = await utf8.decoder.bind(response).join().timeout(timeout);
    if (response.statusCode != 200) {
      throw HttpException('${response.statusCode} from $url: $text');
    }
    return text;
  }

  void close() => _client.close(force: true);
}

/// The device's own LAN addresses, IPv4 and non-loopback, in interface order.
///
/// Same assumption the printer sweep makes: a shop is one flat /24 behind one
/// router, and the first address is the one the tills see each other on.
Future<List<String>> lanAddresses() async {
  try {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
      includeLinkLocal: false,
    );
    return [
      for (final interface in interfaces)
        for (final address in interface.addresses) address.address,
    ];
  } catch (_) {
    return const [];
  }
}
