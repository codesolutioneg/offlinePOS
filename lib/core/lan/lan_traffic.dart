import 'lan_event.dart';

/// What passed between this device and one peer since the app started, for the
/// shop network screen.
///
/// In memory only: it answers "is that till keeping up right now", and a figure
/// from yesterday's run would only muddy that.
class LanPeerTraffic {
  /// Events this device read from the peer by asking for them.
  int pulled = 0;

  /// Events this device handed to the peer the moment they happened.
  int pushed = 0;

  /// Events the peer handed to this device the moment they happened.
  int received = 0;

  DateTime? lastPullAt;
  DateTime? lastPushAt;
  DateTime? lastReceivedAt;

  /// How long the last ask and the last hand-over took, there and back.
  Duration? lastPullTook;
  Duration? lastPushTook;

  /// How long the last change the peer made took to land here.
  Duration? lastDelay;

  String? lastError;
  DateTime? lastErrorAt;

  final List<int> _delaysMs = [];

  /// The average and the worst of the recent [LanTraffic.delayWindow] landings.
  Duration? get averageDelay => _delaysMs.isEmpty
      ? null
      : Duration(
          milliseconds:
              _delaysMs.reduce((a, b) => a + b) ~/ _delaysMs.length);

  Duration? get worstDelay => _delaysMs.isEmpty
      ? null
      : Duration(milliseconds: _delaysMs.reduce((a, b) => a > b ? a : b));

  void _delay(Duration d, int window) {
    lastDelay = d;
    _delaysMs.add(d.inMilliseconds);
    if (_delaysMs.length > window) _delaysMs.removeAt(0);
  }
}

/// Every peer's [LanPeerTraffic], fed by the fabric as it pulls and pushes and by
/// the server as it is handed events.
class LanTraffic {
  LanTraffic({
    Duration? Function(String deviceId)? clockOffsetOf,
    DateTime Function()? now,
    this.delayWindow = 50,
  })  : _clockOffsetOf = clockOffsetOf,
        _now = now ?? DateTime.now;

  final Duration? Function(String deviceId)? _clockOffsetOf;
  final DateTime Function() _now;

  /// How many recent landings the average and the worst delay are taken over.
  final int delayWindow;

  final Map<String, LanPeerTraffic> _peers = {};

  Map<String, LanPeerTraffic> get byPeer => Map.unmodifiable(_peers);

  LanPeerTraffic of(String deviceId) =>
      _peers.putIfAbsent(deviceId, LanPeerTraffic.new);

  void pulled(String deviceId, List<LanEvent> events, Duration took) {
    final t = of(deviceId)
      ..pulled += events.length
      ..lastPullAt = _now().toUtc()
      ..lastPullTook = took
      ..lastError = null;
    _landed(t, deviceId, events);
  }

  void pushed(String deviceId, int count, Duration took) {
    of(deviceId)
      ..pushed += count
      ..lastPushAt = _now().toUtc()
      ..lastPushTook = took;
  }

  void received(String deviceId, List<LanEvent> events) {
    final t = of(deviceId)
      ..received += events.length
      ..lastReceivedAt = _now().toUtc();
    _landed(t, deviceId, events);
  }

  void failed(String deviceId, String error) {
    of(deviceId)
      ..lastError = error
      ..lastErrorAt = _now().toUtc();
  }

  void reset() => _peers.clear();

  /// The delay is measured on the peer's own changes only, moved onto this
  /// device's clock by the offset its beacon reported. A change relayed from a
  /// third till says nothing about this link.
  void _landed(LanPeerTraffic t, String deviceId, List<LanEvent> events) {
    final now = _now().toUtc();
    final offset = _clockOffsetOf?.call(deviceId) ?? Duration.zero;
    for (final e in events) {
      if (e.originDeviceId != deviceId) continue;
      final d = now.difference(e.at.toUtc().subtract(offset));
      t._delay(d.isNegative ? Duration.zero : d, delayWindow);
    }
  }
}
