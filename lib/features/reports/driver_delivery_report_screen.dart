import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/i18n/l10n.dart';
import '../../core/theme/app_colors.dart';
import '../../core/widgets/feedback.dart';
import '../../domain/delivery.dart';
import '../../domain/order.dart';
import 'driver_sales_analysis.dart';
import 'report_export.dart';
import 'rm/thermal_report.dart';
import 'rm/thermal_report_preview_screen.dart';

class _DriverAgg {
  _DriverAgg(this.driverId, this.driverName);
  final String driverId;
  final String driverName;
  final List<Order> orders = [];

  int get orderCount => orders.length;
  double get total => orders.fold(0.0, (s, o) => s + o.total);
  double get delivery => orders.fold(0.0, (s, o) => s + o.deliveryCost);
  double get net => total - delivery;
}

/// حساب الطيار: pick a driver (or all), then see the same table layout as other
/// reports. Stays interactive so the picker can change the page without fighting
/// [ReportWindow]'s one-shot table announce.
class DriverDeliveryReportScreen extends StatefulWidget {
  const DriverDeliveryReportScreen({
    super.key,
    required this.orders,
    required this.drivers,
    required this.formatAmount,
    this.onPrint,
  });

  final List<Order> orders;
  final List<Driver> drivers;
  final String Function(double) formatAmount;

  /// Sends the visible table to the receipt printer. Null hides Print.
  final Future<void> Function(ThermalReport report)? onPrint;

  @override
  State<DriverDeliveryReportScreen> createState() =>
      _DriverDeliveryReportScreenState();
}

class _DriverDeliveryReportScreenState
    extends State<DriverDeliveryReportScreen> {
  /// `null` = not chosen yet; `''` = every driver; otherwise a driver id.
  String? _driverId;

  List<Order> get _deliveryRows => widget.orders
      .where((o) =>
          o.type.isDelivery &&
          (o.state == OrderState.paid ||
              o.state == OrderState.synced ||
              o.state == OrderState.held))
      .where((o) =>
          (o.driverId != null && o.driverId!.trim().isNotEmpty) ||
          (o.driverName != null && o.driverName!.trim().isNotEmpty))
      .toList();

  List<_DriverAgg> _allGroups() {
    final byKey = <String, _DriverAgg>{};
    for (final o in _deliveryRows) {
      final known = widget.drivers.where((d) =>
          orderBelongsToDriver(o, driverId: d.id, driverName: d.name));
      final d = known.firstOrNull;
      final key = d?.id ??
          (o.driverId?.trim().isNotEmpty == true
              ? o.driverId!.trim()
              : 'name:${(o.driverName ?? '').trim().toLowerCase()}');
      final name = d?.name ??
          ((o.driverName ?? '').trim().isEmpty
              ? key
              : o.driverName!.trim());
      byKey.putIfAbsent(key, () => _DriverAgg(key, name)).orders.add(o);
    }
    final list = byKey.values.toList()
      ..sort((a, b) => b.total.compareTo(a.total));
    return list;
  }

  List<_DriverAgg> get _groups {
    final all = _allGroups();
    final id = _driverId;
    if (id == null) return const [];
    if (id.isEmpty) return all;
    final picked = widget.drivers.where((d) => d.id == id).firstOrNull;
    return [
      for (final g in all)
        if (g.driverId == id ||
            (picked != null &&
                g.driverName.toLowerCase() ==
                    picked.name.trim().toLowerCase()))
          g,
    ];
  }

  List<Driver> get _pickerDrivers {
    final withSales = {for (final g in _allGroups()) g.driverId};
    return [
      for (final d in widget.drivers)
        if (d.active ||
            withSales.contains(d.id) ||
            withSales.any((k) =>
                k == 'name:${d.name.trim().toLowerCase()}'))
          d,
    ];
  }

  ReportTable _table() {
    final groups = _groups;
    final detailOrders = groups.expand((g) => g.orders).toList();
    return ReportTable(
      header: const [
        'Driver',
        'Orders / Check',
        'Total',
        'Delivery',
        'Net',
        'Customer',
      ],
      rows: [
        for (final g in groups)
          [
            g.driverName,
            '${g.orderCount}',
            g.total.toStringAsFixed(2),
            g.delivery.toStringAsFixed(2),
            g.net.toStringAsFixed(2),
            '',
          ],
        if (groups.isNotEmpty) ...[
          [
            'Total',
            '${detailOrders.length}',
            detailOrders.fold(0.0, (s, o) => s + o.total).toStringAsFixed(2),
            detailOrders
                .fold(0.0, (s, o) => s + o.deliveryCost)
                .toStringAsFixed(2),
            detailOrders
                .fold(0.0, (s, o) => s + (o.total - o.deliveryCost))
                .toStringAsFixed(2),
            '',
          ],
          const ['—', '—', '—', '—', '—', '—'],
          for (final g in groups)
            for (final o in g.orders)
              [
                g.driverName,
                '#${o.displayNo}',
                o.total.toStringAsFixed(2),
                o.deliveryCost.toStringAsFixed(2),
                (o.total - o.deliveryCost).toStringAsFixed(2),
                o.customerName ?? '',
              ],
        ],
      ],
    );
  }

  String _filterWords(BuildContext context) {
    final id = _driverId;
    if (id == null) return '';
    if (id.isEmpty) return tr(context, 'All drivers');
    final name =
        widget.drivers.where((d) => d.id == id).map((d) => d.name).firstOrNull;
    return '${tr(context, 'Driver')}: ${name ?? id}';
  }

  void _openPrintPreview(BuildContext context) {
    final printFn = widget.onPrint;
    if (printFn == null || _driverId == null) return;
    final table = _table();
    final scope = ReportScope.of(context);
    final report = ThermalReport(
      title: tr(context, 'Driver account'),
      period: scope?.periodLabel ?? '',
      filter: _filterWords(context),
      header: table.header,
      rows: table.rows,
      dateLabel: tr(context, 'Date/time'),
      filterLabel: tr(context, 'Report filter'),
    );
    unawaited(Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => ThermalReportPreviewScreen(
        report: report,
        shopName: scope?.shopName ?? '',
        onPrint: printFn,
      ),
    )));
  }

  /// Download without announcing to [ReportWindow] (keeps the picker on screen).
  Widget _exportMenu(BuildContext context) {
    return PopupMenuButton<String>(
      key: const Key('report-export'),
      tooltip: tr(context, 'Download'),
      icon: const Icon(Icons.download),
      onSelected: (format) => downloadReport(
        context,
        name: 'report-driver-account',
        title: tr(context, 'Driver account'),
        table: _table(),
        format: format,
      ),
      itemBuilder: (ctx) => [
        PopupMenuItem(
          key: const Key('export-xlsx'),
          value: 'xlsx',
          child: Text(tr(ctx, 'Excel')),
        ),
        PopupMenuItem(
          key: const Key('export-pdf'),
          value: 'pdf',
          child: Text(tr(ctx, 'PDF')),
        ),
        PopupMenuItem(
          key: const Key('export-csv'),
          value: 'csv',
          child: Text(tr(ctx, 'CSV')),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final groups = _groups;
    final money = widget.formatAmount;
    final scope = ReportScope.of(context);
    final detailOrders = groups.expand((g) => g.orders).toList();

    return Scaffold(
      key: const Key('driver-delivery-report'),
      appBar: AppBar(
        title: Text(tr(context, 'Driver account')),
        actions: [
          if (_driverId != null && widget.onPrint != null)
            IconButton(
              key: const Key('driver-account-print'),
              tooltip: tr(context, 'Print'),
              icon: const Icon(Icons.print),
              onPressed: () => _openPrintPreview(context),
            ),
          if (_driverId != null) _exportMenu(context),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (scope != null && scope.periodLabel.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Text(
                '${tr(context, 'Period')}: ${scope.periodLabel}',
                style: const TextStyle(
                  fontWeight: FontWeight.w600,
                  color: AppColors.textMutedLight,
                ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: DropdownButtonFormField<String?>(
              key: Key('driver-report-picker-${_driverId ?? 'none'}'),
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
                DropdownMenuItem<String?>(
                  value: '',
                  child: Text(tr(context, 'All drivers')),
                ),
                for (final d in _pickerDrivers)
                  DropdownMenuItem<String?>(
                    value: d.id,
                    child: Text(d.name),
                  ),
              ],
              onChanged: (v) => setState(() => _driverId = v),
            ),
          ),
          Expanded(
            child: _driverId == null
                ? Center(child: Text(tr(context, 'Pick a driver')))
                : groups.isEmpty
                    ? EmptyState(
                        icon: Icons.delivery_dining,
                        title: tr(context, 'No deliveries for this driver'),
                        message: tr(context,
                            'Assign a driver on delivery orders in this period.'),
                      )
                    : SingleChildScrollView(
                        padding: const EdgeInsets.all(16),
                        child: Card(
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(children: [
                                  _kpi(tr(context, 'Orders'),
                                      '${detailOrders.length}', AppColors.info),
                                  _kpi(
                                      tr(context, 'Total'),
                                      money(detailOrders.fold(
                                          0.0, (s, o) => s + o.total)),
                                      AppColors.brandNavy),
                                  _kpi(
                                      tr(context, 'Delivery'),
                                      money(detailOrders.fold(
                                          0.0, (s, o) => s + o.deliveryCost)),
                                      AppColors.primary),
                                  _kpi(
                                      tr(context, 'Net'),
                                      money(detailOrders.fold(
                                          0.0,
                                          (s, o) =>
                                              s +
                                              (o.total - o.deliveryCost))),
                                      AppColors.success),
                                ]),
                                const SizedBox(height: 16),
                                Row(children: [
                                  _h(tr(context, 'Driver')),
                                  _h(tr(context, 'Orders')),
                                  _h(tr(context, 'Total')),
                                  _h(tr(context, 'Delivery')),
                                  _h(tr(context, 'Net')),
                                ]),
                                const Divider(),
                                for (final g in groups)
                                  Padding(
                                    key: Key('driver-account-row-${g.driverId}'),
                                    padding:
                                        const EdgeInsets.symmetric(vertical: 8),
                                    child: Row(children: [
                                      _c(g.driverName),
                                      _c('${g.orderCount}'),
                                      _c(money(g.total)),
                                      _c(money(g.delivery)),
                                      _c(money(g.net)),
                                    ]),
                                  ),
                                const Divider(),
                                Row(
                                  key: const Key('driver-account-total-row'),
                                  children: [
                                    _c(tr(context, 'Total'), bold: true),
                                    _c('${detailOrders.length}', bold: true),
                                    _c(
                                        money(detailOrders.fold(
                                            0.0, (s, o) => s + o.total)),
                                        bold: true),
                                    _c(
                                        money(detailOrders.fold(
                                            0.0, (s, o) => s + o.deliveryCost)),
                                        bold: true),
                                    _c(
                                        money(detailOrders.fold(
                                            0.0,
                                            (s, o) =>
                                                s +
                                                (o.total - o.deliveryCost))),
                                        bold: true),
                                  ],
                                ),
                                const SizedBox(height: 20),
                                Text(
                                  tr(context, 'Orders'),
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w800),
                                ),
                                const Divider(),
                                for (final g in groups)
                                  for (final o in g.orders)
                                    Padding(
                                      key: Key(
                                          'driver-account-order-${o.uuid}'),
                                      padding: const EdgeInsets.symmetric(
                                          vertical: 6),
                                      child: Row(children: [
                                        _c(g.driverName),
                                        _c('#${o.displayNo}'),
                                        _c(o.customerName ?? '—'),
                                        _c(money(o.total)),
                                        _c(money(o.deliveryCost)),
                                      ]),
                                    ),
                              ],
                            ),
                          ),
                        ),
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
            padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
            child: Column(
              children: [
                Text(label,
                    textAlign: TextAlign.center,
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

  Widget _h(String text) => Expanded(
        child: Text(text, style: const TextStyle(fontWeight: FontWeight.bold)),
      );

  Widget _c(String text, {bool bold = false}) => Expanded(
        child: Text(
          text,
          style:
              TextStyle(fontWeight: bold ? FontWeight.bold : FontWeight.normal),
        ),
      );
}
