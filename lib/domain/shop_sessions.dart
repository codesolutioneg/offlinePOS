import 'shift.dart';

/// Collapse LAN "quiet open" clones of the same shop open into one session row.
///
/// When till A opens, peers open a local drawer with the same cashier — often a
/// few minutes later, still while A's session is open. Uploaded to the reports
/// site those look like three Emad sessions (08:35, 08:35, 08:47). Prefer the
/// drawer with the higher opening float (the till that really counted cash in);
/// otherwise keep the earliest / longest-lived row.
List<Shift> collapseShopShiftClones(List<Shift> shifts,
    {Duration window = const Duration(minutes: 3)}) {
  if (shifts.length <= 1) return List.of(shifts);
  final sorted = [...shifts]..sort((a, b) => a.openedAt.compareTo(b.openedAt));
  final kept = <Shift>[];
  for (final s in sorted) {
    final i = kept.indexWhere((k) => _sameShopOpen(k, s, window));
    if (i < 0) {
      kept.add(s);
      continue;
    }
    kept[i] = _preferShopOpen(kept[i], s);
  }
  kept.sort((a, b) {
    final ac = a.closedAt ?? a.openedAt;
    final bc = b.closedAt ?? b.openedAt;
    return bc.compareTo(ac);
  });
  return kept;
}

bool _sameShopOpen(Shift a, Shift b, Duration window) {
  if (a.cashierId != b.cashierId) return false;
  if (a.openedAt.difference(b.openedAt).abs() <= window) return true;
  // Peer opened while the other drawer was still the shop's open session.
  final earlier = a.openedAt.isBefore(b.openedAt) ? a : b;
  final later = a.openedAt.isBefore(b.openedAt) ? b : a;
  final end = earlier.closedAt;
  if (end == null) return true;
  // Inclusive: a peer that opens at the exact close second still collapses.
  return !later.openedAt.isAfter(end);
}

Shift _preferShopOpen(Shift a, Shift b) {
  if (b.openingFloat > a.openingFloat) return b;
  if (a.openingFloat > b.openingFloat) return a;
  // The till that counted the drawer at close is the real shop session.
  final aCounted = a.closingCounted ?? 0;
  final bCounted = b.closingCounted ?? 0;
  if (bCounted > aCounted) return b;
  if (aCounted > bCounted) return a;
  final aEnd = a.closedAt;
  final bEnd = b.closedAt;
  if (aEnd == null && bEnd != null) return a;
  if (bEnd == null && aEnd != null) return b;
  if (aEnd != null && bEnd != null) {
    if (bEnd.isAfter(aEnd)) return b;
    if (aEnd.isAfter(bEnd)) return a;
  }
  return a.openedAt.isBefore(b.openedAt) ? a : b;
}
