/// What a till reports about itself.
///
/// One small payload that answers the questions support actually asks: which till
/// is behind, by how much, and since when. Without it the only way to know a shop
/// has been offline for six days is for someone to notice the reports are wrong.
class DeviceStatus {
  const DeviceStatus({
    required this.deviceId,
    required this.appVersion,
    required this.at,
    required this.pending,
    required this.dead,
    required this.unsyncedAudit,
    this.oldestPendingAge,
    this.catalogueRefreshedAt,
    this.lastError,
    this.cashierId,
  });

  final String deviceId;
  final String appVersion;
  final DateTime at;

  /// Sales waiting to reach the server.
  final int pending;

  /// Sales the server refused. Every one of these is money missing from the books,
  /// so it is reported separately and never folded into [pending].
  final int dead;

  final int unsyncedAudit;

  /// How long the books have been out of date, which is the number that actually
  /// tells you how bad an outage is.
  final Duration? oldestPendingAge;

  final DateTime? catalogueRefreshedAt;
  final String? lastError;
  final String? cashierId;

  /// Worth a human looking at it.
  bool get needsAttention =>
      dead > 0 ||
      (oldestPendingAge != null && oldestPendingAge! > const Duration(hours: 24));

  Map<String, dynamic> toMap() => {
        'device_id': deviceId,
        'app_version': appVersion,
        'at': at.toIso8601String(),
        'pending': pending,
        'dead': dead,
        'unsynced_audit': unsyncedAudit,
        'oldest_pending_seconds': oldestPendingAge?.inSeconds,
        'catalogue_refreshed_at': catalogueRefreshedAt?.toIso8601String(),
        'last_error': lastError,
        'cashier_id': cashierId,
        'needs_attention': needsAttention,
      };
}
