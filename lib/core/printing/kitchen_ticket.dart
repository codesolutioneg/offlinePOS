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
  Uint8List build(Order order,
      {List<OrderLine>? only, String? station, bool reprint = false}) {
    final lines = only ?? order.lines;
    final p = EscPos(columns: columns)..reset();
    const major = '=';

    // Top breathing room, then ===STATION=== centred by the printer (not by
    // space-padding — padding + align-center drifts double-width text).
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
    if (order.type == OrderType.delivery &&
        order.companyOrderNo != null &&
        order.companyOrderNo!.isNotEmpty) {
      p.align(EscPosAlign.center)
          .size(doubleWidth: true, doubleHeight: true)
          .bold(true)
          .line('#${order.companyOrderNo}')
          .bold(false)
          .size();
    }

    // Same seating wording as the payment receipt: "e - Table 2", centred.
    final tableLine = _tableDisplay(order);
    if (tableLine != null) {
      p.align(EscPosAlign.center)
          .size(doubleWidth: true, doubleHeight: true)
          .bold(true)
          .line('* $tableLine *')
          .bold(false)
          .size();
    }

    // Time large in the middle.
    p.align(EscPosAlign.center)
        .size(doubleWidth: true, doubleHeight: true)
        .bold(true)
        .line(_time12(order.createdAt))
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
        .line(_dateMdy(order.createdAt))
        .bold(false);
    final server = serverNameOf?.call(order.cashierId)?.trim();
    if (server != null && server.isNotEmpty) {
      p.align(EscPosAlign.center).line('Server: $server');
    }
    p.align(EscPosAlign.left);

    // Delivery contact under the header (kitchen needs who/phone, not address).
    if (order.type == OrderType.delivery) {
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
  Uint8List buildVoid(Order order, OrderLine line, String reason) {
    final p = EscPos(columns: columns)..reset();
    const major = '=';
    p.feed(2);
    p.align(EscPosAlign.center)
      ..size(doubleWidth: true, doubleHeight: true)
      ..bold(true)
      ..centred('===${'KITCHEN'}===')
      ..bold(false)
      ..size();
    p.align(EscPosAlign.left).rule(major);
    final tableLine = _tableDisplay(order);
    if (tableLine != null) {
      p.align(EscPosAlign.center)
          .size(doubleHeight: true)
          .bold(true)
          .centred(tableLine)
          .bold(false)
          .size();
    }
    p.align(EscPosAlign.center)
        .size(doubleHeight: true)
        .bold(true)
        .centred(_time12(DateTime.now().toUtc()))
        .bold(false)
        .size();
    p.align(EscPosAlign.left).rule(major);
    p.bold(true).row(
          order.guestCount != null
              ? 'Cust(s): ${order.guestCount}'
              : 'Cust(s): -',
          'ORDER:${order.displayNo}',
        ).bold(false);
    p.rule(major);
    p.align(EscPosAlign.center)
        .bold(true)
        .line('*' * (columns.clamp(8, 32)))
        .size(doubleWidth: true, doubleHeight: true)
        .centred('DELETION')
        .size()
        .line('*' * (columns.clamp(8, 32)))
        .bold(false);
    p.align(EscPosAlign.left);
    p.size(doubleHeight: true)
        .bold(true)
        .line('-${_qty(line.quantity)}  ${line.name}')
        .bold(false)
        .size();
    for (final m in line.modifiers) {
      final qtyPrefix = m.quantity == 1 ? '' : '${_qty(m.quantity)}x ';
      p.size(doubleHeight: true).line('       $qtyPrefix${m.name}').size();
    }
    if (line.note != null && line.note!.isNotEmpty) {
      p.bold(true).line('       ** ${line.note} **').bold(false);
    }
    p.feed().line('Reason: $reason');
    final server = serverNameOf?.call(order.cashierId)?.trim();
    if (server != null && server.isNotEmpty) p.line('By: $server');
    return (p..feed(3)..cut()).build();
  }

  /// Non–dine-in order type as Dishflow English kitchen label; dine-in is table-only.
  String? _orderTypeBanner(Order order) {
    return switch (order.type) {
      OrderType.dineIn => null,
      OrderType.toGo => 'TO GO',
      OrderType.takeaway => 'TAKEAWAY',
      OrderType.delivery => 'DELIVERY',
    };
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
