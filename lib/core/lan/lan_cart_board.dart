import 'dart:convert';

import '../db/settings_store.dart';

/// One line as the customer sees it. Deliberately not an [OrderLine]: a display is
/// shown to whoever is standing at the counter, so it carries what is on the bill
/// and nothing else about the sale, the cashier or the customer.
class LanCartLine {
  const LanCartLine({
    required this.name,
    required this.quantity,
    required this.total,
  });

  final String name;
  final double quantity;
  final double total;

  Map<String, dynamic> toMap() =>
      {'name': name, 'qty': quantity, 'total': total};

  factory LanCartLine.fromMap(Map<String, dynamic> m) => LanCartLine(
        name: '${m['name']}',
        quantity: (m['qty'] as num?)?.toDouble() ?? 1,
        total: (m['total'] as num?)?.toDouble() ?? 0,
      );
}

/// What one till has on its counter right now.
///
/// A snapshot rather than a change: only the newest one has any use, which is what
/// lets the log keep exactly one per till instead of one per tap.
class LanCartSnapshot {
  const LanCartSnapshot({
    required this.deviceId,
    required this.lines,
    required this.total,
    required this.at,
  });

  final String deviceId;
  final List<LanCartLine> lines;
  final double total;
  final DateTime at;

  /// Nothing on the counter: the display goes back to its idle panel rather than
  /// leaving the last customer's shopping up for the next one to read.
  bool get isEmpty => lines.isEmpty;

  Map<String, dynamic> toMap() => {
        'device': deviceId,
        'lines': [for (final l in lines) l.toMap()],
        'total': total,
        'at': at.toIso8601String(),
      };

  /// Throws on anything that is not a cart, so the applier refuses it rather than
  /// putting half a bill in front of a customer.
  factory LanCartSnapshot.fromMap(Map<String, dynamic> m) => LanCartSnapshot(
        deviceId: m['device'] as String,
        lines: [
          for (final l in (m['lines'] as List? ?? const []))
            LanCartLine.fromMap((l as Map).cast<String, dynamic>()),
        ],
        total: (m['total'] as num?)?.toDouble() ?? 0,
        at: DateTime.parse(m['at'] as String).toUtc(),
      );
}

/// What each till has on its counter, as the customer-facing display reads it.
///
/// In the settings bag rather than a table of its own: it is one short row per till,
/// always replaced and never accumulated, and a shop has two or three of them. It is
/// durable so a display restarted mid-service shows the counter it was showing
/// instead of an idle screen until the next tap.
class LanCartBoard {
  LanCartBoard(this._settings);

  static const _cartsKey = 'lan_display_carts';
  static const _publishKey = 'lan_display_cart';
  static const _sourceKey = 'lan_display_source';

  final SettingsStore _settings;

  /// Whether this till puts its counter on the shop network for a display to show.
  ///
  /// Off by default and deliberately its own switch: it is the one thing in the
  /// fabric that writes while an order is being rung, so a shop without a display
  /// pays nothing for it. Even on, the write is a local insert that replaces the
  /// previous snapshot, and the hand-over to the peers happens after the tap.
  bool get publishing => _settings.getBool(_publishKey);
  set publishing(bool v) => _settings.setBool(_publishKey, v);

  /// The till this display is pointed at, or null for "whichever is busiest", which
  /// is the right answer for the ordinary one-counter shop.
  String? get source => _settings.getString(_sourceKey);
  set source(String? v) => _settings.setString(_sourceKey, v);

  Map<String, LanCartSnapshot> carts() {
    final raw = _settings.getString(_cartsKey);
    if (raw == null) return const {};
    try {
      final decoded = (jsonDecode(raw) as Map).cast<String, dynamic>();
      return {
        for (final e in decoded.entries)
          e.key: LanCartSnapshot.fromMap((e.value as Map).cast<String, dynamic>()),
      };
    } catch (_) {
      return const {};
    }
  }

  /// Keep what one till last showed. One row per device: the previous snapshot is
  /// replaced, because a cart from a minute ago is of no use to anybody.
  void remember(LanCartSnapshot cart) {
    final all = {for (final e in carts().entries) e.key: e.value.toMap()};
    all[cart.deviceId] = cart.toMap();
    _settings.setString(_cartsKey, jsonEncode(all));
  }

  /// What the display should be showing: the till it was pointed at, or the one
  /// that moved most recently. Null when no till has said anything.
  LanCartSnapshot? showing() {
    final all = carts();
    final pinned = source;
    if (pinned != null) return all[pinned];
    LanCartSnapshot? latest;
    for (final c in all.values) {
      if (latest == null || c.at.isAfter(latest.at)) latest = c;
    }
    return latest;
  }
}
