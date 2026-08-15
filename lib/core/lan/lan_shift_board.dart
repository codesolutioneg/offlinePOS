import 'dart:convert';

import '../db/settings_store.dart';

/// What a till does about a day closed somewhere else in the shop.
///
/// Off is the default and the honest one: a shop where each till closes its own
/// drawer whenever it likes was working before this existed and keeps working
/// exactly as it did.
enum LanDayClosePolicy {
  /// Nothing is said. Every till closes its own day, as before.
  off,

  /// The other tills are told, and can still sell. A cashier who missed the shout
  /// across the floor sees it on the plan.
  warn,

  /// The other tills are told and stop STARTING work: no new order until this till
  /// has closed too. Tabs already open can still be settled, always: money that has
  /// been ordered has to be takeable whatever the policy says.
  block;

  static LanDayClosePolicy fromKey(String? key) {
    for (final p in LanDayClosePolicy.values) {
      if (p.name == key) return p;
    }
    return LanDayClosePolicy.off;
  }
}

/// One till saying its day is over.
class LanShiftNotice {
  const LanShiftNotice({
    required this.deviceId,
    required this.deviceName,
    required this.businessDate,
    required this.at,
    this.cashierId,
  });

  final String deviceId;

  /// What that till calls itself, so the message names a device a human can walk
  /// to rather than a uuid.
  final String deviceName;

  /// The trading day that was closed, which is what makes the notice expire on its
  /// own: tomorrow it is about yesterday and nobody is nudged.
  final String businessDate;
  final DateTime at;
  final String? cashierId;

  Map<String, dynamic> toMap() => {
        'device': deviceId,
        'name': deviceName,
        'state': 'closed',
        'business_date': businessDate,
        'at': at.toIso8601String(),
        'cashier': cashierId,
      };

  /// Throws on anything that is not a close notice, so the applier refuses it
  /// rather than storing half a fact.
  factory LanShiftNotice.fromMap(Map<String, dynamic> m) => LanShiftNotice(
        deviceId: m['device'] as String,
        deviceName: (m['name'] as String?) ?? m['device'] as String,
        businessDate: m['business_date'] as String,
        at: DateTime.parse(m['at'] as String).toUtc(),
        cashierId: m['cashier'] as String?,
      );
}

/// What the other tills have said about the trading day, and what this one does
/// about it.
///
/// Kept in the settings bag rather than a table of its own: it is one short row per
/// device, it is replaced rather than accumulated, and a shop with two tills has two
/// of them. Durable, so a till restarted overnight still knows the day was closed
/// while it was off.
///
/// Nothing here is ever on a selling path. It is read when the floor is drawn and
/// written when an event arrives on the fabric's timer.
class LanShiftBoard {
  LanShiftBoard(this._settings);

  static const _noticesKey = 'lan_shift_notices';
  static const _policyKey = 'lan_day_close_policy';

  final SettingsStore _settings;

  LanDayClosePolicy get policy =>
      LanDayClosePolicy.fromKey(_settings.getString(_policyKey));

  set policy(LanDayClosePolicy p) => _settings.setString(
      _policyKey, p == LanDayClosePolicy.off ? null : p.name);

  /// The last thing each till said, by device id. Unreadable data reads as nothing,
  /// so a corrupt value is a shop with no nudge rather than a floor that crashes.
  Map<String, LanShiftNotice> notices() {
    final raw = _settings.getString(_noticesKey);
    if (raw == null) return const {};
    try {
      final decoded = (jsonDecode(raw) as Map).cast<String, dynamic>();
      return {
        for (final e in decoded.entries)
          e.key: LanShiftNotice.fromMap((e.value as Map).cast<String, dynamic>()),
      };
    } catch (_) {
      return const {};
    }
  }

  /// Record what one till said. One row per device: a till that closes a second
  /// time replaces its own notice rather than stacking one up.
  void remember(LanShiftNotice notice) {
    final all = {for (final e in notices().entries) e.key: e.value.toMap()};
    all[notice.deviceId] = notice.toMap();
    _settings.setString(_noticesKey, jsonEncode(all));
  }

  /// The first till that has closed [businessDate], or null when none has.
  ///
  /// Scoped to the day on purpose: yesterday's close is not today's business, so
  /// the nudge lets itself go at the cutover instead of needing to be cleared.
  LanShiftNotice? closedOn(String businessDate) {
    for (final n in notices().values) {
      if (n.businessDate == businessDate) return n;
    }
    return null;
  }
}
