/// A store (ecommerce) order waiting on Firebase for this till to claim.
///
/// Shape matches Dishflow `ecommerce_orders` + the mobile checkout contract.
class EcommerceOrder {
  const EcommerceOrder({
    required this.id,
    required this.status,
    required this.items,
    this.orderNumber,
    this.customerName,
    this.customerPhone,
    this.deliveryAddress,
    this.orderType,
    this.branchId,
    this.branchName,
    this.deliveryFee = 0,
    this.serviceFee = 0,
    this.discount = 0,
    this.totalAmount = 0,
    this.dishflowOrderId,
    this.receivedBy,
    this.createdAt,
    this.raw = const {},
  });

  /// Firestore document id (= `ecommerceOrderId` on the mobile side).
  final String id;
  final String status;
  final List<EcommerceOrderItem> items;
  final String? orderNumber;
  final String? customerName;
  final String? customerPhone;
  final String? deliveryAddress;
  final String? orderType;
  final String? branchId;
  final String? branchName;
  final double deliveryFee;
  final double serviceFee;
  final double discount;
  final double totalAmount;
  final String? dishflowOrderId;
  final String? receivedBy;
  final DateTime? createdAt;
  final Map<String, dynamic> raw;

  bool get isPending => status == 'pending';
  bool get isReceived => status == 'received';

  /// Delivery unless the store marked pickup/takeaway.
  bool get isDelivery {
    final t = (orderType ?? '').toLowerCase();
    if (t.contains('pickup') ||
        t.contains('takeaway') ||
        t.contains('take away')) {
      return false;
    }
    return true;
  }

  /// Net merchandise (items + modifier extras), before VAT / delivery.
  double get itemsNet => items.fold<double>(0, (s, i) => s + i.lineNet);

  /// Same 14% the mobile checkout shows — VAT on items after discount, not delivery.
  double get vatAmount {
    final base = itemsNet - discount;
    if (base <= 0) return 0;
    return _money(base * storeVatRate);
  }

  /// What the customer sees as Total on checkout (net + delivery + fees + VAT).
  ///
  /// Prefer this over [totalAmount]: Firebase sometimes stores a partial or
  /// catalogue-drift figure that does not match the phone.
  double get customerTotal {
    final payable = itemsNet + deliveryFee + serviceFee - discount;
    final net = payable < 0 ? 0.0 : payable;
    return _money(net + vatAmount);
  }

  static const storeVatRate = 0.14;

  static double _money(double v) => (v * 100).round() / 100;
}

class EcommerceOrderItem {
  const EcommerceOrderItem({
    required this.name,
    required this.quantity,
    required this.unitPrice,
    this.productId,
    this.notes,
    this.modifiers = const [],
  });

  final String name;
  final double quantity;
  final double unitPrice;
  final int? productId;
  final String? notes;
  final List<EcommerceOrderModifier> modifiers;

  /// Line net: qty × unit + modifier extras (once per line, Dishflow cart shape).
  double get lineNet =>
      quantity * unitPrice +
      modifiers.fold<double>(0, (s, m) => s + m.priceExtra);
}

class EcommerceOrderModifier {
  const EcommerceOrderModifier({
    required this.name,
    this.priceExtra = 0,
  });

  final String name;
  final double priceExtra;
}
