import 'order.dart';
import 'shift.dart';

/// How far money figures may sit apart and still count as the same session.
const sessionCloseMoneyEpsilon = 0.02;

/// Whether the End of Day card and the set about to go to Odoo describe the
/// same night. A free till that only held its own outbox used to pass the Z
/// figures (shop-wide) while sending a short SO — this check blocks that.
class SessionCloseMatch {
  const SessionCloseMatch({
    required this.ok,
    this.screenCount = 0,
    this.sendCount = 0,
    this.screenTotal = 0,
    this.sendTotal = 0,
    this.tenderGaps = const [],
  });

  final bool ok;
  final int screenCount;
  final int sendCount;
  final double screenTotal;
  final double sendTotal;

  /// Tender labels where the screen and the send set disagree.
  final List<String> tenderGaps;

  /// Short English lines for a dialog (UI translates or shows as-is).
  List<String> get lines {
    final out = <String>[];
    if (screenCount != sendCount) {
      out.add('Orders on screen: $screenCount, to send: $sendCount');
    }
    if ((screenTotal - sendTotal).abs() >= sessionCloseMoneyEpsilon) {
      out.add(
        'Total on screen: ${screenTotal.toStringAsFixed(2)}, '
        'to send: ${sendTotal.toStringAsFixed(2)}',
      );
    }
    for (final g in tenderGaps) {
      out.add(g);
    }
    return out;
  }
}

/// Build the tender totals the send set would book, same labels the Z card uses.
Map<String, double> paymentMixOf(Iterable<Order> orders) {
  final byPay = <String, double>{};
  for (final o in orders) {
    if (o.payments.isEmpty) {
      if (o.total.abs() < sessionCloseMoneyEpsilon) continue;
      byPay['Cash'] = (byPay['Cash'] ?? 0) + o.total;
      continue;
    }
    for (final p in o.payments) {
      if (p.amount.abs() < sessionCloseMoneyEpsilon) continue;
      final label =
          (p.label ?? '').trim().isEmpty ? 'Cash' : p.label!.trim();
      byPay[label] = (byPay[label] ?? 0) + p.amount;
    }
  }
  return byPay;
}

/// Compare [screen] (shift summary on the End of Day card) to [sendOrders]
/// (what flush will enqueue). Counts and totals must agree; each tender on
/// either side must match within [sessionCloseMoneyEpsilon].
SessionCloseMatch matchSessionClose({
  required ShiftSummary screen,
  required List<Order> sendOrders,
}) {
  final sendTotal = sendOrders.fold<double>(0, (s, o) => s + o.total);
  final sendMix = paymentMixOf(sendOrders);
  final screenMix = <String, double>{
    for (final t in screen.tenders) t.label: t.amount,
  };
  final gaps = <String>[];
  final labels = {...screenMix.keys, ...sendMix.keys};
  for (final label in labels) {
    final a = screenMix[label] ?? 0;
    final b = sendMix[label] ?? 0;
    if ((a - b).abs() >= sessionCloseMoneyEpsilon) {
      gaps.add(
        '$label on screen: ${a.toStringAsFixed(2)}, '
        'to send: ${b.toStringAsFixed(2)}',
      );
    }
  }
  final ok = screen.salesCount == sendOrders.length &&
      (screen.salesTotal - sendTotal).abs() < sessionCloseMoneyEpsilon &&
      gaps.isEmpty;
  return SessionCloseMatch(
    ok: ok,
    screenCount: screen.salesCount,
    sendCount: sendOrders.length,
    screenTotal: screen.salesTotal,
    sendTotal: sendTotal,
    tenderGaps: gaps,
  );
}
