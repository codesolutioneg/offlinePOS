import 'package:flutter/material.dart';

import '../../core/i18n/l10n.dart';
import '../../core/theme/app_colors.dart';
import '../../domain/delivery.dart';
import '../../domain/order.dart';

/// Full screen of parked deliveries for one Dishflow subtype.
///
/// After the cashier picks Company / Store / Car they land here to resume a
/// waiting bag, assign a driver (حساب الطيار), update status, or start new.
class DeliveryWaitingScreen extends StatefulWidget {
  const DeliveryWaitingScreen({
    super.key,
    required this.type,
    required this.parked,
    required this.formatAmount,
    this.drivers = const [],
    this.onAssignDriver,
    this.onSetStatus,
  });

  final OrderType type;
  final List<Order> parked;
  final String Function(double) formatAmount;
  final List<Driver> drivers;
  final void Function(Order order, Driver? driver)? onAssignDriver;
  final void Function(Order order, DeliveryStatus status)? onSetStatus;

  @override
  State<DeliveryWaitingScreen> createState() => _DeliveryWaitingScreenState();
}

class _DeliveryWaitingScreenState extends State<DeliveryWaitingScreen> {
  void _backToTables() => Navigator.of(context).pop();

  @override
  Widget build(BuildContext context) {
    final typeLabel = tr(context, widget.type.label);
    final parked = widget.parked;
    return Scaffold(
      key: const Key('delivery-waiting-screen'),
      backgroundColor: AppColors.backgroundLight,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 16, 0),
              child: Row(
                children: [
                  TextButton.icon(
                    key: const Key('delivery-waiting-back'),
                    onPressed: _backToTables,
                    icon: const Icon(Icons.arrow_back),
                    label: Text(tr(context, 'Back')),
                    style: TextButton.styleFrom(
                      foregroundColor: AppColors.brandNavy,
                      textStyle: const TextStyle(
                          fontWeight: FontWeight.w700, fontSize: 15),
                    ),
                  ),
                  const Spacer(),
                  Text(
                    typeLabel,
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
                      color: AppColors.textMutedLight,
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    tr(context, 'Deliveries waiting'),
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 20,
                      color: AppColors.brandNavy,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    tr(context, 'Pick one up, or start a new order.'),
                    style: const TextStyle(
                      fontSize: 14,
                      color: AppColors.textMutedLight,
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: parked.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(32),
                        child: Text(
                          tr(context, 'No deliveries waiting for this type.'),
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontSize: 15,
                            color: AppColors.textMutedLight,
                          ),
                        ),
                      ),
                    )
                  : LayoutBuilder(
                      builder: (ctx, constraints) {
                        const gap = 12.0;
                        const minCard = 180.0;
                        final cols = ((constraints.maxWidth + gap) /
                                (minCard + gap))
                            .floor()
                            .clamp(2, 5);
                        return GridView.builder(
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                          gridDelegate:
                              SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: cols,
                            mainAxisSpacing: gap,
                            crossAxisSpacing: gap,
                            childAspectRatio: 0.82,
                          ),
                          itemCount: parked.length,
                          itemBuilder: (ctx, i) =>
                              _card(context, parked[i]),
                        );
                      },
                    ),
            ),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: SizedBox(
                  height: 48,
                  child: FilledButton.icon(
                    key: const Key('new-delivery'),
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.primary,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                    ),
                    onPressed: () => Navigator.pop(context, 'new'),
                    icon: const Icon(Icons.add),
                    label: Text(tr(context, 'New delivery')),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _card(BuildContext context, Order o) {
    final subtitle = [
      '#${o.displayNo}',
      if (o.customerPhone != null) o.customerPhone!,
      if (o.deliveryChannel != null) o.deliveryChannel!,
      if (o.companyOrderNo != null) '#${o.companyOrderNo}',
    ].join('  ·  ');
    final activeDrivers =
        widget.drivers.where((d) => d.active).toList(growable: false);
    return Material(
      color: Colors.white,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: Color(0xFFE2E8F0)),
      ),
      child: InkWell(
        key: Key('resume-delivery-${o.uuid}'),
        borderRadius: BorderRadius.circular(16),
        onTap: () => Navigator.pop(context, o),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: AppColors.primary.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(Icons.delivery_dining,
                        color: AppColors.primary, size: 22),
                  ),
                  const Spacer(),
                  Text(
                    widget.formatAmount(o.total),
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 15,
                      color: AppColors.primary,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                o.customerName ?? '#${o.displayNo}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 15,
                  color: AppColors.brandNavy,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                subtitle,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 11.5,
                  color: AppColors.textMutedLight,
                  height: 1.25,
                ),
              ),
              const Spacer(),
              if (widget.onAssignDriver != null && activeDrivers.isNotEmpty)
                DropdownButtonFormField<String?>(
                  key: Key('assign-driver-${o.uuid}-${o.driverId ?? 'none'}'),
                  initialValue: o.driverId,
                  isExpanded: true,
                  decoration: InputDecoration(
                    isDense: true,
                    labelText: tr(context, 'Driver'),
                    border: const OutlineInputBorder(),
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                  ),
                  items: [
                    DropdownMenuItem<String?>(
                      value: null,
                      child: Text(tr(context, 'No driver yet'),
                          overflow: TextOverflow.ellipsis),
                    ),
                    for (final d in activeDrivers)
                      DropdownMenuItem<String?>(
                        value: d.id,
                        child: Text(d.name, overflow: TextOverflow.ellipsis),
                      ),
                  ],
                  onChanged: (id) {
                    final d = id == null
                        ? null
                        : activeDrivers.where((x) => x.id == id).firstOrNull;
                    widget.onAssignDriver!(o, d);
                    setState(() {});
                  },
                ),
              if (widget.onSetStatus != null) ...[
                const SizedBox(height: 6),
                DropdownButtonFormField<DeliveryStatus>(
                  key: Key(
                      'delivery-status-${o.uuid}-${o.deliveryStatus.wireName}'),
                  initialValue: o.deliveryStatus,
                  isExpanded: true,
                  decoration: InputDecoration(
                    isDense: true,
                    labelText: tr(context, 'Status'),
                    border: const OutlineInputBorder(),
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                  ),
                  items: [
                    for (final st in DeliveryStatus.values)
                      DropdownMenuItem(
                        value: st,
                        child: Text(tr(context, st.label),
                            overflow: TextOverflow.ellipsis),
                      ),
                  ],
                  onChanged: (st) {
                    if (st == null) return;
                    widget.onSetStatus!(o, st);
                    setState(() {});
                  },
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
