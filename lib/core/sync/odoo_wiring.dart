import 'http_post.dart';
import 'odoo_endpoint.dart';
import 'odoo_sender.dart';
import 'outbox.dart';

/// Connects a configured [OdooEndpoint] to the [Outbox].
///
/// Registers an order sender that authenticates on demand and re-authenticates
/// when the session lapses. Selling never waits on any of this: the outbox drains
/// on the sync timer, off the path of a sale.
class OdooWiring {
  OdooWiring({
    required Outbox outbox,
    HttpPostFn? post,
    this.onOrderBooked,
    this.onOrderRejected,
  })  : _outbox = outbox,
        _post = post ?? httpPost;

  final Outbox _outbox;
  final HttpPostFn _post;

  /// Called with a sale's uuid (and optional Odoo id / document name) once the
  /// server has booked it, so the till can mark the order synced and End of Day
  /// can show the SO number on the close screen.
  final void Function(String uuid, [int? serverId, String? serverName])?
      onOrderBooked;

  /// Called when the server permanently refused a sale, so the money impact of a
  /// parked order reaches the audit trail instead of only the diagnostics count.
  final void Function(String uuid, String reason)? onOrderRejected;
  OdooSender? _sender;
  OdooEndpoint? _endpoint;

  bool get isConfigured => _endpoint != null;

  /// The Odoo user the till is authenticated as, or null before the first login.
  /// The catalogue pull reads it to narrow the tenders to what that user may take.
  int? get uid => _sender?.uid;

  /// Point the outbox at [endpoint]. Safe to call again when settings change; it
  /// rebuilds the sender so a new URL or login takes effect without a restart.
  void configure(OdooEndpoint endpoint) {
    _endpoint = endpoint;
    _sender = OdooSender(
      baseUrl: Uri.parse(endpoint.baseUrl),
      db: endpoint.db,
      post: _post,
    );
    _outbox.register('order.push', _orderSender);
    // Audit and heartbeat have no server sink yet, so they are acknowledged locally
    // and drained. They must NOT go through the order sender: that posts to
    // pos.order/create_from_offline_pos, which would book audit rows as sales. The
    // local audit log stays the record; a dedicated endpoint is the follow-up.
    _outbox.register('audit.push', (_) async {});
    _outbox.register('device.status', (_) async {});
  }

  /// Stop syncing: a till pointed at the wrong server should queue, not push there.
  void disable() {
    _endpoint = null;
    _sender = null;
    _outbox.unregister('order.push');
    _outbox.unregister('audit.push');
    _outbox.unregister('device.status');
  }

  /// Deliver one payload that is not an outbox row of its own: the merged shift
  /// batch. Same transport, same authentication, same shop ids and the same
  /// reading of the server's answer as a single sale, so the merged path cannot
  /// drift from the one it stands in for.
  ///
  /// Returns the module status dict (`id`, `name`, `status`) so End of Day can
  /// show the cashier the Odoo document that was booked.
  Future<Map<String, dynamic>?> pushPayload(
      String uuid, Map<String, dynamic> payload) async {
    final sender = _sender;
    final endpoint = _endpoint;
    if (sender == null || endpoint == null) {
      throw TransientSyncError('no Odoo endpoint configured');
    }
    if (!sender.isAuthenticated) {
      await sender.authenticate(endpoint.login, endpoint.password ?? '');
    }
    return sender.bookOrder(OutboxEntry(
        id: -1, kind: 'order.push', payloadUuid: uuid, payload: payload));
  }

  Future<void> _orderSender(OutboxEntry entry) async {
    try {
      final ack = await pushPayload(entry.payloadUuid, entry.payload);
      // Only order.push is routed here (audit and heartbeat have their own local
      // sinks), so a clean return means the server booked this sale.
      final id = (ack?['id'] as num?)?.toInt();
      final name = ack?['name']?.toString();
      onOrderBooked?.call(entry.payloadUuid, id, name);
    } on PermanentlyRejected catch (e) {
      onOrderRejected?.call(entry.payloadUuid, e.toString());
      rethrow;
    }
  }

  /// A `call` for the catalogue [OdooPuller]: authenticates on demand against the
  /// current endpoint, then runs one call_kw. It reads the live sender, so it
  /// works even though the puller is built before the endpoint is configured.
  Future<dynamic> catalogueCall(String model, String method,
      List<dynamic> args, Map<String, dynamic> kwargs) async {
    final sender = _sender;
    final endpoint = _endpoint;
    if (sender == null || endpoint == null) {
      throw TransientSyncError('no Odoo endpoint configured');
    }
    if (!sender.isAuthenticated) {
      await sender.authenticate(endpoint.login, endpoint.password ?? '');
    }
    return sender.callKw(model, method, args, kwargs);
  }
}

typedef HttpPostFn = Future<HttpReply> Function(
    Uri url, Map<String, String> headers, String body);
