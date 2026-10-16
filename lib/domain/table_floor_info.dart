import 'order.dart';

/// Derived floor colour for one table, from the bills sitting on it.
///
/// Not stored on the table row: occupancy is the bills, so a colour that disagreed
/// with the kitchen flag or the printed check could only ever be a lie.
enum TableFloorLife {
  /// Parked or being rung, kitchen has not seen a line yet.
  unsent,

  /// At least one line has been fired.
  sent,

  /// A pre-bill was printed while the tab is still open.
  billed,
}

/// What the floor tile shows for a busy table: money, age, how many bills, and
/// which colour to draw.
class TableFloorInfo {
  const TableFloorInfo({
    required this.total,
    required this.since,
    this.tabCount = 1,
    this.life = TableFloorLife.unsent,
  });

  final double total;
  final DateTime since;
  final int tabCount;
  final TableFloorLife life;

  /// Fold every open bill on one table into the tile facts.
  static TableFloorInfo fromTabs(Iterable<Order> tabs) {
    final list = tabs.toList();
    var total = 0.0;
    DateTime? since;
    var billed = false;
    var sent = false;
    for (final o in list) {
      total += o.total;
      if (since == null || o.createdAt.isBefore(since)) since = o.createdAt;
      if (o.billPrintedAt != null) billed = true;
      if (o.lines.any((l) => l.printedToKitchen)) sent = true;
    }
    return TableFloorInfo(
      total: total,
      since: since ?? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      tabCount: list.length,
      life: billed
          ? TableFloorLife.billed
          : sent
              ? TableFloorLife.sent
              : TableFloorLife.unsent,
    );
  }
}
