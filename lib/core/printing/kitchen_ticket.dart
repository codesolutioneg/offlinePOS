import 'dart:typed_data';

import '../../domain/order.dart';
import 'escpos.dart';

/// What became of a kitchen ticket.
///
/// The cashier has to be told the truth: [sent] means a printer took it and the food
/// is being cooked, [spooled] means it is held and will print when the printer is
/// back, and [lost] means nothing anywhere has it and the kitchen must be told by
/// hand. Telling a rush "Sent to kitchen" for all three is how food never arrives.
enum KitchenFireResult {
  sent,
  spooled,
  lost;

  /// The worse of two outcomes, for a ticket that went to several stations: one lost
  /// copy makes the whole fire lost, because part of the order is not being cooked.
  KitchenFireResult worst(KitchenFireResult other) =>
      other.index > index ? other : this;
}

/// Formats an order as a kitchen ticket (KOT) in the Dishflow classic layout:
/// station banner, large order-type / table / time, Cust(s)/ORDER row, category
/// groups, double-height qty+name, indented modifiers and notes — no prices.
///
/// The customer receipt tells the guest what they paid; this ticket tells the
/// kitchen what to cook.
class KitchenTicketBuilder {
  KitchenTicketBuilder({
    this.columns = 42,
    this.sectionOf,
    this.categoryNameOf,
    this.serverNameOf,
  });

  final int columns;

  /// Which part of the floor a table sits in, by table name.
  final String? Function(String tableLabel)? sectionOf;

  /// Category title for grouping items on the ticket.
  final String? Function(int categoryId)? categoryNameOf;

  /// Human name for the Server row (cashier id → display name).
  final String? Function(String cashierId)? serverNameOf;

  /// Build a ticket for [order]. When [only] is given, prints just those lines.
  ///
  /// [at] is when this ticket is sent. The clock on the paper is that moment,
  /// not when the table was opened ([Order.createdAt]).
  Uint8List build(Order order,
      {List<OrderLine>? only,
      String? station,
      bool reprint = false,
      DateTime? at}) {
    final lines = only ?? order.lines;
    final p = EscPos(columns: columns)..reset();
    const major = '=';
    _header(p, order,
        station: station,
        at: at ?? DateTime.now().toUtc(),
        reprint: reprint);

    // Items grouped by category (uppercase headers), Dishflow style.
    String? lastCat;
    for (final l in lines) {
      final cat = _categoryLabel(l);
      if (cat != null && cat != lastCat) {
        lastCat = cat;
        p.feed()
            .bold(true)
            .size(doubleHeight: true)
            .line(cat.toUpperCase())
            .size()
            .bold(false)
            .rule(major);
      }
      // qty + name — double height, no "x".
      p.size(doubleHeight: true)
          .bold(true)
          .line('${_qty(l.quantity)}  ${l.name}')
          .bold(false)
          .size();
      // Modifiers: large + clear, quantity before the name ("4x Cheese").
      if (l.modifiers.isNotEmpty ||
          (l.note != null && l.note!.isNotEmpty)) {
        p.feed();
      }
      for (final m in l.modifiers) {
        final qtyPrefix =
            m.quantity == 1 ? '' : '${_qty(m.quantity)}x ';
        final label = '    $qtyPrefix${m.name}';
        p.size(doubleHeight: true).bold(true).line(label).bold(false).size();
      }
      if (l.note != null && l.note!.isNotEmpty) {
        p.size(doubleHeight: true)
            .bold(true)
            .line('    ** ${l.note} **')
            .bold(false)
            .size();
      }
      p.feed();
    }

    if (order.note != null && order.note!.isNotEmpty) {
      p.rule(major).bold(true).line('NOTE: ${order.note}').bold(false);
    }
    return (p..feed(3)..cut()).build();
  }

  /// A deletion slip: Dishflow-style DELETION banner so the kitchen bins a line.
  ///
  /// Headed exactly like the ticket that fired the line (station, order type,
  /// company number, table, Cust(s)/ORDER), so the pass can match the two slips
  /// at a glance; only the time is when it was deleted.
  Uint8List buildVoid(Order order, OrderLine line, String reason,
      {String? station, DateTime? at}) {
    final p = EscPos(columns: columns)..reset();
    _header(p, order, station: station, at: at ?? DateTime.now().toUtc());

    final stars = '*' * (columns ~/ 2).clamp(8, 24);
    p.feed()
        .align(EscPosAlign.center)
        .bold(true)
        .line(stars)
        .size(doubleWidth: true, doubleHeight: true)
        .line('DELETION')
        .size()
        .line(stars)
        .bold(false)
        .align(EscPosAlign.left)
        .feed();
    p.size(doubleHeight: true)
        .bold(true)
        .line('-${_qty(line.quantity)}  ${line.name}')
        .bold(false)
        .size();
    for (final m in line.modifiers) {
      final qtyPrefix = m.quantity == 1 ? '' : '${_qty(m.quantity)}x ';
      p.size(doubleHeight: true).bold(true).line('    $qtyPrefix${m.name}').bold(false).size();
    }
    if (line.note != null && line.note!.isNotEmpty) {
      p.size(doubleHeight: true)
          .bold(true)
          .line('    ** ${line.note} **')
          .bold(false)
          .size();
    }
    p.feed().rule('-').bold(true).line('Reason: $reason').bold(false);
    return (p..feed(3)..cut()).build();
  }

  /// Station banner down to the delivery contact, shared by the ticket and the
  /// deletion slip. Everything centred is centred by the printer, never by space
  /// padding as well: the two together push double-width text off to the right.
  void _header(EscPos p, Order order,
      {String? station, required DateTime at, bool reprint = false}) {
    const major = '=';
    p.feed(4);
    p.align(EscPosAlign.center)
      ..size(doubleWidth: true, doubleHeight: true)
      ..bold(true)
      ..line('===${(station ?? 'KITCHEN').toUpperCase()}===')
      ..bold(false)
      ..size();
    if (reprint) {
      for (var i = 0; i < 3; i++) {
        p.size(doubleWidth: true, doubleHeight: true)
            .bold(true)
            .line('** RE-PRINT **')
            .bold(false)
            .size();
      }
    }
    p.align(EscPosAlign.left).rule(major);

    // Order-type banner (skip plain DINE IN — table carries that).
    final typeBanner = _orderTypeBanner(order);
    if (typeBanner != null) {
      p.align(EscPosAlign.center)
          .size(doubleWidth: true, doubleHeight: true)
          .bold(true)
          .line(typeBanner)
          .bold(false)
          .size();
    }
    if (order.type.isDelivery &&
        order.companyOrderNo != null &&
        order.companyOrderNo!.isNotEmpty) {
      p.align(EscPosAlign.center)
          .size(doubleWidth: true, doubleHeight: true)
          .bold(true)
          .line('#${order.companyOrderNo}')
          .bold(false)
          .size();
    }

    // Same seating wording as the payment receipt: "e - Table 2", centred. Tall
    // but normal width, so a section and a table name fit on one line.
    final tableLine = _tableDisplay(order);
    if (tableLine != null) {
      p.align(EscPosAlign.center)
          .size(doubleHeight: true)
          .bold(true)
          .line('* $tableLine *')
          .bold(false)
          .size();
    }

    // Time large in the middle.
    p.align(EscPosAlign.center)
        .size(doubleWidth: true, doubleHeight: true)
        .bold(true)
        .line(_time12(at))
        .bold(false)
        .size();

    p.align(EscPosAlign.left).rule(major);

    // Cust(s) / ORDER — same displayNo as the customer receipt (no short form).
    final cust = order.guestCount != null
        ? 'Cust(s): ${order.guestCount}'
        : 'Cust(s): -';
    final ord = 'ORDER:${order.displayNo}';
    p.bold(true).row(cust, ord).bold(false);
    p.rule(major);

    // Date + server centred on the paper.
    p.align(EscPosAlign.center)
        .bold(true)
        .line(_dateMdy(at))
        .bold(false);
    final server = serverNameOf?.call(order.cashierId)?.trim();
    if (server != null && server.isNotEmpty) {
      p.align(EscPosAlign.center).line('Server: $server');
    }
    p.align(EscPosAlign.left);

    // Delivery contact under the header (kitchen needs who/phone, not address).
    if (order.type.isDelivery) {
      if (order.customerName != null && order.customerName!.isNotEmpty) {
        p.line('Customer: ${order.customerName}');
      }
      if (order.customerPhone != null && order.customerPhone!.isNotEmpty) {
        p.line('Phone: ${order.customerPhone}');
      }
      final channel = [
        if (order.deliveryChannel != null) order.deliveryChannel!,
      ].join(' ');
      if (channel.isNotEmpty) p.line('Channel: $channel');
      if (order.driverName != null) p.line('Driver: ${order.driverName}');
    }
  }

  /// Non–dine-in order type as Dishflow English kitchen label; dine-in is table-only.
  String? _orderTypeBanner(Order order) {
    if (order.type == OrderType.dineIn) return null;
    return order.type.printBanner;
  }

  /// Same wording as the payment receipt banner: `e - Table 2`.
  String? _tableDisplay(Order order) {
    final label = order.tableLabel;
    if (label == null || label.isEmpty) return null;
    final section = sectionOf?.call(label);
    final parts = <String>[
      if (section != null && section.isNotEmpty) section,
      'Table $label',
    ];
    return parts.join(' - ');
  }

  String? _categoryLabel(OrderLine l) {
    final id = l.categoryId;
    if (id == null) return null;
    final name = categoryNameOf?.call(id)?.trim();
    return (name != null && name.isNotEmpty) ? name : null;
  }

  String _qty(double q) =>
      q == q.roundToDouble() ? q.toStringAsFixed(0) : q.toStringAsFixed(3);

  static String _time12(DateTime utc) {
    final d = utc.toLocal();
    final h24 = d.hour;
    final ap = h24 >= 12 ? 'PM' : 'AM';
    final h12 = h24 % 12 == 0 ? 12 : h24 % 12;
    final min = d.minute.toString().padLeft(2, '0');
    return '$h12:$min $ap';
  }

  static String _dateMdy(DateTime utc) {
    final d = utc.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(d.month)}/${two(d.day)}/${d.year}';
  }
}

/// Groups an order's lines by the kitchen station(s) that should cook them, so
/// each station's printer gets its own items and a line that belongs at more
/// than one station prints at every one of them rather than just the first.
Map<String, List<OrderLine>> routeToStations(
  List<OrderLine> lines, {
  Map<int, List<String>> categoryToStations = const {},
  Map<int, List<String>> productToStations = const {},
  String fallbackStation = 'kitchen',
}) {
  final byStation = <String, List<OrderLine>>{};
  for (final l in lines) {
    final productOverride = productToStations[l.productId];
    final categoryStations = categoryToStations[l.categoryId];
    final stations = (productOverride != null && productOverride.isNotEmpty)
        ? productOverride
        : (categoryStations != null && categoryStations.isNotEmpty)
            ? categoryStations
            : [fallbackStation];
    for (final station in stations) {
      byStation.putIfAbsent(station, () => []).add(l);
    }
  }
  return byStation;
}
