import 'package:flutter/material.dart';

import '../../core/i18n/l10n.dart';
import '../../core/widgets/feedback.dart';
import '../../domain/order.dart';
import 'report_export.dart';

/// What customers owe the shop: the sales that were put on an account instead of
/// settled at the counter.
///
/// A pure view over the orders the caller has already windowed. An on-account sale
/// is an ordinary sale with one tender under its own label, so this report is a
/// filter rather than a second ledger, and it works with the line down like every
/// other report here.
class ReceivablesReportScreen extends StatelessWidget {
  const ReceivablesReportScreen({
    super.key,
    required this.orders,
    required this.formatAmount,
  });

  final List<Order> orders;
  final String Function(double) formatAmount;

  /// The sale is on account when any of its tenders is.
  static bool isOnAccount(Order o) =>
      o.payments.any((p) => p.label == kOnAccountLabel);

  static double owedOn(Order o) => o.payments
      .where((p) => p.label == kOnAccountLabel)
      .fold(0.0, (s, p) => s + p.amount);

  List<Order> get _onAccount {
    final list = orders.where(isOnAccount).toList();
    list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return list;
  }

  /// Who owes what, largest first. Unnamed cannot happen (the till refuses an
  /// on-account sale without a customer), but an order that arrived from an older
  /// build is bucketed rather than dropped.
  List<MapEntry<String, double>> _byCustomer(List<Order> rows) {
    final owed = <String, double>{};
    for (final o in rows) {
      final who = (o.customerName ?? '').trim().isEmpty
          ? 'Unnamed'
          : o.customerName!.trim();
      owed[who] = (owed[who] ?? 0) + owedOn(o);
    }
    final list = owed.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    return list;
  }

  static String _at(DateTime d) {
    final l = d.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${l.year}-${two(l.month)}-${two(l.day)} ${two(l.hour)}:${two(l.minute)}';
  }

  Future<void> _csv(BuildContext context) => downloadReportCsv(
        context,
        name: 'report-receivables',
        header: const ['Date', 'Order', 'Customer', 'Cashier', 'Amount'],
        rows: [
          for (final o in _onAccount)
            [
              _at(o.createdAt),
              o.displayNo,
              o.customerName ?? '',
              o.cashierId,
              owedOn(o).toStringAsFixed(2),
            ],
        ],
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

  @override
  Widget build(BuildContext context) {
    final rows = _onAccount;
    final total = rows.fold(0.0, (s, o) => s + owedOn(o));
    return Scaffold(
      appBar: AppBar(
        title: Text(tr(context, 'On account')),
        actions: [reportCsvAction(context, onPressed: () => _csv(context))],
      ),
      body: rows.isEmpty
          ? Center(
              child: EmptyState(
                key: const Key('receivables-empty'),
                icon: Icons.account_balance_wallet_outlined,
                title: tr(context, 'Nothing on account'),
                message: tr(context, 'Every sale in this range was settled.'),
              ),
            )
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _card(tr(context, 'Owed by customer'), [
                    Column(
                      key: const Key('receivables-by-customer'),
                      children: [
                        for (final e in _byCustomer(rows))
                          ListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            title: Text(tr(context, e.key)),
                            trailing: Text(formatAmount(e.value),
                                style: const TextStyle(fontWeight: FontWeight.bold)),
                          ),
                        const Divider(),
                        ListTile(
                          key: const Key('receivables-total'),
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          title: Text(tr(context, 'Total outstanding')),
                          trailing: Text(formatAmount(total),
                              style: const TextStyle(fontWeight: FontWeight.bold)),
                        ),
                      ],
                    ),
                  ]),
                  _card(tr(context, 'Sales on account'), [
                    for (final o in rows)
                      ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: Text(o.customerName ?? tr(context, 'Unnamed')),
                        subtitle: Text('${o.displayNo} · ${_at(o.createdAt)} · '
                            '${o.cashierId}'),
                        trailing: Text(formatAmount(owedOn(o))),
                      ),
                  ]),
                ],
              ),
            ),
    );
  }
}
