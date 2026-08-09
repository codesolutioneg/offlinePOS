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
  OdooWiring({required Outbox outbox, HttpPostFn? post})
      : _outbox = outbox,
        _post = post ?? httpPost;

  final Outbox _outbox;
  final HttpPostFn _post;
  OdooSender? _sender;
  OdooEndpoint? _endpoint;

  bool get isConfigured => _endpoint != null;

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
    _outbox.register('audit.push', _orderSender);
    // Best-effort telemetry with no server sink yet: acknowledge it so it drains
    // cleanly instead of showing as "nothing can send" on the Support screen.
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

  Future<void> _orderSender(OutboxEntry entry) async {
    final sender = _sender;
    final endpoint = _endpoint;
    if (sender == null || endpoint == null) {
      // Not configured yet. Transient, so the sale stays queued rather than parked.
      throw TransientSyncError('no Odoo endpoint configured');
    }
    if (!sender.isAuthenticated) {
      // Authenticate lazily and only when the line is up. A failure here is
      // transient (server down / wrong-for-now), so the sale is kept and retried.
      await sender.authenticate(endpoint.login, endpoint.password ?? '');
    }
    await sender.orderSender(entry);
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
