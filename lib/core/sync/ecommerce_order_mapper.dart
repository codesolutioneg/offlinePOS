import '../../app/pos_session.dart';
import '../../domain/catalogue.dart';
import '../../domain/ecommerce_order.dart';
import '../../domain/order.dart';
import '../db/catalogue_store.dart';

/// Loads an [EcommerceOrder] onto the open till session (Dishflow cart mapping).
class EcommerceOrderMapper {
  EcommerceOrderMapper._();

  /// Same rate the mobile app shows as "VAT (14%)" on checkout ([OrderVat.rate]).
  /// Payloads stay net; the till adds tax so Pay matches what the customer saw.
  static const storeVatPercent = 14.0;

  /// Claim result applied to [session]: fresh delivery/takeaway bag with lines,
  /// customer, fees, and [Order.ecommerceOrderId] for complete-on-pay.
  static void applyToSession({
    required PosSession session,
    required CatalogueStore catalogue,
    required EcommerceOrder order,
  }) {
    final type = order.isDelivery
        ? OrderType.storeDelivery
        : OrderType.takeaway;
    session.startFresh(type);
    final o = session.current;
    o.ecommerceOrderId = order.id;
    o.customerName = order.customerName;
    o.customerPhone = order.customerPhone;
    o.customerAddress = order.deliveryAddress;
    o.deliveryCost = order.deliveryFee < 0 ? 0 : order.deliveryFee;
    o.serviceFee = order.serviceFee < 0 ? 0 : order.serviceFee;
    if (order.orderNumber != null) {
      o.note = 'Store #${order.orderNumber}';
    }
    if (order.discount > 0 && order.totalAmount > 0) {
      // Approximate percent from money discount when the store sent an amount.
      final base = order.items.fold<double>(
          0, (s, i) => s + i.unitPrice * i.quantity);
      if (base > 0.01) {
        o.discountPercent =
            (order.discount / base * 100).clamp(0, 100).toDouble();
        o.discountReason = 'Store order';
      }
    }

    for (final item in order.items) {
      final product = _resolveProduct(catalogue, item);
      final unit = _money(item.unitPrice);
      if (product != null) {
        session.addProduct(product, qty: item.quantity);
        final line = session.current.lines.last;
        if (item.notes != null && item.notes!.isNotEmpty) {
          line.note = item.notes;
        }
        // Ticket wins over the local catalogue (promo / Odoo lag / float drift).
        line.unitPrice = unit;
        // Mobile checkout adds 14% VAT on net items; keep Pay in step.
        // (baseTaxRate is fixed at add — taxRate is what totals read.)
        line.taxRate = storeVatPercent;
        // Only the store's chosen modifiers — not whatever the till would prompt.
        line.modifiers
          ..clear()
          ..addAll([
            for (final m in item.modifiers)
              if (m.name.trim().isNotEmpty)
                OrderModifier(
                  modifierId: 0,
                  name: m.name,
                  quantity: 1,
                  unitPrice: _money(m.priceExtra),
                ),
          ]);
      } else {
        // Unknown SKU: still ring a free-named line so the kitchen gets the bag.
        final line = OrderLine(
          productId: item.productId ?? 0,
          name: item.name,
          quantity: item.quantity,
          unitPrice: unit,
          taxRate: storeVatPercent,
          baseTaxRate: storeVatPercent,
          note: item.notes,
          modifiers: [
            for (final m in item.modifiers)
              if (m.name.trim().isNotEmpty)
                OrderModifier(
                  modifierId: 0,
                  name: m.name,
                  quantity: 1,
                  unitPrice: _money(m.priceExtra),
                ),
          ],
        );
        session.current.lines.add(line);
      }
    }
    session.orders.save(session.current);
  }

  static Product? _resolveProduct(
      CatalogueStore catalogue, EcommerceOrderItem item) {
    final id = item.productId;
    if (id == null || id <= 0) return null;
    return catalogue.byId(id);
  }

  static double _money(double v) => (v * 100).round() / 100;
}
