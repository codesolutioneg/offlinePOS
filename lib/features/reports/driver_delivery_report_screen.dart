import 'package:flutter/material.dart';

import '../../core/i18n/l10n.dart';
import '../../core/theme/app_colors.dart';
import '../../domain/delivery.dart';
import '../../domain/order.dart';

/// Dishflow «حساب الطيار»: orders | total | delivery fees | net (total − delivery).
class DriverDeliveryReportScreen extends StatefulWidget {
  const DriverDeliveryReportScreen({
    super.key,
    required this.orders,
    required this.drivers,
    required this.formatAmount,
  });

  final List<Order> orders;
  final List<Driver> drivers;
  final String Function(double) formatAmount;

  @override
  State<DriverDeliveryReportScreen> createState() =>
      _DriverDeliveryReportScreenState();
}

class _DriverDeliveryReportScreenState
    extends State<DriverDeliveryReportScreen> {
  String? _driverId;

  List<Order> get _deliveryPaid => widget.orders
      .where((o) =>
          o.type.isDelivery &&
          (o.state == OrderState.paid || o.state == OrderState.synced))
      .toList();

  List<Order> get _forDriver {
    final id = _driverId;
    if (id == null) return const [];
    return _deliveryPaid.where((o) => o.driverId == id).toList();
  }

  @override
  Widget build(BuildContext context) {
    final rows = _forDriver;
    final total = rows.fold<double>(0, (s, o) => s + o.total);
    final delivery = rows.fold<double>(0, (s, o) => s + o.deliveryCost);
    final net = total - delivery;
    final drivers = [
      for (final d in widget.drivers)
        if (_deliveryPaid.any((o) => o.driverId == d.id) || d.active) d,
    ];

    return Scaffold(
      key: const Key('driver-delivery-report'),
      appBar: AppBar(title: Text(tr(context, 'Driver account'))),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: DropdownButtonFormField<String?>(
              key: const Key('driver-report-picker'),
              initialValue: _driverId,
              decoration: InputDecoration(
                labelText: tr(context, 'Driver'),
                border: const OutlineInputBorder(),
              ),
              items: [
                DropdownMenuItem<String?>(
                  value: null,
                  child: Text(tr(context, 'Pick a driver')),
                ),
                for (final d in drivers)
                  DropdownMenuItem<String?>(
                    value: d.id,
                    child: Text(d.name),
                  ),
              ],
              onChanged: (v) => setState(() => _driverId = v),
            ),
          ),
          if (_driverId != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  _kpi(tr(context, 'Orders'), '${rows.length}', AppColors.info),
                  _kpi(tr(context, 'Total'), widget.formatAmount(total),
                      AppColors.brandNavy),
                  _kpi(tr(context, 'Delivery'), widget.formatAmount(delivery),
                      AppColors.primary),
                  _kpi(tr(context, 'Net'), widget.formatAmount(net),
                      AppColors.success),
                ],
              ),
            ),
          const Divider(height: 24),
          Expanded(
            child: _driverId == null
                ? Center(child: Text(tr(context, 'Pick a driver')))
                : rows.isEmpty
                    ? Center(
                        child: Text(tr(context, 'No deliveries for this driver')))
                    : ListView.separated(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                        itemCount: rows.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 8),
                        itemBuilder: (ctx, i) {
                          final o = rows[i];
                          return ListTile(
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                              side: const BorderSide(color: Color(0xFFE2E8F0)),
                            ),
                            title: Text(
                              o.customerName ?? '#${o.displayNo}',
                              style:
                                  const TextStyle(fontWeight: FontWeight.w700),
                            ),
                            subtitle: Text([
                              '#${o.displayNo}',
                              if (o.customerAddress != null) o.customerAddress!,
                              tr(ctx, o.deliveryStatus.label),
                            ].join('  ·  ')),
                            trailing: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                Text(widget.formatAmount(o.total),
                                    style: const TextStyle(
                                        fontWeight: FontWeight.w800)),
                                Text(
                                  '${tr(ctx, 'Delivery')} ${widget.formatAmount(o.deliveryCost)}',
                                  style: const TextStyle(
                                      fontSize: 12,
                                      color: AppColors.textMutedLight),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }

  Widget _kpi(String label, String value, Color color) => Expanded(
        child: Card(
          margin: const EdgeInsets.all(4),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
            child: Column(
              children: [
                Text(label,
                    style: const TextStyle(
                        fontSize: 11, color: AppColors.textMutedLight)),
                const SizedBox(height: 4),
                Text(value,
                    style: TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 14,
                        color: color)),
              ],
            ),
          ),
        ),
      );
}
