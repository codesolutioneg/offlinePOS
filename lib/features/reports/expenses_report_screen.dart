import 'package:flutter/material.dart';

import '../../core/db/shift_store.dart';
import '../../core/i18n/l10n.dart';
import '../../core/widgets/feedback.dart';
import 'report_export.dart';

/// One bucket of paid-outs: how many and how much.
class _Bucket {
  _Bucket(this.label);
  final String label;
  int count = 0;
  double amount = 0;
}

/// What the shop spent out of the drawer over a period, across every shift.
///
/// Paid-outs are recorded inside a shift, so until now they died with the drawer
/// they were taken from. This is a pure view over the movements the caller has
/// already windowed: it never reads storage or the network itself.
class ExpensesReportScreen extends StatelessWidget {
  const ExpensesReportScreen({
    super.key,
    required this.movements,
    required this.formatAmount,
  });

  final List<ShiftMovement> movements;
  final String Function(double) formatAmount;

  /// Money out of the drawer. Paid-ins are drawer top-ups, not spending, so they
  /// are summarised separately and never mixed into an expense total.
  List<ShiftMovement> get _paidOut =>
      movements.where((m) => m.movement.type == 'out').toList();

  List<ShiftMovement> get _paidIn =>
      movements.where((m) => m.movement.type != 'out').toList();

  double get _outTotal =>
      _paidOut.fold(0.0, (s, m) => s + m.movement.amount);

  double get _inTotal => _paidIn.fold(0.0, (s, m) => s + m.movement.amount);

  /// Paid-outs grouped by their category, largest first. A movement saved without
  /// one is bucketed as uncategorised rather than dropped: unlabelled spending is
  /// exactly what a manager wants to see.
  List<_Bucket> _byCategory() => _group(
      _paidOut, (m) => (m.movement.category ?? '').trim(), 'Uncategorised');

  List<_Bucket> _byCashier() =>
      _group(_paidOut, (m) => m.cashierId.trim(), 'Unknown');

  List<_Bucket> _group(List<ShiftMovement> rows,
      String Function(ShiftMovement) key, String fallback) {
    final buckets = <String, _Bucket>{};
    for (final m in rows) {
      final k = key(m).isEmpty ? fallback : key(m);
      final b = buckets.putIfAbsent(k, () => _Bucket(k));
      b.count += 1;
      b.amount += m.movement.amount;
    }
    return buckets.values.toList()
      ..sort((a, b) => b.amount.compareTo(a.amount));
  }

  static String _at(DateTime d) {
    final l = d.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${l.year}-${two(l.month)}-${two(l.day)} ${two(l.hour)}:${two(l.minute)}';
  }

  Future<void> _csv(BuildContext context) => downloadReportCsv(
        context,
        name: 'report-expenses',
        header: const ['Date', 'Category', 'Reason', 'Cashier', 'Shift', 'Amount'],
        rows: [
          for (final m in _paidOut)
            [
              _at(m.movement.at),
              m.movement.category ?? '',
              m.movement.reason,
              m.cashierId,
              m.shiftId,
              m.movement.amount.toStringAsFixed(2),
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

  Widget _bucketRows(BuildContext context, List<_Bucket> buckets, String key) =>
      Column(
        key: Key(key),
        children: [
          for (final b in buckets)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text(tr(context, b.label)),
              subtitle: Text(
                  '${b.count} ${tr(context, b.count == 1 ? 'payout' : 'payouts')}'),
              trailing: Text(formatAmount(b.amount)),
            ),
        ],
      );

  @override
  Widget build(BuildContext context) {
    final paidOut = _paidOut;
    return Scaffold(
      appBar: AppBar(
        title: Text(tr(context, 'Expenses')),
        actions: [reportCsvAction(context, onPressed: () => _csv(context))],
      ),
      body: paidOut.isEmpty
          ? Center(
              child: EmptyState(
                key: const Key('expenses-empty-state'),
                icon: Icons.money_off,
                title: tr(context, 'No expenses'),
                message: tr(context, 'Nothing was paid out in this range.'),
              ),
            )
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _card(tr(context, 'Overview'), [
                    _row(tr(context, 'Payouts'), '${paidOut.length}'),
                    _row(tr(context, 'Total paid out'), formatAmount(_outTotal),
                        bold: true),
                    _row(tr(context, 'Total paid in'), formatAmount(_inTotal)),
                  ]),
                  _card(tr(context, 'By category'),
                      [_bucketRows(context, _byCategory(), 'expenses-by-category')]),
                  _card(tr(context, 'By cashier'),
                      [_bucketRows(context, _byCashier(), 'expenses-by-cashier')]),
                  _card(tr(context, 'Payouts'), [
                    for (final m in paidOut)
                      ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: Text(m.movement.reason.trim().isEmpty
                            ? tr(context, 'No reason')
                            : m.movement.reason),
                        subtitle: Text(
                            '${tr(context, m.movement.category ?? 'Uncategorised')} · ${m.cashierId} · ${_at(m.movement.at)}'),
                        trailing: Text(formatAmount(m.movement.amount)),
                      ),
                  ]),
                ],
              ),
            ),
    );
  }
}
