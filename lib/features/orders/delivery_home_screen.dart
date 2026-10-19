import 'package:flutter/material.dart';

import '../../core/i18n/l10n.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/dishflow_brand.dart';
import '../../domain/delivery.dart';
import '../../domain/order.dart';
import '../../domain/delivery_bulletin.dart';
import '../tables/floor_action_bar.dart';
import '../tables/floor_bulletin_panel.dart';

/// The delivery station's own home: a big button per delivery kind the role may
/// ring, every bag waiting on this till, and the station's bottom bar.
///
/// It is home for a role that rings deliveries only, and a screen of its own the
/// floor's Delivery tile opens for everyone else ([onBack] takes them back).
class DeliveryHomeScreen extends StatelessWidget {
  const DeliveryHomeScreen({
    super.key,
    required this.types,
    required this.parked,
    required this.formatAmount,
    required this.onOpenType,
    required this.onResume,
    this.actions = const [],
    this.guard,
    this.cashierName,
    this.onBack,
    this.bulletin,
    this.ownDeviceId,
    this.onShiftOrders,
    this.drivers = const [],
    this.onAssignDriver,
  });

  /// Opens this shift's paid deliveries. Null hides the button.
  final VoidCallback? onShiftOrders;

  final List<OrderType> types;

  /// Parked delivery bags in the shop, any kind, this till's and other tills'.
  final List<Order> parked;

  /// This till; a bag rung anywhere else is marked as on another device.
  final String? ownDeviceId;
  final String Function(double) formatAmount;
  final void Function(OrderType type) onOpenType;
  final void Function(Order order) onResume;
  final List<FloorAction> actions;

  /// Asked before anything that starts or resumes an order; false refuses it.
  final bool Function()? guard;
  final String? cashierName;
  final VoidCallback? onBack;

  /// The shop's delivery numbers for the Bulletin board; null draws no board.
  final DeliveryBulletin? bulletin;

  /// Active drivers for the assign sheet on each waiting card.
  final List<Driver> drivers;

  /// Assign / clear a driver without opening the bag. Null hides the control.
  final void Function(Order order, Driver? driver)? onAssignDriver;

  static const List<BulletinRow> bulletinRows = [
    (
      id: 'waiting',
      label: 'Deliveries waiting',
      icon: Icons.inventory_2_outlined,
      color: Color(0xFFE67E22),
    ),
    (
      id: 'company',
      label: 'Delivery from company',
      icon: Icons.delivery_dining,
      color: Color(0xFF8E44AD),
    ),
    (
      id: 'store',
      label: 'Store delivery',
      icon: Icons.storefront,
      color: Color(0xFF16A085),
    ),
    (
      id: 'car',
      label: 'Car delivery',
      icon: Icons.directions_car,
      color: Color(0xFF2980B9),
    ),
    (
      id: 'no-driver',
      label: 'No driver yet',
      icon: Icons.person_off_outlined,
      color: Color(0xFFC0392B),
    ),
    (
      id: 'on-the-way',
      label: 'On the way',
      icon: Icons.two_wheeler,
      color: Color(0xFFD35400),
    ),
    (
      id: 'waiting-amount',
      label: 'Waiting total',
      icon: Icons.account_balance_wallet_outlined,
      color: Color(0xFF6D4C41),
    ),
    (
      id: 'closed',
      label: 'Deliveries closed today',
      icon: Icons.check_circle_outline,
      color: Color(0xFF27AE60),
    ),
    (
      id: 'sales',
      label: 'Delivery sales today',
      icon: Icons.payments_outlined,
      color: Color(0xFF1565C0),
    ),
  ];

  static IconData iconOf(OrderType t) => switch (t) {
    OrderType.deliveryFromCompany => Icons.delivery_dining,
    OrderType.storeDelivery => Icons.storefront,
    OrderType.carDelivery => Icons.directions_car,
    _ => Icons.local_shipping,
  };

  static Color colorOf(OrderType t) => switch (t) {
    OrderType.deliveryFromCompany => const Color(0xFF8E44AD),
    OrderType.storeDelivery => const Color(0xFF16A085),
    OrderType.carDelivery => const Color(0xFF2980B9),
    _ => const Color(0xFFE91E63),
  };

  bool _allowed() => guard?.call() ?? true;

  @override
  Widget build(BuildContext context) {
    final waiting = [...parked]
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return Scaffold(
      key: const Key('delivery-home'),
      backgroundColor: AppColors.backgroundLight,
      bottomNavigationBar: actions.isEmpty
          ? null
          : FloorActionBar(
              actions: actions,
              keyPrefix: 'delivery-action',
              barKey: const Key('delivery-action-bar'),
            ),
      body: SafeArea(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: _main(context, waiting)),
            if (bulletin != null)
              FloorBulletinPanel.custom(
                key: const Key('delivery-bulletin'),
                rows: bulletinRows,
                values: bulletin!.values(formatAmount),
              ),
          ],
        ),
      ),
    );
  }

  Widget _main(BuildContext context, List<Order> waiting) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(8, 8, 16, 0),
        child: Row(
          children: [
            if (onBack != null)
              TextButton.icon(
                key: const Key('delivery-home-back'),
                onPressed: onBack,
                icon: const Icon(Icons.arrow_back),
                label: Text(tr(context, 'Tables')),
                style: TextButton.styleFrom(
                  foregroundColor: AppColors.brandNavy,
                  textStyle: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 15,
                  ),
                ),
              )
            else
              const Padding(
                padding: EdgeInsets.only(left: 8),
                child: DishflowBrandMark(height: 32),
              ),
            const Spacer(),
            if (onShiftOrders != null) ...[
              Flexible(
                child: OutlinedButton.icon(
                  key: const Key('delivery-home-shift-orders'),
                  onPressed: onShiftOrders,
                  icon: const Icon(Icons.receipt_long_outlined, size: 18),
                  label: Text(tr(context, 'Shift orders'),
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.brandNavy,
                    textStyle: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
              ),
              const SizedBox(width: 8),
            ],
            if (cashierName != null)
              Flexible(
                child: Chip(
                  avatar: const Icon(Icons.person, size: 18),
                  label: Text(cashierName!,
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                ),
              ),
          ],
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
        child: Text(
          tr(context, 'Delivery'),
          style: const TextStyle(
            fontWeight: FontWeight.w800,
            fontSize: 22,
            color: AppColors.brandNavy,
          ),
        ),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [for (final t in types) _typeTile(context, t, waiting)],
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
        child: Text(
          '${tr(context, 'Deliveries waiting')} (${waiting.length})',
          style: const TextStyle(
            fontWeight: FontWeight.w800,
            fontSize: 16,
            color: AppColors.brandNavy,
          ),
        ),
      ),
      Expanded(
        child: waiting.isEmpty
            ? Center(
                child: Text(
                  tr(context, 'No deliveries waiting.'),
                  style: const TextStyle(
                    fontSize: 15,
                    color: AppColors.textMutedLight,
                  ),
                ),
              )
            : LayoutBuilder(
                builder: (ctx, box) {
                  const gap = 12.0;
                  final cols = ((box.maxWidth + gap) / (220 + gap))
                      .floor()
                      .clamp(1, 6);
                  return GridView.builder(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: cols,
                      mainAxisSpacing: gap,
                      crossAxisSpacing: gap,
                      mainAxisExtent: onAssignDriver == null ? 128 : 152,
                    ),
                    itemCount: waiting.length,
                    itemBuilder: (ctx, i) => _card(ctx, waiting[i]),
                  );
                },
              ),
      ),
    ],
  );

  Future<void> _pickDriver(BuildContext context, Order o) async {
    final assign = onAssignDriver;
    if (assign == null) return;
    final active = drivers.where((d) => d.active).toList(growable: false);
    final chosen = await showDialog<Object?>(
      context: context,
      barrierColor: const Color(0x99000000),
      builder: (ctx) => _DriverPickDialog(drivers: active),
    );
    if (chosen == null) return;
    assign(o, chosen == 'clear' ? null : chosen as Driver);
  }

  Widget _typeTile(BuildContext context, OrderType t, List<Order> waiting) {
    final count = waiting.where((o) => o.type == t).length;
    return SizedBox(
      width: 200,
      height: 120,
      child: Material(
        color: colorOf(t),
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: Key('delivery-home-${t.name}'),
          onTap: () {
            if (_allowed()) onOpenType(t);
          },
          child: Stack(
            children: [
              Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(iconOf(t), color: Colors.white, size: 40),
                    const SizedBox(height: 8),
                    Text(
                      tr(context, t.label),
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w800,
                        fontSize: 15,
                      ),
                    ),
                  ],
                ),
              ),
              if (count > 0)
                PositionedDirectional(
                  top: 8,
                  end: 8,
                  child: CircleAvatar(
                    radius: 13,
                    backgroundColor: Colors.white,
                    child: Text(
                      '$count',
                      style: TextStyle(
                        color: colorOf(t),
                        fontWeight: FontWeight.w800,
                        fontSize: 13,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _card(BuildContext context, Order o) {
    final color = colorOf(o.type);
    return Material(
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: color.withValues(alpha: 0.5), width: 1.4),
      ),
      child: InkWell(
        key: Key('delivery-home-resume-${o.uuid}'),
        borderRadius: BorderRadius.circular(14),
        onTap: () {
          if (_allowed()) onResume(o);
        },
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(iconOf(o.type), color: color, size: 22),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '#${o.displayNo}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                  ),
                  if (ownDeviceId != null && o.deviceId != ownDeviceId)
                    Tooltip(
                      message: tr(context, 'Open on another device'),
                      child: Icon(
                        Icons.devices_other,
                        key: Key('delivery-home-elsewhere-${o.uuid}'),
                        size: 16,
                        color: AppColors.textMutedLight,
                      ),
                    ),
                  const SizedBox(width: 6),
                  Text(
                    formatAmount(o.total),
                    style: TextStyle(fontWeight: FontWeight.w800, color: color),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                o.customerName ?? o.customerPhone ?? tr(context, o.type.label),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  color: AppColors.brandNavy,
                ),
              ),
              if (o.customerAddress != null)
                Text(
                  o.customerAddress!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppColors.textMutedLight,
                  ),
                ),
              const Spacer(),
              Row(
                children: [
                  Flexible(
                    child: Text(
                      tr(context, o.deliveryStatus.label),
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: color,
                      ),
                    ),
                  ),
                  if (onAssignDriver == null && o.driverName != null) ...[
                    const Text('  ·  ', style: TextStyle(fontSize: 12)),
                    const Icon(Icons.two_wheeler, size: 14),
                    const SizedBox(width: 3),
                    Flexible(
                      child: Text(
                        o.driverName!,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                  ],
                ],
              ),
              if (onAssignDriver != null) ...[
                const SizedBox(height: 4),
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: TextButton.icon(
                    key: Key('delivery-home-assign-driver-${o.uuid}'),
                    onPressed: () => _pickDriver(context, o),
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      foregroundColor: AppColors.primary,
                      textStyle: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 12,
                      ),
                    ),
                    icon: Icon(
                      o.driverName == null
                          ? Icons.person_off_outlined
                          : Icons.two_wheeler,
                      size: 16,
                    ),
                    label: Text(
                      o.driverName ?? tr(context, 'Driver'),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Centered driver picker with name/phone search — used from delivery home.
class _DriverPickDialog extends StatefulWidget {
  const _DriverPickDialog({required this.drivers});

  final List<Driver> drivers;

  @override
  State<_DriverPickDialog> createState() => _DriverPickDialogState();
}

class _DriverPickDialogState extends State<_DriverPickDialog> {
  String _query = '';

  List<Driver> get _filtered {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return widget.drivers;
    return [
      for (final d in widget.drivers)
        if (d.name.toLowerCase().contains(q) ||
            (d.phone?.toLowerCase().contains(q) ?? false))
          d,
    ];
  }

  @override
  Widget build(BuildContext context) {
    final shown = _filtered;
    return Dialog(
      key: const Key('delivery-home-driver-dialog'),
      backgroundColor: Colors.white,
      elevation: 12,
      insetPadding: const EdgeInsets.symmetric(horizontal: 40, vertical: 40),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 480,
          maxHeight: MediaQuery.sizeOf(context).height * 0.75,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 12, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      tr(context, 'Driver'),
                      style: const TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 20,
                        color: AppColors.brandNavy,
                      ),
                    ),
                  ),
                  IconButton(
                    key: const Key('delivery-home-driver-dialog-close'),
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: TextField(
                key: const Key('delivery-home-driver-search'),
                autofocus: true,
                decoration: InputDecoration(
                  hintText: tr(context, 'Search name or phone'),
                  prefixIcon: const Icon(Icons.search),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  isDense: true,
                ),
                onChanged: (v) => setState(() => _query = v),
              ),
            ),
            const Divider(height: 1),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.symmetric(vertical: 8),
                children: [
                  if (widget.drivers.isEmpty)
                    ListTile(
                      key: const Key('delivery-home-no-drivers'),
                      title: Text(
                          tr(context, 'No drivers yet. Add them in Settings.')),
                    )
                  else if (shown.isEmpty)
                    ListTile(
                      key: const Key('delivery-home-driver-search-empty'),
                      title: Text(tr(context, 'No matching drivers')),
                    )
                  else
                    for (final d in shown)
                      ListTile(
                        key: Key('delivery-home-driver-${d.id}'),
                        leading: const Icon(Icons.delivery_dining,
                            color: AppColors.primary),
                        title: Text(d.name,
                            style:
                                const TextStyle(fontWeight: FontWeight.w700)),
                        subtitle: d.phone == null ? null : Text(d.phone!),
                        onTap: () => Navigator.pop(context, d),
                      ),
                  ListTile(
                    key: const Key('delivery-home-driver-clear'),
                    leading: const Icon(Icons.person_off_outlined),
                    title: Text(tr(context, 'No driver yet')),
                    onTap: () => Navigator.pop(context, 'clear'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
