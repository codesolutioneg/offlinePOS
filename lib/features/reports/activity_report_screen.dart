import 'package:flutter/material.dart';

import '../../core/audit/audit_log.dart';
import '../../core/i18n/l10n.dart';
import '../../core/widgets/feedback.dart';
import '../../domain/order.dart';

/// A parsed 'line.voided' audit row. The raw detail is
/// 'orderUuid|name xqty|reason'; only the item text and the reason are shown.
class _VoidedLine {
  _VoidedLine({required this.item, required this.reason, required this.actor, required this.at});
  final String item;
  final String reason;
  final String actor;
  final DateTime at;
}

/// A parsed 'order.cancelled' audit row, whose detail is just the order uuid.
class _CancelledOrder {
  _CancelledOrder({required this.orderUuid, required this.actor, required this.at});
  final String orderUuid;
  final String actor;
  final DateTime at;
}

/// A read-only report of every money-affecting action a manager should see at
/// a glance.
///
/// Refunds come from the order list (a refund is an [Order] with
/// [Order.isRefund] set); voided lines and cancelled orders never become an
/// order of their own, so they are read from the audit log instead. [orders]
/// is assumed to already be windowed by the caller; [from]/[to] are used only
/// to window the audit query, so both sources line up on the same range.
class ActivityReportScreen extends StatelessWidget {
  const ActivityReportScreen({
    super.key,
    required this.orders,
    required this.audit,
    required this.formatAmount,
    this.from,
    this.to,
  });

  final List<Order> orders;
  final AuditLog audit;
  final String Function(double) formatAmount;
  final DateTime? from;
  final DateTime? to;

  List<Order> get _refunds => orders.where((o) => o.isRefund).toList();

  double get _refundTotal => _refunds.fold(0.0, (s, o) => s + o.total.abs());

  List<_VoidedLine> get _voidedLines => audit
      .recent(event: 'line.voided', from: from, to: to)
      .map(_parseVoided)
      .whereType<_VoidedLine>()
      .toList();

  List<_CancelledOrder> get _cancelledOrders =>
      audit.recent(event: 'order.cancelled', from: from, to: to).map(_parseCancelled).toList();

  _VoidedLine? _parseVoided(Map<String, Object?> row) {
    final detail = row['detail'] as String?;
    if (detail == null) return null;
    final parts = detail.split('|');
    if (parts.length < 3) return null;
    return _VoidedLine(
      item: parts[1],
      // The reason is free text and may itself contain '|', so keep everything
      // after the second separator rather than only the first segment.
      reason: parts.sublist(2).join('|'),
      actor: (row['actor'] as String?) ?? '',
      at: DateTime.parse(row['at'] as String),
    );
  }

  _CancelledOrder _parseCancelled(Map<String, Object?> row) => _CancelledOrder(
        orderUuid: (row['detail'] as String?) ?? '',
        actor: (row['actor'] as String?) ?? '',
        at: DateTime.parse(row['at'] as String),
      );

  static String _shortRef(String uuid) =>
      uuid.length <= 6 ? uuid : uuid.replaceAll('-', '').substring(0, 6).toUpperCase();

  static String _time(DateTime at) {
    final local = at.toLocal();
    return '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
  }

  Widget _row(String k, String v, {bool bold = false}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(children: [
          Text(k),
          const Spacer(),
          Text(v, style: TextStyle(fontWeight: bold ? FontWeight.bold : FontWeight.normal)),
        ]),
      );

  Widget _sectionCard(String title, List<Widget> children) => Card(
        margin: const EdgeInsets.only(bottom: 12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            const Divider(),
            ...children,
          ]),
        ),
      );

  Widget _refundTile(BuildContext context, Order o) {
    final reason = o.note?.trim() ?? '';
    return ListTile(
      dense: true,
      title: Text(formatAmount(o.total.abs())),
      subtitle: Text(
          '${reason.isEmpty ? tr(context, 'No reason') : reason} · ${o.cashierId} · ${_time(o.createdAt)}'),
    );
  }

  Widget _voidedTile(BuildContext context, _VoidedLine v) => ListTile(
        dense: true,
        title: Text(v.item),
        subtitle: Text('${v.reason} · ${v.actor} · ${_time(v.at)}'),
      );

  Widget _cancelledTile(BuildContext context, _CancelledOrder c) => ListTile(
        dense: true,
        title: Text(_shortRef(c.orderUuid)),
        subtitle: Text('${c.actor} · ${_time(c.at)}'),
      );

  @override
  Widget build(BuildContext context) {
    final refunds = _refunds;
    final voided = _voidedLines;
    final cancelled = _cancelledOrders;

    return Scaffold(
      appBar: AppBar(title: Text(tr(context, 'Cancelled, voided & refunded'))),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _sectionCard(tr(context, 'Overview'), [
            _row(tr(context, 'Refunds'), '${refunds.length}'),
            _row(tr(context, 'Total refunded'), formatAmount(_refundTotal), bold: true),
          ]),
          _sectionCard(
            tr(context, 'Refunds'),
            refunds.isEmpty
                ? [
                    EmptyState(
                      icon: Icons.undo,
                      title: tr(context, 'No refunds'),
                    ),
                  ]
                : refunds.map((o) => _refundTile(context, o)).toList(),
          ),
          _sectionCard(
            tr(context, 'Voided lines'),
            voided.isEmpty
                ? [
                    EmptyState(
                      icon: Icons.remove_circle_outline,
                      title: tr(context, 'No voided lines'),
                    ),
                  ]
                : voided.map((v) => _voidedTile(context, v)).toList(),
          ),
          _sectionCard(
            tr(context, 'Cancelled orders'),
            cancelled.isEmpty
                ? [
                    EmptyState(
                      icon: Icons.cancel_outlined,
                      title: tr(context, 'No cancelled orders'),
                    ),
                  ]
                : cancelled.map((c) => _cancelledTile(context, c)).toList(),
          ),
        ]),
      ),
    );
  }
}
