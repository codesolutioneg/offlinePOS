/// One line a table opens with: the cover charge, the bottle of water, the bread.
///
/// Held as the product and a quantity rather than as a price, so the bill it lands
/// on is priced by the catalogue like any other line. A pre-order line is an ordinary
/// order line the moment it is added, which is what lets a waiter take it off with
/// the void they already have rather than needing a way out of a special case.
class TablePreorder {
  const TablePreorder({
    required this.productId,
    this.quantity = 1,
    this.perGuest = false,
  });

  final int productId;

  /// How many, or how many per guest when [perGuest] is set.
  final double quantity;

  /// Whether the quantity is multiplied by the covers on the table. What a cover
  /// charge is: one per person, decided by the guest count the waiter just gave,
  /// which is why the covers are asked for before the bill is opened.
  final bool perGuest;

  /// The quantity to actually ring for a table seating [guests]. A per-guest line on
  /// a table seated with nobody counted falls back to one, never to zero: a line
  /// worth nothing on the bill reads as a broken till.
  double quantityFor(int guests) {
    if (!perGuest) return quantity;
    final covers = guests > 0 ? guests : 1;
    return quantity * covers;
  }

  Map<String, dynamic> toMap() => {
        'product': productId,
        'qty': quantity,
        'per_guest': perGuest,
      };

  /// Returns null for a line this build cannot read, so one bad entry is skipped
  /// rather than costing a shop its whole pre-order list.
  static TablePreorder? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['product'];
    if (id is! int) return null;
    final qty = (raw['qty'] as num?)?.toDouble() ?? 1;
    if (qty <= 0) return null;
    return TablePreorder(
      productId: id,
      quantity: qty,
      perGuest: raw['per_guest'] == true,
    );
  }
}
