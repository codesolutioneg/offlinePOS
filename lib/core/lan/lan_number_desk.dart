import 'dart:async';

import '../db/order_store.dart';
import '../db/settings_store.dart';

/// The primary till's order-number counter, answered to the secondaries.
///
/// Each till climbs past the highest number it has seen, which is a floor and not
/// a lock: two tills paying inside one replication window both land on it. The
/// primary hands secondaries their numbers from the very counter it numbers its
/// own sales from, so while it can be reached no two checks share a number.
class LanNumberDesk {
  LanNumberDesk({
    required this.deviceId,
    required SettingsStore settings,
    required OrderStore orders,
  })  : _settings = settings,
        _orders = orders;

  final String deviceId;
  final SettingsStore _settings;
  final OrderStore _orders;

  String issue() =>
      _settings.nextOrderNumber(deviceId, atLeast: _orders.orderNumberFloor());

  /// [count] numbers in a row off the same counter, for a secondary's reserve.
  List<String> issueMany(int count) {
    final floor = _orders.orderNumberFloor();
    return [
      for (var i = 0; i < count; i++)
        _settings.nextOrderNumber(deviceId, atLeast: floor),
    ];
  }
}

/// Order numbers a secondary reserved from the primary ahead of the sales that
/// will carry them.
///
/// Numbering happens inside Pay, which never waits on the network, so the ask is
/// made before it is needed: when an order starts being rung, and again whenever
/// the reserve runs low. A reserve rather than one number, because a split makes
/// several checks in one tap and two cashiers can pay a second apart; with only
/// one number held, every check after the first was numbered locally and could
/// repeat the primary's. With nothing reserved the till numbers locally, so a
/// primary that is down never stops a sale.
class LanNumberSupply {
  LanNumberSupply({
    required Future<List<String>> Function(int count) ask,
    this.batch = 8,
    this.freshFor = const Duration(seconds: 60),
    DateTime Function()? now,
  })  : _ask = ask,
        _now = now ?? DateTime.now;

  final Future<List<String>> Function(int count) _ask;
  final DateTime Function() _now;

  /// How many numbers the reserve is topped up to. Asked again once half are used.
  final int batch;

  /// How long a reserved number is kept before it is dropped for a newer one. A
  /// number held over a quiet spell would otherwise print well below the ones the
  /// primary has handed out since; a skipped number is the smaller harm.
  final Duration freshFor;

  final List<({String number, DateTime at})> _held = [];
  Future<void>? _asking;

  /// How many fresh numbers are reserved right now.
  int get held {
    _dropStale();
    return _held.length;
  }

  /// Top the reserve up unless it is still over half full or an ask is in flight.
  void prepare() {
    if (_asking != null || held > batch ~/ 2) return;
    _asking = _fetch(batch - _held.length);
  }

  /// Settles once the ask in flight, if any, has landed.
  Future<void> get settled => _asking ?? Future<void>.value();

  Future<void> _fetch(int count) async {
    try {
      final at = _now();
      for (final n in await _ask(count)) {
        if (int.tryParse(n) != null) _held.add((number: n, at: at));
      }
    } catch (_) {
      // The caller numbers locally; nothing to keep.
    } finally {
      _asking = null;
    }
  }

  void _dropStale() {
    final now = _now();
    _held.removeWhere((h) => now.difference(h.at) >= freshFor);
  }

  /// The oldest reserved number, or null to number locally. The caller tops the
  /// reserve up with [prepare].
  String? take() {
    if (held == 0) return null;
    return _held.removeAt(0).number;
  }
}
