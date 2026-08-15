import 'package:flutter/material.dart';

import '../../core/i18n/l10n.dart';
import '../../core/theme/app_colors.dart';
import '../../domain/order.dart';

/// The day so far, at the top of the reports hub.
///
/// A manager walking past the till wants four numbers, not a report: how many
/// orders, how much, how much of it is cash, and how many tables are still open.
/// It always covers today regardless of the range chosen below it, because
/// "today at a glance" is the question being answered.
class TodayGlanceCard extends StatelessWidget {
  const TodayGlanceCard({
    super.key,
    required this.allOrders,
    required this.formatAmount,
    this.openTables,
    this.now,
  });

  /// Every order the hub knows about; this card windows them to today itself.
  final List<Order> allOrders;
  final String Function(double) formatAmount;

  /// Tables with an order parked on them right now. Null hides the tile, for a
  /// shop with no floor.
  final int? openTables;

  /// Injected in tests so "today" is not the machine clock.
  final DateTime? now;

  List<Order> get _today {
    final at = now ?? DateTime.now();
    final start = DateTime(at.year, at.month, at.day);
    return allOrders
        .where((o) => !o.createdAt.toLocal().isBefore(start))
        .toList();
  }

  /// Cash is decided by the tender label, not by the payment-method config the
  /// hub does not have: an untendered sale is booked to cash the same way the
  /// shift read and the payment-mix report book it.
  static bool _isCash(String label) => label.toLowerCase() == 'cash';

  @override
  Widget build(BuildContext context) {
    final today = _today;
    var gross = 0.0;
    var cash = 0.0;
    for (final o in today) {
      gross += o.total;
      if (o.payments.isEmpty) {
        cash += o.total;
      } else {
        for (final p in o.payments) {
          if (_isCash(p.label ?? 'Cash')) cash += p.amount;
        }
      }
    }
    final other = gross - cash;

    return Card(
      key: const Key('today-glance'),
      margin: const EdgeInsets.fromLTRB(8, 8, 8, 0),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: AppColors.info.withValues(alpha: 0.25)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(tr(context, 'Today at a glance'),
                style: const TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 16,
              runSpacing: 8,
              children: [
                _stat(context, 'Orders', '${today.length}', 'glance-orders'),
                _stat(context, 'Gross sales', formatAmount(gross), 'glance-gross'),
                _stat(context, 'Cash', formatAmount(cash), 'glance-cash'),
                _stat(context, 'Other tenders', formatAmount(other), 'glance-other'),
                if (openTables != null)
                  _stat(context, 'Open tables', '$openTables', 'glance-tables'),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _stat(BuildContext context, String label, String value, String key) =>
      Column(
        key: Key(key),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(tr(context, label),
              style: Theme.of(context).textTheme.bodySmall),
          Text(value,
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
        ],
      );
}
