import '../../domain/order.dart';

/// One product's trade over the report window: what it sold, what it earned, and
/// what it cost the shop to sell.
class ProductMargin {
  ProductMargin({
    required this.productId,
    required this.name,
    required this.units,
    required this.revenue,
    required this.cost,
    required this.costed,
  });

  final int productId;
  final String name;

  /// Units sold, net of refunds: a reversal carries negative quantities, so a
  /// refunded dish stops counting as one that moved.
  final double units;

  /// What the shop kept, net of tax and of both discounts. Prices are
  /// tax-inclusive, so leaving the tax in would flatter every margin by the VAT
  /// rate, and the cost it is compared against never had tax in it.
  final double revenue;

  /// Units times the cost the server last stated. Zero and meaningless when
  /// [costed] is false.
  final double cost;

  /// Whether the server ever said what this product costs. An unknown cost is not
  /// a cost of zero: a product without one is reported apart rather than shown as
  /// pure profit.
  final bool costed;

  double get margin => revenue - cost;

  /// Margin as a share of revenue. Zero revenue has no percentage, so it reads as
  /// zero rather than as infinity.
  double get marginPercent => revenue == 0 ? 0 : margin / revenue * 100;
}

/// Every product in [orders], with the cost the catalogue holds for it.
///
/// A pure function over what the caller already windowed, like every other report
/// here: no storage, no network, no clock. Aggregated by product id rather than by
/// name, because a renamed dish is still the same dish and its cost is keyed by id.
List<ProductMargin> productMargins(List<Order> orders, Map<int, double> costs) {
  final names = <int, String>{};
  final units = <int, double>{};
  final revenue = <int, double>{};
  for (final order in orders) {
    final orderFactor = order.discountFactor;
    for (final line in order.lines) {
      names[line.productId] = line.name;
      units[line.productId] = (units[line.productId] ?? 0) + line.quantity;
      // The line price is already net: the tax is charged on top of it and is the
      // state's money, not the shop's, so it never enters a margin. Dividing it back
      // out here (as this did when prices were tax-inclusive) would take 14% off the
      // revenue twice and understate every margin in the report.
      revenue[line.productId] =
          (revenue[line.productId] ?? 0) + line.total * orderFactor;
    }
  }
  final out = [
    for (final id in names.keys)
      ProductMargin(
        productId: id,
        name: names[id]!,
        units: units[id]!,
        revenue: revenue[id]!,
        cost: (costs[id] ?? 0) * units[id]!,
        costed: costs.containsKey(id),
      ),
  ];
  out.sort((a, b) => b.margin.compareTo(a.margin));
  return out;
}
