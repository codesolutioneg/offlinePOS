import 'package:flutter/material.dart';

import '../../domain/order.dart';

/// One product's tally across every order in the report window: how many
/// units moved and how much revenue they booked. Aggregated by name rather
/// than [OrderLine.productId] alone, since the name is what a manager
/// recognises on the printed report.
class _ProductAggregate {
  _ProductAggregate({required this.name, required this.quantity, required this.revenue});
  final String name;
  final double quantity;
  final double revenue;
}

/// A best-sellers report: which products moved the most units and which
/// earned the most revenue, side by side.
///
/// The two rankings are not the same list in a different order: a cheap side
/// dish can outsell an expensive main by volume while the main still wins on
/// revenue, and a manager restocking the kitchen cares about one ranking
/// while a manager pricing the menu cares about the other. It is a pure view
/// over the orders handed in: the caller decides the date range and never
/// touches storage itself.
class TopProductsReportScreen extends StatelessWidget {
  const TopProductsReportScreen({super.key, required this.orders, required this.formatAmount});
  final List<Order> orders;
  final String Function(double) formatAmount;

  /// Sums every line across every order into one aggregate per product name.
  /// A product sold on ten different orders must appear once here, not ten
  /// times, or the ranking below would just be a list of orders again.
  List<_ProductAggregate> _aggregate() {
    final quantities = <String, double>{};
    final revenues = <String, double>{};
    for (final order in orders) {
      for (final line in order.lines) {
        quantities[line.name] = (quantities[line.name] ?? 0) + line.quantity;
        revenues[line.name] = (revenues[line.name] ?? 0) + line.total;
      }
    }
    return [
      for (final name in quantities.keys)
        _ProductAggregate(name: name, quantity: quantities[name]!, revenue: revenues[name]!),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final products = _aggregate();
    final byRevenue = [...products]..sort((a, b) => b.revenue.compareTo(a.revenue));
    final byQuantity = [...products]..sort((a, b) => b.quantity.compareTo(a.quantity));

    return Scaffold(
      appBar: AppBar(title: const Text('Top products')),
      body: orders.isEmpty || products.isEmpty
          ? const Center(child: Text('No orders'))
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _productCard(context, title: 'By revenue', key: const Key('top-by-revenue'), products: byRevenue, showRevenue: true),
                  const SizedBox(height: 16),
                  _productCard(context, title: 'By quantity', key: const Key('top-by-qty'), products: byQuantity, showRevenue: false),
                ],
              ),
            ),
    );
  }

  Widget _productCard(
    BuildContext context, {
    required String title,
    required Key key,
    required List<_ProductAggregate> products,
    required bool showRevenue,
  }) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            const Divider(),
            ListView.builder(
              key: key,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: products.length,
              itemBuilder: (context, i) => _productRow(context, products[i], isTop: i == 0),
            ),
          ],
        ),
      ),
    );
  }

  Widget _productRow(BuildContext context, _ProductAggregate p, {required bool isTop}) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: Text(
              p.name,
              style: TextStyle(fontWeight: isTop ? FontWeight.bold : FontWeight.normal),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (isTop) Icon(Icons.star, size: 16, color: colorScheme.primary),
          const SizedBox(width: 8),
          SizedBox(
            width: 48,
            child: Text(
              p.quantity.toStringAsFixed(p.quantity.truncateToDouble() == p.quantity ? 0 : 2),
              textAlign: TextAlign.right,
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 80,
            child: Text(
              formatAmount(p.revenue),
              textAlign: TextAlign.right,
              style: TextStyle(fontWeight: isTop ? FontWeight.bold : FontWeight.normal),
            ),
          ),
        ],
      ),
    );
  }
}
