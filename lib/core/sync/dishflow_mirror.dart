import '../db/settings_store.dart';
import '../../domain/order.dart';
import 'dishflow_sale_mapper.dart';
import 'outbox.dart';

/// Owner-mirror channel: paid sales on this till, visible in Dishflow reports.
///
/// Separate from [order.push]. Odoo still books at shift close; this kind leaves
/// whenever the line is up, so the owner can see the day without waiting for Z.
class DishflowMirror {
  DishflowMirror._();

  static const kind = 'dishflow.sale.push';

  /// Queue [order] for Dishflow when the mirror is switched on and pointed at a
  /// branch. No-op otherwise: an unconfigured till must not pile up undeliverable
  /// rows that diagnostics then report as stranded money.
  ///
  /// When a driver is assigned, also mirrors under `drivers/{id}/orders/{saleId}`
  /// so the rider app receives the bag the same way Dishflow does.
  static Future<void> enqueueIfEnabled({
    required Outbox outbox,
    required SettingsStore settings,
    required Order order,
    String? cashierName,
    String? status,
  }) async {
    if (!settings.dishflowMirrorReady) return;
    final payload = DishflowSaleMapper.toOutboxPayload(
      order,
      projectId: settings.dishflowProjectId!,
      apiKey: settings.dishflowApiKey!,
      odooConnectionId: settings.dishflowOdooConnectionId!,
      branchId: settings.dishflowBranchId,
      branchName: settings.dishflowBranchName,
      cashierName: cashierName,
      status: status,
    );
    await outbox.enqueue(kind, order.uuid, payload);
    final driverId = order.driverId?.trim();
    if (driverId == null || driverId.isEmpty) return;
    if (!order.type.isDelivery) return;
    final fields = Map<String, dynamic>.from(payload['fields'] as Map);
    final saleId = (payload['doc_id'] ?? '').toString();
    fields['sale_firebase_id'] = saleId;
    fields['total_amount'] = order.total;
    fields['delivery_fee'] = order.deliveryCost;
    await outbox.enqueue(
      driverOrderKind,
      '${order.uuid}|$driverId',
      {
        'project_id': settings.dishflowProjectId!,
        'api_key': settings.dishflowApiKey!,
        'doc_path': 'drivers/$driverId/orders/${_safeDocId(saleId)}',
        'fields': fields,
      },
    );
  }

  static const driverOrderKind = 'dishflow.driver.order.push';

  static String _safeDocId(String raw) =>
      raw.replaceAll(RegExp(r'[^a-zA-Z0-9_\-]'), '_');

  /// Mark a sale cancelled in Dishflow after amend/void of a paid order that may
  /// already have been mirrored. Same [docId] PATCH; a later re-pay enqueues sale.
  static Future<void> enqueueCancelIfEnabled({
    required Outbox outbox,
    required SettingsStore settings,
    required Order order,
    String? cashierName,
  }) =>
      enqueueIfEnabled(
        outbox: outbox,
        settings: settings,
        order: order,
        cashierName: cashierName,
        status: 'cancelled',
      );
}
