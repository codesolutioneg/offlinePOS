import 'package:flutter/material.dart';

import '../../core/i18n/l10n.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/dishflow_brand.dart';
import '../../domain/order.dart';
import '../tables/floor_action_bar.dart';

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
  });

  final List<OrderType> types;

  /// Parked delivery bags on this till, any kind.
  final List<Order> parked;
  final String Function(double) formatAmount;
  final void Function(OrderType type) onOpenType;
  final void Function(Order order) onResume;
  final List<FloorAction> actions;

  /// Asked before anything that starts or resumes an order; false refuses it.
  final bool Function()? guard;
  final String? cashierName;
  final VoidCallback? onBack;

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
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 16, 0),
              child: Row(children: [
                if (onBack != null)
                  TextButton.icon(
                    key: const Key('delivery-home-back'),
                    onPressed: onBack,
                    icon: const Icon(Icons.arrow_back),
                    label: Text(tr(context, 'Tables')),
                    style: TextButton.styleFrom(
                      foregroundColor: AppColors.brandNavy,
                      textStyle: const TextStyle(
                          fontWeight: FontWeight.w700, fontSize: 15),
                    ),
                  )
                else
                  const Padding(
                    padding: EdgeInsets.only(left: 8),
                    child: DishflowBrandMark(height: 32),
                  ),
                const Spacer(),
                if (cashierName != null)
                  Chip(
                    avatar: const Icon(Icons.person, size: 18),
                    label: Text(cashierName!),
                  ),
              ]),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
              child: Text(
                tr(context, 'Delivery'),
                style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 22,
                    color: AppColors.brandNavy),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Wrap(spacing: 12, runSpacing: 12, children: [
                for (final t in types) _typeTile(context, t, waiting),
              ]),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
              child: Text(
                '${tr(context, 'Deliveries waiting')} (${waiting.length})',
                style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 16,
                    color: AppColors.brandNavy),
              ),
            ),
            Expanded(
              child: waiting.isEmpty
                  ? Center(
                      child: Text(
                        tr(context, 'No deliveries waiting.'),
                        style: const TextStyle(
                            fontSize: 15, color: AppColors.textMutedLight),
                      ),
                    )
                  : LayoutBuilder(builder: (ctx, box) {
                      const gap = 12.0;
                      final cols =
                          ((box.maxWidth + gap) / (220 + gap)).floor().clamp(1, 6);
                      return GridView.builder(
                        padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                        gridDelegate:
                            SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: cols,
                          mainAxisSpacing: gap,
                          crossAxisSpacing: gap,
                          mainAxisExtent: 128,
                        ),
                        itemCount: waiting.length,
                        itemBuilder: (ctx, i) => _card(ctx, waiting[i]),
                      );
                    }),
            ),
          ],
        ),
      ),
    );
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
          child: Stack(children: [
            Center(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Icon(iconOf(t), color: Colors.white, size: 40),
                const SizedBox(height: 8),
                Text(
                  tr(context, t.label),
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w800,
                      fontSize: 15),
                ),
              ]),
            ),
            if (count > 0)
              PositionedDirectional(
                top: 8,
                end: 8,
                child: CircleAvatar(
                  radius: 13,
                  backgroundColor: Colors.white,
                  child: Text('$count',
                      style: TextStyle(
                          color: colorOf(t),
                          fontWeight: FontWeight.w800,
                          fontSize: 13)),
                ),
              ),
          ]),
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
              Row(children: [
                Icon(iconOf(o.type), color: color, size: 22),
                const SizedBox(width: 6),
                Text('#${o.displayNo}',
                    style: const TextStyle(fontWeight: FontWeight.w800)),
                const Spacer(),
                Text(formatAmount(o.total),
                    style: TextStyle(
                        fontWeight: FontWeight.w800, color: color)),
              ]),
              const SizedBox(height: 6),
              Text(
                o.customerName ?? o.customerPhone ?? tr(context, o.type.label),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontWeight: FontWeight.w700, color: AppColors.brandNavy),
              ),
              if (o.customerAddress != null)
                Text(o.customerAddress!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 12, color: AppColors.textMutedLight)),
              const Spacer(),
              Row(children: [
                Flexible(
                  child: Text(
                    tr(context, o.deliveryStatus.label),
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: color),
                  ),
                ),
                if (o.driverName != null) ...[
                  const Text('  ·  ', style: TextStyle(fontSize: 12)),
                  const Icon(Icons.two_wheeler, size: 14),
                  const SizedBox(width: 3),
                  Flexible(
                    child: Text(o.driverName!,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12)),
                  ),
                ],
              ]),
            ],
          ),
        ),
      ),
    );
  }
}
