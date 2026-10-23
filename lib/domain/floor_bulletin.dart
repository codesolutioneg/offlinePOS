import 'order.dart';

/// The floor's at-a-glance numbers for the Bulletin panel: how the room stands
/// right now, and what has been closed today.
class FloorBulletin {
  const FloorBulletin({
    required this.tables,
    required this.openTables,
    required this.freeTables,
    required this.sentToKitchen,
    required this.notSent,
    required this.billPrinted,
    required this.delivery,
    required this.takeaway,
    required this.openAmount,
    required this.paidToday,
    required this.salesToday,
  });

  final int tables;
  final int openTables;
  final int freeTables;

  /// Open tables with at least one line already fired to the kitchen.
  final int sentToKitchen;

  /// Open tables where nothing has reached the kitchen yet.
  final int notSent;

  /// Open tables whose bill has been printed but not paid.
  final int billPrinted;

  /// Parked delivery orders, every subtype.
  final int delivery;

  /// Parked takeaway / to-go orders with no table.
  final int takeaway;

  /// What the open tables come to right now.
  final double openAmount;

  final int paidToday;
  final double salesToday;

  /// [tableNames] is the room as laid out; [open] is every order occupying the
  /// shop (all tills), with duplicates allowed; [held] every parked order.
  factory FloorBulletin.from({
    required Set<String> tableNames,
    required Iterable<Order> open,
    required Iterable<Order> held,
    int paidToday = 0,
    double salesToday = 0,
  }) {
    final seen = <String>{};
    final byTable = <String, List<Order>>{};
    for (final o in open) {
      final label = o.tableLabel;
      if (label == null || label.isEmpty || !seen.add(o.uuid)) continue;
      byTable.putIfAbsent(label, () => []).add(o);
    }
    bool fired(Order o) => o.lines
        .any((l) => l.printedToKitchen || l.firedStations.isNotEmpty);

    var sent = 0, billed = 0;
    var amount = 0.0;
    for (final tabs in byTable.values) {
      if (tabs.any(fired)) sent++;
      if (tabs.any((o) => o.billPrintedAt != null)) billed++;
      for (final o in tabs) {
        amount += o.total;
      }
    }
    final openHere = byTable.keys.where(tableNames.contains).length;

    final parked = <String, Order>{for (final o in held) o.uuid: o}.values;
    final noTable =
        parked.where((o) => (o.tableLabel ?? '').isEmpty).toList();

    return FloorBulletin(
      tables: tableNames.length,
      openTables: byTable.length,
      freeTables: (tableNames.length - openHere).clamp(0, tableNames.length),
      sentToKitchen: sent,
      notSent: byTable.length - sent,
      billPrinted: billed,
      delivery: parked.where((o) => o.type.isDelivery).length,
      takeaway: noTable.where((o) => !o.type.isDelivery).length,
      openAmount: amount,
      paidToday: paidToday,
      salesToday: salesToday,
    );
  }
}
