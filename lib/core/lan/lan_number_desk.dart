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
}

/// One order number a secondary reserved from the primary ahead of the sale that
/// will carry it.
///
/// Numbering happens inside Pay, which never waits on the network, so the ask is
/// made before it is needed: when an order starts being rung, and again as soon as
/// a number is used. With nothing reserved the till numbers locally, as it did
/// before, so a primary that is down never stops a sale.
class LanNumberSupply {
  LanNumberSupply({
    required Future<String?> Function() ask,
    this.freshFor = const Duration(seconds: 60),
    DateTime Function()? now,
  })  : _ask = ask,
        _now = now ?? DateTime.now;

  final Future<String?> Function() _ask;
  final DateTime Function() _now;

  /// How long a reserved number is kept before a new order swaps it for a newer
  /// one. A number held over a quiet spell would otherwise print well below the
  /// ones the primary has handed out since; a skipped number is the smaller harm.
  final Duration freshFor;

  String? _held;
  DateTime? _heldAt;
  Future<void>? _asking;

  /// Reserve a number unless a fresh one is already held or being asked for.
  void prepare() {
    if (_asking != null) return;
    final at = _heldAt;
    if (_held != null && at != null && _now().difference(at) < freshFor) return;
    _asking = _fetch();
  }

  /// Settles once the ask in flight, if any, has landed.
  Future<void> get settled => _asking ?? Future<void>.value();

  Future<void> _fetch() async {
    try {
      final n = await _ask();
      if (n != null && int.tryParse(n) != null) {
        _held = n;
        _heldAt = _now();
      }
    } catch (_) {
      // The caller numbers locally; nothing to keep.
    } finally {
      _asking = null;
    }
  }

  /// The reserved number, or null to number locally. The caller asks for the
  /// next one with [prepare].
  String? take() {
    final n = _held;
    _held = null;
    _heldAt = null;
    return n;
  }
}
