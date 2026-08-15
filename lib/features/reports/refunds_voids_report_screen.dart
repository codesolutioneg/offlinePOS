import 'package:flutter/material.dart';

import '../../core/audit/audit_log.dart';
import '../../core/i18n/l10n.dart';
import '../../core/widgets/feedback.dart';
import '../../domain/order.dart';
import 'report_export.dart';

/// One money-back or money-lost event, whatever its source.
///
/// Refunds are reversal orders and carry a total; voided lines and cancelled
/// orders only exist in the audit trail, which records what and why but never an
/// amount, so their [amount] is null and they are counted rather than totalled.
class _Event {
  _Event({
    required this.kind,
    required this.what,
    required this.reason,
    required this.actor,
    required this.at,
    this.amount,
  });

  final String kind;
  final String what;
  final String reason;
  final String actor;
  final DateTime at;
  final double? amount;
}

class _Bucket {
  _Bucket(this.label);
  final String label;
  int count = 0;
  double amount = 0;
}

/// Refunds, voids and cancels in one place, totalled by reason and by cashier.
///
/// The activity report lists these as raw events; a manager reconciling a day
/// needs the money and the pattern: which reason costs the most, and who is
/// giving it away. [orders] is already windowed by the caller; [from]/[to] window
/// the audit query so both sources cover the same period.
class RefundsVoidsReportScreen extends StatelessWidget {
  const RefundsVoidsReportScreen({
    super.key,
    required this.orders,
    required this.audit,
    required this.formatAmount,
    this.from,
    this.to,
    this.actor,
  });

  final List<Order> orders;
  final AuditLog audit;
  final String Function(double) formatAmount;
  final DateTime? from;
  final DateTime? to;

  /// Narrows the audited voids/cancels to one cashier, matching the cashier
  /// filter already applied to [orders].
  final String? actor;

  static const _refundKind = 'Refund';
  static const _voidKind = 'Voided line';
  static const _cancelKind = 'Cancelled order';

  List<_Event> get _refunds => [
        for (final o in orders.where((o) => o.isRefund))
          _Event(
            kind: _refundKind,
            what: _shortRef(o.uuid),
            reason: _orEmpty(o.note),
            actor: o.cashierId,
            at: o.createdAt,
            // A reversal is stored negative; a report of money given back reads
            // in positive money.
            amount: o.total.abs(),
          ),
      ];

  List<_Event> get _voids => [
        for (final r in audit.recent(
            event: 'line.voided', actor: actor, from: from, to: to))
          if (_split(r['detail']) case final parts when parts.length >= 3)
            _Event(
              kind: _voidKind,
              what: parts[1],
              // Free text can contain the separator itself, so everything after
              // the second one is the reason.
              reason: _orEmpty(parts.sublist(2).join('|')),
              actor: (r['actor'] as String?) ?? '',
              at: DateTime.parse(r['at'] as String),
            ),
      ];

  List<_Event> get _cancels => [
        for (final r in audit.recent(
            event: 'order.cancelled', actor: actor, from: from, to: to))
          if (_split(r['detail']) case final parts when parts.isNotEmpty)
            _Event(
              kind: _cancelKind,
              what: _shortRef(parts.first),
              reason: _orEmpty(parts.skip(1).join('|')),
              actor: (r['actor'] as String?) ?? '',
              at: DateTime.parse(r['at'] as String),
            ),
      ];

  List<_Event> get _all => [..._refunds, ..._voids, ..._cancels]
    ..sort((a, b) => b.at.compareTo(a.at));

  static List<String> _split(Object? detail) =>
      (detail as String?)?.split('|') ?? const [];

  static String _orEmpty(String? s) {
    final t = s?.trim() ?? '';
    return t.isEmpty ? 'No reason' : t;
  }

  static String _shortRef(String uuid) => uuid.length <= 6
      ? uuid
      : uuid.replaceAll('-', '').substring(0, 6).toUpperCase();

  static String _at(DateTime d) {
    final l = d.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${l.year}-${two(l.month)}-${two(l.day)} ${two(l.hour)}:${two(l.minute)}';
  }

  List<_Bucket> _group(List<_Event> events, String Function(_Event) key) {
    final buckets = <String, _Bucket>{};
    for (final e in events) {
      final b = buckets.putIfAbsent(key(e), () => _Bucket(key(e)));
      b.count += 1;
      b.amount += e.amount ?? 0;
    }
    // Money first, then how often: a costly reason outranks a frequent free one.
    return buckets.values.toList()
      ..sort((a, b) {
        final byMoney = b.amount.compareTo(a.amount);
        return byMoney != 0 ? byMoney : b.count.compareTo(a.count);
      });
  }

  Future<void> _csv(BuildContext context) => downloadReportCsv(
        context,
        name: 'report-refunds-voids',
        header: const ['Date', 'Kind', 'What', 'Reason', 'Cashier', 'Amount'],
        rows: [
          for (final e in _all)
            [
              _at(e.at),
              e.kind,
              e.what,
              e.reason,
              e.actor,
              e.amount?.toStringAsFixed(2) ?? '',
            ],
        ],
      );

  Widget _row(String k, String v, {bool bold = false}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(children: [
          Expanded(child: Text(k)),
          Text(v,
              style: TextStyle(
                  fontWeight: bold ? FontWeight.bold : FontWeight.normal)),
        ]),
      );

  Widget _card(String title, List<Widget> children) => Card(
        margin: const EdgeInsets.only(bottom: 12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title,
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            const Divider(),
            ...children,
          ]),
        ),
      );

  Widget _buckets(BuildContext context, List<_Bucket> buckets, String key) =>
      Column(
        key: Key(key),
        children: [
          for (final b in buckets)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text(tr(context, b.label)),
              subtitle: Text('${b.count}'),
              trailing: Text(formatAmount(b.amount)),
            ),
        ],
      );

  @override
  Widget build(BuildContext context) {
    final refunds = _refunds;
    final voids = _voids;
    final cancels = _cancels;
    final all = _all;
    final refunded = refunds.fold(0.0, (s, e) => s + (e.amount ?? 0));

    return Scaffold(
      appBar: AppBar(
        title: Text(tr(context, 'Refunds & voids')),
        actions: [reportCsvAction(context, onPressed: () => _csv(context))],
      ),
      body: all.isEmpty
          ? Center(
              child: EmptyState(
                key: const Key('refunds-voids-empty-state'),
                icon: Icons.undo,
                title: tr(context, 'Nothing given back'),
                message: tr(context,
                    'No refunds, voids or cancellations in this range.'),
              ),
            )
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _card(tr(context, 'Overview'), [
                    _row(tr(context, 'Refunds'), '${refunds.length}'),
                    _row(tr(context, 'Total refunded'), formatAmount(refunded),
                        bold: true),
                    _row(tr(context, 'Voided lines'), '${voids.length}'),
                    _row(tr(context, 'Cancelled orders'), '${cancels.length}'),
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        tr(context,
                            'Voids and cancellations are counted; no amount is recorded when they happen.'),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  ]),
                  _card(tr(context, 'By reason'),
                      [_buckets(context, _group(all, (e) => e.reason), 'rv-by-reason')]),
                  _card(tr(context, 'By cashier'),
                      [_buckets(context, _group(all, (e) => e.actor), 'rv-by-cashier')]),
                  _card(tr(context, 'Events'), [
                    for (final e in all)
                      ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: Text('${tr(context, e.kind)} · ${e.what}'),
                        subtitle: Text(
                            '${tr(context, e.reason)} · ${e.actor} · ${_at(e.at)}'),
                        trailing: Text(
                            e.amount == null ? '' : formatAmount(e.amount!)),
                      ),
                  ]),
                ],
              ),
            ),
    );
  }
}
