import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/i18n/l10n.dart';
import '../../core/theme/app_colors.dart';
import '../../core/widgets/feedback.dart';
import '../../domain/order.dart';

/// The dark surface a kitchen board sits on and the slightly lighter card tone
/// on top of it, so the board reads at a glance under pass-through lighting
/// instead of a bright white screen glaring back at the cooks.
const _kdsBackground = Color(0xFF1A1D23);
const _kdsCardSurface = Color(0xFF242830);

/// A live board of active kitchen tickets, one card per order, that a cook
/// advances New -> Preparing -> Ready -> Served without touching the till.
///
/// [load] is polled on a timer rather than pushed: the kitchen has its own
/// device and the till that books the order may be several seconds away or
/// offline entirely, so the board must catch up on its own schedule instead
/// of waiting on a notification that might never arrive.
class KitchenDisplayScreen extends StatefulWidget {
  const KitchenDisplayScreen({
    super.key,
    required this.load,
    required this.onStatus,
    this.nowFn = DateTime.now,
  });

  /// Returns the active tickets, newest first. Called on every poll and on
  /// manual refresh.
  final List<Order> Function() load;

  /// Advances [uuid] to [status]. The board reloads immediately after, so the
  /// caller does not need to return anything: the next [load] is the source
  /// of truth for what actually happened.
  final void Function(String uuid, KitchenStatus status) onStatus;

  /// The clock driving the app bar time and every card's elapsed timer.
  /// Defaults to the real clock; tests inject a controllable one so the
  /// second-by-second tick is deterministic instead of racing real wall time.
  final DateTime Function() nowFn;

  @override
  State<KitchenDisplayScreen> createState() => _KitchenDisplayScreenState();
}

class _KitchenDisplayScreenState extends State<KitchenDisplayScreen> {
  Timer? _poll;
  Timer? _clock;
  late List<Order> _orders;
  late DateTime _now;

  @override
  void initState() {
    super.initState();
    _orders = widget.load();
    _now = widget.nowFn();
    // A cook cannot be relied on to remember to tap refresh mid-service, so the
    // board keeps itself current even if nobody touches it.
    _poll = Timer.periodic(const Duration(seconds: 10), (_) => _refresh());
    // Drives the wall clock in the app bar and every card's live MM:SS timer, so
    // waiting time is obvious without a cook doing the subtraction in their head.
    _clock = Timer.periodic(
      const Duration(seconds: 1),
      (_) => mounted ? setState(() => _now = widget.nowFn()) : null,
    );
  }

  @override
  void dispose() {
    _poll?.cancel();
    _clock?.cancel();
    super.dispose();
  }

  void _refresh() {
    if (!mounted) return;
    setState(() => _orders = widget.load());
  }

  void _advance(String uuid, KitchenStatus status) {
    widget.onStatus(uuid, status);
    _refresh();
  }

  /// How many columns the board shows at this width. A single narrow kitchen
  /// tablet gets one wide column; a big pass-through monitor gets four, so
  /// tickets stay large and touch-friendly at every screen size.
  static int _columnsFor(double width) {
    if (width < 700) return 1;
    if (width < 1100) return 2;
    if (width < 1500) return 3;
    return 4;
  }

  String get _clockText {
    final local = _now.toLocal();
    final hh = local.hour.toString().padLeft(2, '0');
    final mm = local.minute.toString().padLeft(2, '0');
    final ss = local.second.toString().padLeft(2, '0');
    return '$hh:$mm:$ss';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _kdsBackground,
      appBar: AppBar(
        backgroundColor: _kdsBackground,
        foregroundColor: Colors.white,
        title: Text(tr(context, 'Kitchen')),
        actions: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 14),
            child: Center(
              child: Text(
                _clockText,
                key: const Key('kds-clock'),
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          IconButton(
            key: const Key('kds-refresh'),
            onPressed: _refresh,
            icon: const Icon(Icons.refresh),
            tooltip: tr(context, 'Refresh'),
          ),
        ],
      ),
      body: Container(
        color: _kdsBackground,
        child: _orders.isEmpty
            ? EmptyState(
                icon: Icons.soup_kitchen_outlined,
                title: tr(context, 'No active tickets'),
                message: tr(context, 'Orders sent to the kitchen will show up here'),
                iconColor: Colors.white38,
                textColor: Colors.white70,
              )
            : LayoutBuilder(
                builder: (context, constraints) {
                  final columns = _columnsFor(constraints.maxWidth);
                  return GridView.builder(
                    key: const Key('kds-grid'),
                    padding: const EdgeInsets.all(12),
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: columns,
                      crossAxisSpacing: 12,
                      mainAxisSpacing: 12,
                      mainAxisExtent: 400,
                    ),
                    itemCount: _orders.length,
                    itemBuilder: (context, index) {
                      final order = _orders[index];
                      return _TicketCard(
                        key: Key('kds-${order.uuid}'),
                        order: order,
                        now: _now,
                        onAdvance: _advance,
                      );
                    },
                  );
                },
              ),
      ),
    );
  }
}

class _TicketCard extends StatelessWidget {
  const _TicketCard({
    super.key,
    required this.order,
    required this.now,
    required this.onAdvance,
  });

  final Order order;
  final DateTime now;
  final void Function(String uuid, KitchenStatus status) onAdvance;

  Color get _statusColor => switch (order.kitchenStatus) {
        KitchenStatus.pending => AppColors.info,
        KitchenStatus.preparing => AppColors.warning,
        KitchenStatus.ready => AppColors.success,
        // Served tickets fall off the active board (the caller's load()
        // excludes them), but the colour is defined for completeness.
        KitchenStatus.served => Colors.grey,
      };

  IconData get _statusIcon => switch (order.kitchenStatus) {
        KitchenStatus.pending => Icons.fiber_new,
        KitchenStatus.preparing => Icons.local_fire_department,
        KitchenStatus.ready => Icons.check_circle,
        KitchenStatus.served => Icons.done_all,
      };

  IconData get _typeIcon => switch (order.type) {
        OrderType.dineIn => Icons.table_restaurant,
        OrderType.takeaway => Icons.shopping_bag,
        OrderType.delivery => Icons.delivery_dining,
      };

  String _title(BuildContext context) {
    final table = order.tableLabel;
    final type = tr(context, order.type.label);
    return table != null ? '$table · $type' : type;
  }

  /// How long the ticket has waited, as a live [Duration] against [now] (which
  /// ticks every second), so a cook can work oldest-first without doing the
  /// subtraction themselves.
  Duration get _age => now.difference(order.createdAt);

  /// Colour by how long the ticket has waited, independent of status, so an SLA
  /// breach is obvious: green fresh, amber getting old, red overdue.
  Color get _slaColor {
    final m = _age.inMinutes;
    if (m >= 10) return AppColors.error;
    if (m >= 5) return AppColors.warning;
    return AppColors.success;
  }

  /// The live elapsed timer as MM:SS, ticking every second.
  String get _elapsed {
    final seconds = _age.inSeconds.clamp(0, 24 * 60 * 60);
    final mm = (seconds ~/ 60).toString().padLeft(2, '0');
    final ss = (seconds % 60).toString().padLeft(2, '0');
    return '$mm:$ss';
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      color: _kdsCardSurface,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: _slaColor, width: 3),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
            child: Row(
              children: [
                Expanded(
                  child: Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(
                        _title(context),
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
                      StatusChip(tr(context, order.kitchenStatus.label), _statusColor,
                          icon: _statusIcon),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                // Live per-card timer, coloured by the same SLA thresholds as the
                // card border, so the number and the border always agree.
                Container(
                  key: Key('kds-${order.uuid}-timer'),
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: _slaColor,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.timer, size: 14, color: Colors.white),
                      const SizedBox(width: 4),
                      Text(
                        _elapsed,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                          fontFeatures: [FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Icon(_typeIcon, size: 16, color: Colors.white54),
          ),
          const Divider(height: 12, color: Colors.white24),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final line in order.lines) _lineTile(line),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: _actions(context),
            ),
          ),
        ],
      ),
    );
  }

  Widget _quantityBadge(double quantity) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: AppColors.primary,
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(
          '${quantity.toStringAsFixed(quantity == quantity.roundToDouble() ? 0 : 3)}x',
          style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),
        ),
      );

  Widget _lineTile(OrderLine line) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _quantityBadge(line.quantity),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    line.name,
                    style: const TextStyle(
                        color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
            for (final m in line.modifiers)
              Padding(
                padding: const EdgeInsets.only(left: 32, top: 2),
                child: Text(
                  '+ ${m.quantity.toStringAsFixed(
                    m.quantity == m.quantity.roundToDouble() ? 0 : 3,
                  )} x ${m.name}',
                  style: const TextStyle(fontSize: 12, color: Colors.white60),
                ),
              ),
            if (line.note != null)
              Padding(
                padding: const EdgeInsets.only(left: 32, top: 2),
                child: Text(
                  line.note!,
                  style: const TextStyle(
                      fontSize: 12, fontWeight: FontWeight.bold, color: AppColors.warning),
                ),
              ),
          ],
        ),
      );

  // Only the next sensible move is offered: a ticket that has not started
  // cannot be marked Served, and one already served has nothing further to do.
  List<Widget> _actions(BuildContext context) {
    switch (order.kitchenStatus) {
      case KitchenStatus.pending:
        return [
          FilledButton(
            key: Key('kds-${order.uuid}-start'),
            style: FilledButton.styleFrom(
                minimumSize: const Size(0, 44), backgroundColor: AppColors.info),
            onPressed: () => onAdvance(order.uuid, KitchenStatus.preparing),
            child: Text(tr(context, 'Start')),
          ),
        ];
      case KitchenStatus.preparing:
        return [
          FilledButton(
            key: Key('kds-${order.uuid}-ready'),
            style: FilledButton.styleFrom(
                minimumSize: const Size(0, 44), backgroundColor: AppColors.warning),
            onPressed: () => onAdvance(order.uuid, KitchenStatus.ready),
            child: Text(tr(context, 'Ready')),
          ),
        ];
      case KitchenStatus.ready:
        return [
          FilledButton(
            key: Key('kds-${order.uuid}-served'),
            style: FilledButton.styleFrom(
                minimumSize: const Size(0, 44), backgroundColor: AppColors.success),
            onPressed: () => onAdvance(order.uuid, KitchenStatus.served),
            child: Text(tr(context, 'Served')),
          ),
        ];
      case KitchenStatus.served:
        return const [];
    }
  }
}
