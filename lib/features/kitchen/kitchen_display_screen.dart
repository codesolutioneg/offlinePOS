import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/i18n/l10n.dart';
import '../../domain/order.dart';

/// A live board of active kitchen tickets, one card per order, that a cook
/// advances New -> Preparing -> Ready -> Served without touching the till.
///
/// [load] is polled on a timer rather than pushed: the kitchen has its own
/// device and the till that books the order may be several seconds away or
/// offline entirely, so the board must catch up on its own schedule instead
/// of waiting on a notification that might never arrive.
class KitchenDisplayScreen extends StatefulWidget {
  const KitchenDisplayScreen({super.key, required this.load, required this.onStatus});

  /// Returns the active tickets, newest first. Called on every poll and on
  /// manual refresh.
  final List<Order> Function() load;

  /// Advances [uuid] to [status]. The board reloads immediately after, so the
  /// caller does not need to return anything: the next [load] is the source
  /// of truth for what actually happened.
  final void Function(String uuid, KitchenStatus status) onStatus;

  @override
  State<KitchenDisplayScreen> createState() => _KitchenDisplayScreenState();
}

class _KitchenDisplayScreenState extends State<KitchenDisplayScreen> {
  Timer? _poll;
  late List<Order> _orders;

  @override
  void initState() {
    super.initState();
    _orders = widget.load();
    // A cook cannot be relied on to remember to tap refresh mid-service, so the
    // board keeps itself current even if nobody touches it.
    _poll = Timer.periodic(const Duration(seconds: 10), (_) => _refresh());
  }

  @override
  void dispose() {
    _poll?.cancel();
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(tr(context, 'Kitchen')),
        actions: [
          IconButton(
            key: const Key('kds-refresh'),
            onPressed: _refresh,
            icon: const Icon(Icons.refresh),
            tooltip: tr(context, 'Refresh'),
          ),
        ],
      ),
      body: _orders.isEmpty
          ? Center(child: Text(tr(context, 'No active tickets')))
          : SingleChildScrollView(
              padding: const EdgeInsets.all(12),
              child: Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  for (final order in _orders)
                    _TicketCard(
                      key: Key('kds-${order.uuid}'),
                      order: order,
                      onAdvance: _advance,
                    ),
                ],
              ),
            ),
    );
  }
}

class _TicketCard extends StatelessWidget {
  const _TicketCard({super.key, required this.order, required this.onAdvance});

  final Order order;
  final void Function(String uuid, KitchenStatus status) onAdvance;

  Color get _headerColor => switch (order.kitchenStatus) {
        KitchenStatus.pending => Colors.grey.shade300,
        KitchenStatus.preparing => Colors.amber.shade200,
        KitchenStatus.ready => Colors.green.shade200,
        // Served tickets fall off the active board (the caller's load()
        // excludes them), but the colour is defined for completeness.
        KitchenStatus.served => Colors.grey.shade200,
      };

  String get _time {
    final local = order.createdAt.toLocal();
    final hh = local.hour.toString().padLeft(2, '0');
    final mm = local.minute.toString().padLeft(2, '0');
    return '$hh:$mm';
  }

  String _title(BuildContext context) {
    final table = order.tableLabel;
    final type = tr(context, order.type.label);
    return table != null ? '$table · $type' : type;
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        width: 260,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: double.infinity,
              color: _headerColor,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(_title(context),
                        style: const TextStyle(fontWeight: FontWeight.bold)),
                  ),
                  Text(_time),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(tr(context, order.kitchenStatus.label),
                      style: const TextStyle(color: Colors.black54, fontSize: 12)),
                  const SizedBox(height: 8),
                  for (final line in order.lines) _lineTile(line),
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: _actions(context),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _lineTile(OrderLine line) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${line.quantity.toStringAsFixed(
              line.quantity == line.quantity.roundToDouble() ? 0 : 3,
            )} x ${line.name}'),
            for (final m in line.modifiers)
              Padding(
                padding: const EdgeInsets.only(left: 16),
                child: Text('+ ${m.quantity.toStringAsFixed(
                  m.quantity == m.quantity.roundToDouble() ? 0 : 3,
                )} x ${m.name}',
                    style: const TextStyle(fontSize: 12, color: Colors.black54)),
              ),
            if (line.note != null)
              Padding(
                padding: const EdgeInsets.only(left: 16),
                child: Text(line.note!,
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
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
            onPressed: () => onAdvance(order.uuid, KitchenStatus.preparing),
            child: Text(tr(context, 'Start')),
          ),
        ];
      case KitchenStatus.preparing:
        return [
          FilledButton(
            key: Key('kds-${order.uuid}-ready'),
            onPressed: () => onAdvance(order.uuid, KitchenStatus.ready),
            child: Text(tr(context, 'Ready')),
          ),
        ];
      case KitchenStatus.ready:
        return [
          FilledButton(
            key: Key('kds-${order.uuid}-served'),
            onPressed: () => onAdvance(order.uuid, KitchenStatus.served),
            child: Text(tr(context, 'Served')),
          ),
        ];
      case KitchenStatus.served:
        return const [];
    }
  }
}
