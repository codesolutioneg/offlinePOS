import '../db/order_store.dart';
import '../db/settings_store.dart';
import '../db/sqlite_outbox_store.dart';
import '../../domain/order.dart';
import '../../domain/shift.dart';
import 'dishflow_sale_mapper.dart';
import 'outbox.dart';
import 'stress_guard.dart';

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
  ///
  /// [driverBag] false leaves the rider app alone, for a catch-up of sales whose
  /// bags were already handed over.
  static Future<void> enqueueIfEnabled({
    required Outbox outbox,
    required SettingsStore settings,
    required Order order,
    String? cashierName,
    String? status,
    bool driverBag = true,
  }) async {
    if (!settings.dishflowMirrorReady || isStressOrder(order)) return;
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
    if (!driverBag) return;
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

  /// What a catch-up of the open shift would do: the paid sales and refunds
  /// since the shift opened, split by where each stands with the mirror.
  ///
  /// A sale paid before the mirror was configured never reached the queue, so it
  /// has no row; a refused one was queued under settings Firestore rejected.
  /// Both are owed. Sent and waiting ones are left as they are.
  ///
  /// [allTills] (the primary) also takes the sales replicated from the other
  /// tills. Their queue is not visible here, so they are always sent; the doc id
  /// carries the ringing till, so one already in Firestore is overwritten, never
  /// doubled.
  static DishflowResendPlan planOpenShift({
    required Shift? shift,
    required OrderStore orders,
    required SqliteOutboxStore store,
    bool allTills = false,
  }) {
    if (shift == null || !shift.isOpen) return const DishflowResendPlan.noShift();
    final own = orders.ownDeviceId;
    final sales = orders
        .paidBetween(from: shift.openedAt, anyDevice: allTills)
        .where((o) => !isStressOrder(o))
        .toList();
    bool mine(Order o) => own == null || o.deviceId == own;
    final states =
        store.statesOf(kind, [for (final o in sales) if (mine(o)) o.uuid]);
    final others = [for (final o in sales) if (!mine(o)) o];
    return DishflowResendPlan(
      shiftOpen: true,
      toSend: [
        for (final o in sales)
          if (mine(o) &&
              !states.sent.contains(o.uuid) &&
              !states.waiting.contains(o.uuid))
            o,
        ...others,
      ],
      sent: states.sent.length,
      waiting: states.waiting.length,
      refused: states.refused.length,
      otherTills: others.length,
    );
  }

  /// Queue [plan]'s sales the way a payment does, under the settings saved now.
  /// The normal drain delivers them; the same doc id means a sale that did reach
  /// Firestore is overwritten, never doubled. Returns how many were queued.
  static Future<int> resend({
    required Outbox outbox,
    required SqliteOutboxStore store,
    required SettingsStore settings,
    required DishflowResendPlan plan,
  }) async {
    if (!settings.dishflowMirrorReady) return 0;
    var queued = 0;
    for (final order in plan.toSend) {
      await enqueueIfEnabled(
        outbox: outbox,
        settings: settings,
        order: order,
        driverBag: false,
      );
      store.reviveByKey(kind, order.uuid);
      queued++;
    }
    return queued;
  }
}

/// The open shift's sales as the mirror sees them, for the catch-up button.
class DishflowResendPlan {
  const DishflowResendPlan({
    required this.shiftOpen,
    required this.toSend,
    required this.sent,
    required this.waiting,
    required this.refused,
    this.otherTills = 0,
  });

  const DishflowResendPlan.noShift()
      : shiftOpen = false,
        toSend = const [],
        sent = 0,
        waiting = 0,
        refused = 0,
        otherTills = 0;

  final bool shiftOpen;

  /// Never queued, refused, or rung on another till: these go out on
  /// [DishflowMirror.resend].
  final List<Order> toSend;
  final int sent;
  final int waiting;

  /// Already counted in [toSend].
  final int refused;

  /// Sales replicated from the other tills. Already counted in [toSend].
  final int otherTills;

  int get total => toSend.length + sent + waiting;
}
