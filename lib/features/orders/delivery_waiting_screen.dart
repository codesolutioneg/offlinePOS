import 'package:flutter/material.dart';

import '../../core/i18n/l10n.dart';
import '../../core/theme/app_colors.dart';
import '../../domain/order.dart';

/// Full screen of parked deliveries for one Dishflow subtype.
///
/// Replaces the old bottom sheet: after the cashier picks Company / Store / Car,
/// they land here to resume a waiting bag or start a new one — same concept as
/// Dishflow's suspended-delivery panel on the floor.
class DeliveryWaitingScreen extends StatelessWidget {
  const DeliveryWaitingScreen({
    super.key,
    required this.type,
    required this.parked,
    required this.formatAmount,
  });

  final OrderType type;
  final List<Order> parked;
  final String Function(double) formatAmount;

  void _backToTables(BuildContext context) {
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final typeLabel = tr(context, type.label);
    return Scaffold(
      key: const Key('delivery-waiting-screen'),
      backgroundColor: AppColors.backgroundLight,
      // No AppBar: on Windows the themed bar often sits empty under the
      // caption. Back lives in the body so it is always visible.
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
                    onPressed: () => _backToTables(context),
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
                  : ListView.separated(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                      itemCount: parked.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 10),
                      itemBuilder: (ctx, i) {
                        final o = parked[i];
                        return Material(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(14),
                          child: InkWell(
                            key: Key('resume-delivery-${o.uuid}'),
                            borderRadius: BorderRadius.circular(14),
                            onTap: () => Navigator.pop(ctx, o),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 14, vertical: 14),
                              child: Row(
                                children: [
                                  Container(
                                    width: 44,
                                    height: 44,
                                    decoration: BoxDecoration(
                                      color: AppColors.primary
                                          .withValues(alpha: 0.12),
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    child: const Icon(Icons.delivery_dining,
                                        color: AppColors.primary),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          o.customerName ?? '#${o.displayNo}',
                                          style: const TextStyle(
                                            fontWeight: FontWeight.w700,
                                            fontSize: 15,
                                            color: AppColors.brandNavy,
                                          ),
                                        ),
                                        const SizedBox(height: 2),
                                        Text(
                                          [
                                            '#${o.displayNo}',
                                            if (o.customerPhone != null)
                                              o.customerPhone!,
                                            if (o.deliveryChannel != null)
                                              o.deliveryChannel!,
                                            if (o.companyOrderNo != null)
                                              '#${o.companyOrderNo}',
                                          ].join('  ·  '),
                                          style: const TextStyle(
                                            fontSize: 12.5,
                                            color: AppColors.textMutedLight,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  Text(
                                    formatAmount(o.total),
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w800,
                                      fontSize: 15,
                                      color: AppColors.brandNavy,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
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
}
