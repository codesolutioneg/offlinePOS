import 'business_day.dart';
import 'identity.dart';

enum OrderState { draft, paid, synced }

/// A modifier applied to a line, priced at the moment of sale.
///
/// The price is captured here rather than looked up later: a receipt must never
/// change because someone edited the catalogue afterwards.
class OrderModifier {
  OrderModifier({
    required this.modifierId,
    required this.name,
    required this.quantity,
    required this.unitPrice,
  });

  final int modifierId;
  final String name;
  final double quantity;
  final double unitPrice;

  double get total => quantity * unitPrice;

  Map<String, dynamic> toMap() => {
        'modifier_id': modifierId,
        'name': name,
        'quantity': quantity,
        'unit_price': unitPrice,
      };

  factory OrderModifier.fromMap(Map<String, dynamic> m) => OrderModifier(
        modifierId: m['modifier_id'] as int,
        name: m['name'] as String,
        quantity: (m['quantity'] as num).toDouble(),
        unitPrice: (m['unit_price'] as num).toDouble(),
      );
}

class OrderLine {
  OrderLine({
    String? uuid,
    required this.productId,
    required this.name,
    required this.quantity,
    required this.unitPrice,
    List<OrderModifier>? modifiers,
  })  : uuid = uuid ?? Uuid.v4(),
        modifiers = modifiers ?? [];

  final String uuid;
  final int productId;
  final String name;
  double quantity;
  final double unitPrice;
  final List<OrderModifier> modifiers;

  /// Modifiers are priced per unit of the parent, so they scale with quantity.
  double get total =>
      quantity * (unitPrice + modifiers.fold(0.0, (s, m) => s + m.total));

  Map<String, dynamic> toMap() => {
        'uuid': uuid,
        'product_id': productId,
        'name': name,
        'quantity': quantity,
        'unit_price': unitPrice,
        'modifiers': modifiers.map((m) => m.toMap()).toList(),
      };

  factory OrderLine.fromMap(Map<String, dynamic> m) => OrderLine(
        uuid: m['uuid'] as String,
        productId: m['product_id'] as int,
        name: m['name'] as String,
        quantity: (m['quantity'] as num).toDouble(),
        unitPrice: (m['unit_price'] as num).toDouble(),
        modifiers: ((m['modifiers'] as List?) ?? const [])
            .map((e) => OrderModifier.fromMap(e as Map<String, dynamic>))
            .toList(),
      );
}

class Order {
  Order({
    String? uuid,
    required this.deviceId,
    required this.cashierId,
    DateTime? createdAt,
    this.state = OrderState.draft,
    List<OrderLine>? lines,
    List<OrderPayment>? payments,
  })  : uuid = uuid ?? Uuid.v4(),
        createdAt = createdAt ?? DateTime.now().toUtc(),
        lines = lines ?? [],
        payments = payments ?? [];

  final String uuid;
  final String deviceId;
  final String cashierId;
  final DateTime createdAt;
  OrderState state;
  final List<OrderLine> lines;

  /// How the sale was tendered. Empty means the server books it to cash.
  List<OrderPayment> payments;

  /// Set once the backend confirms. Never used as identity.
  int? serverId;

  double get total => lines.fold(0.0, (s, l) => s + l.total);

  /// The trading day this sale belongs to, which decides the session it lands in
  /// on the server.
  BusinessDay get businessDay => BusinessDay.of(createdAt);

  Map<String, dynamic> toMap() => {
        // The idempotency key. The server must treat a repeat of this uuid as the
        // same sale, because a push can be retried after the server committed but
        // before the acknowledgement was recorded.
        'uuid': uuid,
        'device_id': deviceId,
        // Carried explicitly: with one shared Odoo login every order there is
        // attributed to the same user, so this is the only record of who rang it.
        'cashier_id': cashierId,
        // The moment of sale, not the moment of sync. Without it a week of offline
        // orders all post on the day the line came back and every daily report is
        // wrong.
        'created_at': createdAt.toIso8601String(),
        'business_date': businessDay.key,
        'state': state.name,
        'server_id': serverId,
        'lines': lines.map((l) => l.toMap()).toList(),
        'payments': payments.map((p) => p.toMap()).toList(),
      };

  factory Order.fromMap(Map<String, dynamic> m) => Order(
        uuid: m['uuid'] as String,
        deviceId: m['device_id'] as String,
        cashierId: m['cashier_id'] as String,
        createdAt: DateTime.parse(m['created_at'] as String),
        state: OrderState.values.byName(m['state'] as String),
        lines: ((m['lines'] as List?) ?? const [])
            .map((e) => OrderLine.fromMap(e as Map<String, dynamic>))
            .toList(),
        payments: ((m['payments'] as List?) ?? const [])
            .map((e) => OrderPayment.fromMap((e as Map).cast<String, dynamic>()))
            .toList(),
      )..serverId = m['server_id'] as int?;
}

/// One tender against a sale: which Odoo payment method, and how much.
class OrderPayment {
  const OrderPayment({required this.methodId, required this.amount});
  final int methodId;
  final double amount;

  Map<String, dynamic> toMap() => {'method_id': methodId, 'amount': amount};
  factory OrderPayment.fromMap(Map<String, dynamic> m) => OrderPayment(
        methodId: m['method_id'] as int,
        amount: (m['amount'] as num).toDouble(),
      );
}
