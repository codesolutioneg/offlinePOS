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
  static Future<void> enqueueIfEnabled({
    required Outbox outbox,
    required SettingsStore settings,
    required Order order,
    String? cashierName,
  }) {
    if (!settings.dishflowMirrorReady) return Future.value();
    final payload = DishflowSaleMapper.toOutboxPayload(
      order,
      projectId: settings.dishflowProjectId!,
      apiKey: settings.dishflowApiKey!,
      odooConnectionId: settings.dishflowOdooConnectionId!,
      branchId: settings.dishflowBranchId,
      branchName: settings.dishflowBranchName,
      cashierName: cashierName,
    );
    return outbox.enqueue(kind, order.uuid, payload);
  }
}
