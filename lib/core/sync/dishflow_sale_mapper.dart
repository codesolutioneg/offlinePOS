import '../../domain/order.dart';

/// Builds the Firestore `sales` document shape Dishflow reports already read.
///
/// Pure: no IO. The outbox stores the result; the sender only transports it.
class DishflowSaleMapper {
  DishflowSaleMapper._();

  /// Same docId rule as Dishflow's SaleDocId: connection + user + order number.
  ///
  /// [userId] is till-scoped (`offlinepos_<device>`), never a Dishflow cashier id,
  /// so two systems cannot collide on the same document.
  static String docId({
    required String odooConnectionId,
    required String userId,
    required String orderId,
    String? orderNumber,
  }) {
    final safeUser = userId.trim().isNotEmpty ? userId.trim() : 'u0';
    final safeNum = _normalizeOrderNumber(orderNumber, orderId);
    return safeNum.isNotEmpty
        ? '${odooConnectionId}_${safeUser}_$safeNum'
        : 'pending_${odooConnectionId}_${safeUser}_$orderId';
  }

  static String mirrorUserId(String deviceId) {
    final safe = deviceId.trim().replaceAll(RegExp(r'[^a-zA-Z0-9\-_]'), '_');
    return 'offlinepos_${safe.isEmpty ? 'till' : safe}';
  }

  /// Envelope the outbox holds: transport coords plus the document fields.
  static Map<String, dynamic> toOutboxPayload(
    Order order, {
    required String projectId,
    required String apiKey,
    required String odooConnectionId,
    String? branchId,
    String? branchName,
    String? cashierName,
  }) {
    final userId = mirrorUserId(order.deviceId);
    final orderNumber = order.orderNo ?? order.displayNo;
    final id = docId(
      odooConnectionId: odooConnectionId,
      userId: userId,
      orderId: order.uuid,
      orderNumber: orderNumber,
    );
    return {
      'doc_id': id,
      'project_id': projectId,
      'api_key': apiKey,
      'fields': toSalesFields(
        order,
        odooConnectionId: odooConnectionId,
        userId: userId,
        orderNumber: orderNumber,
        branchId: branchId,
        branchName: branchName,
        cashierName: cashierName,
      ),
    };
  }

  /// Native Dart map of the `sales` document (not yet Firestore-REST encoded).
  static Map<String, dynamic> toSalesFields(
    Order order, {
    required String odooConnectionId,
    required String userId,
    required String orderNumber,
    String? branchId,
    String? branchName,
    String? cashierName,
  }) {
    final biz = order.businessDay.key;
    final sessionId = 'session_${biz}_offlinepos';
    final paymentLabel = _primaryPaymentLabel(order);
    final payments = order.payments
        .map((p) => <String, dynamic>{
              'amount': p.amount,
              if (p.label != null && p.label!.trim().isNotEmpty)
                'payment_method_name': p.label,
              if (p.journalId != null) 'journal_id': p.journalId,
              if (!p.isJournal) 'payment_method_id': p.methodId,
            })
        .toList();

    final rawItems = order.lines.map(_lineRaw).toList();
    final items = order.lines.map(_lineSummary).toList();

    final discountAmount = order.discountMoney.abs();
    final isDelivery = order.type == OrderType.delivery;

    return {
      'odooOrderId': 'pending_${order.uuid}',
      'odooOrderName': 'انتظار المزامنة',
      'posOrderId': order.uuid,
      'orderNumber': orderNumber,
      'odooConnectionId': odooConnectionId,
      'odooConnectionName': branchName ?? odooConnectionId,
      'userId': userId,
      'userName': cashierName ?? order.cashierId,
      'amount': order.total,
      'itemsCount': order.lines.fold<double>(0, (s, l) => s + l.quantity).round(),
      'paymentMethod': paymentLabel,
      if (payments.isNotEmpty) 'payments': payments,
      'syncedToOdoo': order.state == OrderState.synced,
      'status': 'sale',
      'source': 'offline_pos',
      'orderType': order.type.wireName,
      if (isDelivery) 'delivery_status': 'received',
      'businessDateKey': biz,
      'sessionDate': biz,
      'sessionId': sessionId,
      if (branchId != null && branchId.trim().isNotEmpty) 'branchId': branchId.trim(),
      if (branchName != null && branchName.trim().isNotEmpty)
        'branchName': branchName.trim(),
      if (order.customerName != null && order.customerName!.trim().isNotEmpty)
        'customer_name': order.customerName!.trim(),
      if (order.customerPhone != null && order.customerPhone!.trim().isNotEmpty)
        'customer_phone': order.customerPhone!.trim(),
      if (order.customerAddress != null &&
          order.customerAddress!.trim().isNotEmpty)
        'delivery_address': order.customerAddress!.trim(),
      if (order.companyOrderNo != null &&
          order.companyOrderNo!.trim().isNotEmpty)
        'delivery_company_order_no': order.companyOrderNo!.trim(),
      if (order.driverName != null && order.driverName!.trim().isNotEmpty)
        'driver_name': order.driverName!.trim(),
      if (order.tableLabel != null && order.tableLabel!.trim().isNotEmpty)
        'tableLabel': order.tableLabel!.trim(),
      if (order.deliveryCost > 0) 'deliveryFee': order.deliveryCost,
      if (order.serviceCharge > 0) 'serviceFee': order.serviceCharge,
      if (order.discountPercent > 0) 'discountType': 'percent',
      if (order.discountPercent > 0) 'discountValue': order.discountPercent,
      if (discountAmount > 0) 'discountAmount': discountAmount,
      if (order.discountReason != null &&
          order.discountReason!.trim().isNotEmpty)
        'discountReason': order.discountReason!.trim(),
      'cashier_id': order.cashierId,
      if (cashierName != null && cashierName.trim().isNotEmpty)
        'cashier_name': cashierName.trim(),
      'orderCreatedAt': order.createdAt.toUtc().toIso8601String(),
      'orderUpdatedAt': DateTime.now().toUtc().toIso8601String(),
      'orderLinesRaw': rawItems,
      'items': items,
      if (order.isRefund) 'refundOfUuid': order.refundOfUuid,
      if (order.amended) 'amended': true,
    };
  }

  static String _primaryPaymentLabel(Order order) {
    if (order.payments.isEmpty) return 'Cash';
    final named = order.payments
        .map((p) => (p.label ?? '').trim())
        .where((s) => s.isNotEmpty);
    if (named.isEmpty) return 'Cash';
    return named.join(' + ');
  }

  static Map<String, dynamic> _lineRaw(OrderLine l) => {
        'product_id': l.odooProductId ?? l.productId,
        'name': l.name,
        'product_name': l.name,
        'quantity': l.quantity,
        'unit_price': l.unitPrice,
        'price_unit': l.unitPrice,
        'total_price': l.total,
        if (l.discountPercent > 0) 'item_discount_type': 'percent',
        if (l.discountPercent > 0) 'item_discount_value': l.discountPercent,
        if (l.categoryId != null) 'category_id': l.categoryId,
        'modifiers': l.modifiers
            .map((m) => {
                  'name': m.name,
                  'quantity': m.quantity,
                  'unit_price': m.unitPrice,
                })
            .toList(),
      };

  static Map<String, dynamic> _lineSummary(OrderLine l) {
    final modifierNames =
        l.modifiers.map((m) => m.name).where((n) => n.isNotEmpty).toList();
    return {
      'productId': '${l.odooProductId ?? l.productId}',
      'productName': l.name,
      'quantity': l.quantity.round() == l.quantity
          ? l.quantity.toInt()
          : l.quantity,
      'unitPrice': l.unitPrice,
      'totalPrice': l.total,
      if (modifierNames.isNotEmpty) 'modifiers': modifierNames,
    };
  }

  static String _normalizeOrderNumber(String? orderNumber, String orderId) {
    var raw = (orderNumber ?? '').trim();
    if (raw.isEmpty) {
      final embedded = RegExp(r'\d{4}-\d{4}-\d{3}').firstMatch(orderId);
      if (embedded != null) raw = embedded.group(0)!;
    }
    return raw.replaceAll(RegExp(r'[^a-zA-Z0-9\-_]'), '_');
  }
}
