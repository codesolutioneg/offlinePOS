import '../core/audit/audit_log.dart';
import '../core/db/catalogue_store.dart';
import '../core/db/order_store.dart';
import '../core/sync/outbox.dart';
import '../domain/catalogue.dart';
import '../domain/order.dart';

/// The live selling state for one cashier on one till.
///
/// Deliberately synchronous. Every operation here is a local read or write, so a tap
/// never awaits anything: that is the whole reason this app exists.
class PosSession {
  PosSession({
    required this.catalogue,
    required this.orders,
    required this.outbox,
    required this.audit,
    required this.deviceId,
    required this.cashierId,
  });

  final CatalogueStore catalogue;
  final OrderStore orders;
  final Outbox outbox;
  final AuditLog audit;
  final String deviceId;
  final String cashierId;

  Order? _current;

  /// The order being built. Restored from disk if one was left unfinished, which is
  /// what gives a cashier their work back after a crash or a closed window.
  Order get current {
    _current ??= orders.drafts().firstOrNull ??
        Order(deviceId: deviceId, cashierId: cashierId);
    return _current!;
  }

  bool get hasLines => current.lines.isNotEmpty;
  double get total => current.total;

  /// Add a product, applying chosen modifiers. Persisted immediately.
  void addProduct(Product product, {List<ChosenModifier> chosen = const [], double qty = 1}) {
    final line = OrderLine(
      productId: product.id,
      name: product.name,
      quantity: qty,
      unitPrice: product.price,
      modifiers: [
        for (final c in chosen)
          OrderModifier(
            modifierId: c.modifier.id,
            name: c.modifier.name,
            quantity: c.quantity.toDouble(),
            // Priced against the parent now, so a later catalogue change cannot
            // rewrite what the customer was charged.
            unitPrice: c.modifier.priceFor(product.price),
          ),
      ],
    );
    current.lines.add(line);
    orders.save(current);
  }

  void removeLine(String lineUuid) {
    current.lines.removeWhere((l) => l.uuid == lineUuid);
    orders.save(current);
  }

  void setQuantity(String lineUuid, double qty) {
    if (qty <= 0) return removeLine(lineUuid);
    final line = current.lines.firstWhere((l) => l.uuid == lineUuid);
    line.quantity = qty;
    orders.save(current);
  }

  void clear() {
    final order = current;
    order.lines.clear();
    orders.save(order);
  }

  /// Take payment. Writes locally, queues for the server, and starts a fresh order.
  /// Returns the completed order so the caller can print it.
  Order pay() {
    final order = current;
    order.state = OrderState.paid;
    orders.save(order);
    outbox.enqueue('order.push', order.uuid, order.toMap());
    audit.record(cashierId, 'order.paid', detail: order.uuid);
    _current = Order(deviceId: deviceId, cashierId: cashierId);
    return order;
  }
}

/// A modifier the cashier picked, with how many.
class ChosenModifier {
  const ChosenModifier(this.modifier, [this.quantity = 1]);
  final Modifier modifier;
  final int quantity;
}
