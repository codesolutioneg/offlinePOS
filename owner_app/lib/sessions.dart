/// One till shift / session from cloud `shift` records.
class OwnerSessionInfo {
  const OwnerSessionInfo({
    required this.key,
    required this.deviceId,
    required this.branchId,
    required this.cashierId,
    required this.openedAt,
    this.closedAt,
  });

  final String key;
  final String deviceId;
  final String branchId;
  final String cashierId;
  final DateTime openedAt;
  final DateTime? closedAt;

  bool get isOpen => closedAt == null;

  /// Local midnight of the day this session opened.
  DateTime get openDay {
    final t = openedAt.toLocal();
    return DateTime(t.year, t.month, t.day);
  }

  String get statusEn => isOpen ? 'Open' : 'Closed';
  String get statusAr => isOpen ? 'مفتوحة' : 'مقفولة';

  factory OwnerSessionInfo.fromRecord({
    required String key,
    required String branchId,
    required Map<String, Object?> payload,
  }) {
    final cut = key.indexOf(':');
    final deviceId = cut > 0 ? key.substring(0, cut) : '${payload['device_id'] ?? ''}';
    final opened = DateTime.tryParse('${payload['opened_at'] ?? ''}')?.toUtc() ??
        DateTime.now().toUtc();
    final closedRaw = payload['closed_at'];
    final closed = closedRaw == null || '$closedRaw'.isEmpty
        ? null
        : DateTime.tryParse('$closedRaw')?.toUtc();
    return OwnerSessionInfo(
      key: key,
      deviceId: deviceId,
      branchId: branchId,
      cashierId: '${payload['cashier_id'] ?? ''}',
      openedAt: opened,
      closedAt: closed,
    );
  }
}

List<OwnerSessionInfo> sessionsFromRecords(
  Iterable<({String key, String branchId, Map<String, Object?> payload})> rows,
) {
  final byKey = <String, OwnerSessionInfo>{};
  for (final r in rows) {
    if (r.key.isEmpty) continue;
    byKey[r.key] = OwnerSessionInfo.fromRecord(
      key: r.key,
      branchId: r.branchId,
      payload: r.payload,
    );
  }
  final list = byKey.values.toList()
    ..sort((a, b) => b.openedAt.compareTo(a.openedAt));
  return list;
}

/// Sessions whose open day is in `[from, to)` plus any still open.
List<OwnerSessionInfo> sessionsInWindow(
  List<OwnerSessionInfo> all, {
  required DateTime from,
  required DateTime to,
}) {
  return [
    for (final s in all)
      if (s.isOpen || (!s.openDay.isBefore(from) && s.openDay.isBefore(to))) s,
  ];
}
