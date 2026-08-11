import 'package:flutter/material.dart';

import '../../domain/catalogue.dart';
import '../../domain/order.dart';

/// Label shown for a line with no category, or one whose category was deleted
/// from the catalogue after the sale. Grouping these under one bucket rather
/// than dropping them keeps the report's total in agreement with the orders
/// handed in.
const _uncategorisedLabel = 'Uncategorised';

/// One category's tally across every order in the report window: units moved,
/// revenue booked, and its share of the report's total revenue.
class _CategoryAggregate {
  _CategoryAggregate({required this.name, required this.quantity, required this.revenue});
  final String name;
  final double quantity;
  final double revenue;
}

/// A category-performance report: which product categories drove the most
/// revenue, and how far ahead of the rest each one is.
///
/// Lines are grouped by [OrderLine.categoryId] rather than by product, since
/// a manager comparing "mains vs drinks" needs the category rolled up, not a
/// per-product breakdown (that is [TopProductsReportScreen]'s job). It is a
/// pure view over the orders and categories handed in: the caller decides the
/// date range and never touches storage itself.
class CategoryReportScreen extends StatelessWidget {
  const CategoryReportScreen({super.key, required this.orders, required this.categories, required this.formatAmount});
  final List<Order> orders;
  final List<Category> categories;
  final String Function(double) formatAmount;

  /// Sums every line across every order into one aggregate per category,
  /// keyed by category id. A category sold across ten orders must appear once
  /// here, not ten times, or the ranking below would just be a list of orders
  /// again. Null and unresolved ids both fall into [_uncategorisedLabel], so a
  /// stale or missing category id never silently drops revenue from the total.
  List<_CategoryAggregate> _aggregate() {
    final names = <int, String>{for (final c in categories) c.id: c.name};
    final quantities = <int?, double>{};
    final revenues = <int?, double>{};
    for (final order in orders) {
      for (final line in order.lines) {
        final key = names.containsKey(line.categoryId) ? line.categoryId : null;
        quantities[key] = (quantities[key] ?? 0) + line.quantity;
        revenues[key] = (revenues[key] ?? 0) + line.total;
      }
    }
    return [
      for (final key in quantities.keys)
        _CategoryAggregate(
          name: key == null ? _uncategorisedLabel : names[key]!,
          quantity: quantities[key]!,
          revenue: revenues[key]!,
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final categoriesData = _aggregate()..sort((a, b) => b.revenue.compareTo(a.revenue));
    final totalRevenue = categoriesData.fold(0.0, (s, c) => s + c.revenue);

    return Scaffold(
      appBar: AppBar(title: const Text('Category performance')),
      body: orders.isEmpty || categoriesData.isEmpty
          ? const Center(child: Text('No orders'))
          : ListView.builder(
              key: const Key('category-list'),
              padding: const EdgeInsets.all(16),
              itemCount: categoriesData.length,
              itemBuilder: (context, i) => _categoryRow(
                context,
                categoriesData[i],
                share: totalRevenue == 0 ? 0.0 : categoriesData[i].revenue / totalRevenue,
                isTop: i == 0,
              ),
            ),
    );
  }

  Widget _categoryRow(BuildContext context, _CategoryAggregate c, {required double share, required bool isTop}) {
    final colorScheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    c.name,
                    style: TextStyle(fontWeight: isTop ? FontWeight.bold : FontWeight.normal, fontSize: 16),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (isTop) Icon(Icons.star, size: 16, color: colorScheme.primary),
                const SizedBox(width: 8),
                Text(
                  '${c.quantity.toStringAsFixed(c.quantity.truncateToDouble() == c.quantity ? 0 : 2)} units',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(width: 8),
                Text(
                  formatAmount(c.revenue),
                  style: TextStyle(fontWeight: isTop ? FontWeight.bold : FontWeight.normal),
                ),
              ],
            ),
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: share.clamp(0, 1),
                minHeight: 6,
                backgroundColor: colorScheme.surfaceContainerHighest,
                color: colorScheme.primary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
