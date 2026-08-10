import 'dart:typed_data';

import '../../domain/order.dart';
import 'escpos.dart';

/// Formats an order as a kitchen ticket (KOT), which is a different document from
/// the customer receipt: no prices, big product names the line cook reads at a
/// glance, and the modifiers and notes that actually change how a dish is made.
///
/// A restaurant cannot run without this. The customer receipt tells the guest what
/// they paid; the kitchen ticket tells the kitchen what to cook, and sending only
/// the receipt (which is what the app did before) means the kitchen never sees the
/// order at all.
class KitchenTicketBuilder {
  KitchenTicketBuilder({this.columns = 42});

  final int columns;

  /// Build a ticket for [order]. When [only] is given, prints just those lines,
  /// which is how a re-fire adds newly rung items without reprinting the whole
  /// order. [station] labels the ticket for the printer it is routed to.
  Uint8List build(Order order, {List<OrderLine>? only, String? station, bool reprint = false}) {
    final lines = only ?? order.lines;
    final p = EscPos(columns: columns)..reset();

    p.align(EscPosAlign.center)
      ..size(doubleWidth: true, doubleHeight: true)
      ..bold(true)
      ..line(station == null ? 'KITCHEN' : station.toUpperCase())
      ..bold(false)
      ..size();
    if (reprint) p.centred('*** REPRINT ***');
    p.align(EscPosAlign.left).rule();

    // The kitchen needs the where/who/how-many before the what: a dine-in for 4 at
    // table 12 is cooked and plated differently from a takeaway.
    p.size(doubleHeight: true).bold(true).line(order.type.label.toUpperCase())..bold(false)..size();
    if (order.tableLabel != null) p.line('Table: ${order.tableLabel}');
    if (order.guestCount != null) p.line('Guests: ${order.guestCount}');
    p.line('${_stamp(order.createdAt)}  #${_shortRef(order)}');
    p.line('By: ${order.cashierId}');
    p.rule();

    for (final l in lines) {
      // Name doubled so it is legible on a steamy pass; quantity leads it.
      p.size(doubleHeight: true).bold(true)
        ..line('${_qty(l.quantity)} x ${l.name}')
        ..bold(false)
        ..size();
      for (final m in l.modifiers) {
        p.line('   + ${m.name}${m.quantity > 1 ? ' x${_qty(m.quantity)}' : ''}');
      }
      // The note is the whole point of a kitchen ticket ("no onions"), so it is the
      // one thing printed bold under its line.
      if (l.note != null && l.note!.isNotEmpty) {
        p.bold(true).line('   ** ${l.note}').bold(false);
      }
    }

    if (order.note != null && order.note!.isNotEmpty) {
      p.rule().bold(true).line('NOTE: ${order.note}').bold(false);
    }
    return (p..feed(3)..cut()).build();
  }

  /// A deletion slip: tells the kitchen to bin something already fired. Without
  /// this a voided line keeps cooking. Mirrors jouma's deleted-line audit onto
  /// paper the kitchen can see.
  Uint8List buildVoid(Order order, OrderLine line, String reason) {
    final p = EscPos(columns: columns)..reset();
    p.align(EscPosAlign.center)
      ..size(doubleWidth: true, doubleHeight: true)
      ..bold(true)
      ..line('*** CANCEL ***')
      ..bold(false)
      ..size();
    p.align(EscPosAlign.left).rule();
    if (order.tableLabel != null) p.line('Table: ${order.tableLabel}');
    p.line('#${_shortRef(order)}  ${_stamp(DateTime.now().toUtc())}');
    p.rule();
    p.size(doubleHeight: true).bold(true)
      ..line('CANCEL: ${_qty(line.quantity)} x ${line.name}')
      ..bold(false)
      ..size();
    p.line('Reason: $reason');
    p.line('By: ${order.cashierId}');
    return (p..feed(3)..cut()).build();
  }

  String _shortRef(Order o) =>
      o.uuid.replaceAll('-', '').substring(0, 6).toUpperCase();

  String _qty(double q) =>
      q == q.roundToDouble() ? q.toStringAsFixed(0) : q.toStringAsFixed(3);

  String _stamp(DateTime utc) {
    final d = utc.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
  }
}

/// Groups an order's lines by the kitchen station that should cook them, so each
/// station's printer gets only its own items.
///
/// Routing is by product category: the shop maps a category id to a station name
/// (a configured printer such as 'kitchen' or 'bar'). Anything unmapped falls to
/// [fallbackStation], because a line with no route must still reach a kitchen
/// rather than silently vanish. Returns station name -> the lines for it.
Map<String, List<OrderLine>> routeToStations(
  List<OrderLine> lines, {
  Map<int, String> categoryToStation = const {},
  String fallbackStation = 'kitchen',
}) {
  final byStation = <String, List<OrderLine>>{};
  for (final l in lines) {
    final station = categoryToStation[l.categoryId] ?? fallbackStation;
    byStation.putIfAbsent(station, () => []).add(l);
  }
  return byStation;
}
