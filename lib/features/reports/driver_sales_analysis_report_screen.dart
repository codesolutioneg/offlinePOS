import 'package:flutter/material.dart';

import '../../core/i18n/l10n.dart';
import '../../core/theme/app_colors.dart';
import '../../core/widgets/feedback.dart';
import '../../domain/catalogue.dart';
import '../../domain/delivery.dart';
import '../../domain/order.dart';
import 'driver_sales_analysis.dart';
import 'report_export.dart';

/// Dishflow-style Employee Sales Analysis for delivery drivers in the hub
/// period. Announces its table so [ReportWindow] draws it like every other report.
class DriverSalesAnalysisReportScreen extends StatelessWidget {
  const DriverSalesAnalysisReportScreen({
    super.key,
    required this.orders,
    required this.drivers,
    required this.categories,
    required this.formatAmount,
  });

  final List<Order> orders;
  /// Kept for hub wiring / future name resolution; totals read driver stamps
  /// off the orders themselves.
  final List<Driver> drivers;
  final List<Category> categories;
  final String Function(double) formatAmount;

  static String _qty(double q) =>
      q == q.roundToDouble() ? q.toStringAsFixed(0) : q.toStringAsFixed(2);

  static String _pct(double part, double whole) =>
      whole == 0 ? '0.0%' : '${(part / whole * 100).toStringAsFixed(1)}%';

  List<DriverSalesBlock> _blocks() =>
      driverSalesAnalysis(orders, categories);

  ReportTable _table(BuildContext context) {
    final blocks = _blocks();
    final rows = <List<String>>[];
    rows.add([
      tr(context, 'Summary'),
      '',
      '',
      '${driverAnalysisChecks(blocks)}',
      '${driverAnalysisCustomers(blocks)}',
      '',
      '',
      '',
      '',
    ]);
    for (final b in blocks) {
      rows.add([
        b.driverName,
        '',
        '',
        '${b.checks}',
        '${b.customers}',
        '',
        '',
        '',
        '',
      ]);
      var no = 0;
      for (final g in b.groups) {
        rows.add([
          '${++no}',
          g.groupName,
          g.sales.toStringAsFixed(2),
          _qty(g.qty),
          _pct(g.sales, b.totalSales),
          b.customers == 0
              ? '0.00'
              : (g.sales / b.customers).toStringAsFixed(2),
          g.qty == 0 ? '0.00' : (g.sales / g.qty).toStringAsFixed(2),
          b.customers == 0
              ? '0.00'
              : (g.qty / b.customers).toStringAsFixed(2),
          '',
        ]);
      }
      rows.add([
        tr(context, 'Total'),
        '',
        b.totalSales.toStringAsFixed(2),
        _qty(b.totalQty),
        '100.0%',
        b.salesPerCustomer.toStringAsFixed(2),
        b.avgItem.toStringAsFixed(2),
        b.qtyPerCustomer.toStringAsFixed(2),
        b.salesPerCheck.toStringAsFixed(2),
      ]);
    }
    return ReportTable(
      header: [
        tr(context, 'Driver'),
        tr(context, 'Group name'),
        tr(context, 'Sales'),
        tr(context, 'Quantity'),
        tr(context, 'Sales %'),
        tr(context, '\$/ Cust'),
        tr(context, 'Avg Item'),
        tr(context, 'Qty / Cust'),
        tr(context, '\$/ Check'),
      ],
      rows: rows,
    );
  }

  @override
  Widget build(BuildContext context) {
    final blocks = _blocks();
    final money = formatAmount;

    return Scaffold(
      key: const Key('driver-sales-analysis-report'),
      appBar: AppBar(
        title: Text(tr(context, 'Driver sales analysis')),
        actions: [
          reportExportAction(
            context,
            name: 'report-driver-sales',
            title: tr(context, 'Driver sales analysis'),
            table: () => _table(context),
          ),
        ],
      ),
      body: blocks.isEmpty
          ? EmptyState(
              icon: Icons.delivery_dining,
              title: tr(context, 'No deliveries for this driver'),
              message: tr(context,
                  'Assign a driver on delivery orders in this period.'),
            )
          : ListView(
              key: const Key('driver-sales-list'),
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
              children: [
                Row(
                  children: [
                    _kpi(tr(context, '# of checks'),
                        '${driverAnalysisChecks(blocks)}', AppColors.info),
                    _kpi(tr(context, 'Number of customers'),
                        '${driverAnalysisCustomers(blocks)}',
                        AppColors.brandNavy),
                    _kpi(
                        tr(context, 'Sales'),
                        money(blocks.fold(0.0, (s, b) => s + b.totalSales)),
                        AppColors.primary),
                  ],
                ),
                const SizedBox(height: 12),
                for (final b in blocks) _driverCard(context, b, money),
              ],
            ),
    );
  }

  Widget _driverCard(
      BuildContext context, DriverSalesBlock b, String Function(double) money) {
    return Card(
      key: Key('driver-sales-block-${b.driverId}'),
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: Color(0xFFE2E8F0)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              b.driverName,
              style: const TextStyle(
                fontWeight: FontWeight.w800,
                fontSize: 16,
                color: AppColors.brandNavy,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '${tr(context, '# of checks')}: ${b.checks}   ·   '
              '${tr(context, 'Number of customers')}: ${b.customers}',
              style: const TextStyle(
                fontSize: 13,
                color: AppColors.textMutedLight,
              ),
            ),
            const SizedBox(height: 10),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: DataTable(
                headingRowHeight: 36,
                dataRowMinHeight: 36,
                dataRowMaxHeight: 40,
                columnSpacing: 16,
                headingTextStyle: const TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 12,
                  color: AppColors.textMutedLight,
                ),
                columns: [
                  DataColumn(label: Text(tr(context, 'Group name'))),
                  DataColumn(label: Text(tr(context, 'Sales')), numeric: true),
                  DataColumn(
                      label: Text(tr(context, 'Quantity')), numeric: true),
                  DataColumn(label: Text(tr(context, 'Sales %')), numeric: true),
                  DataColumn(
                      label: Text(tr(context, '\$/ Cust')), numeric: true),
                  DataColumn(
                      label: Text(tr(context, 'Avg Item')), numeric: true),
                  DataColumn(
                      label: Text(tr(context, 'Qty / Cust')), numeric: true),
                  DataColumn(
                      label: Text(tr(context, '\$/ Check')), numeric: true),
                ],
                rows: [
                  for (final g in b.groups)
                    DataRow(cells: [
                      DataCell(Text(g.groupName)),
                      DataCell(Text(money(g.sales))),
                      DataCell(Text(_qty(g.qty))),
                      DataCell(Text(_pct(g.sales, b.totalSales))),
                      DataCell(Text(b.customers == 0
                          ? money(0)
                          : money(g.sales / b.customers))),
                      DataCell(Text(
                          g.qty == 0 ? money(0) : money(g.sales / g.qty))),
                      DataCell(Text(b.customers == 0
                          ? _qty(0)
                          : _qty(g.qty / b.customers))),
                      const DataCell(Text('')),
                    ]),
                  DataRow(
                    cells: [
                      DataCell(Text(tr(context, 'Total'),
                          style:
                              const TextStyle(fontWeight: FontWeight.w800))),
                      DataCell(Text(money(b.totalSales),
                          style:
                              const TextStyle(fontWeight: FontWeight.w800))),
                      DataCell(Text(_qty(b.totalQty),
                          style:
                              const TextStyle(fontWeight: FontWeight.w800))),
                      const DataCell(Text('100.0%',
                          style: TextStyle(fontWeight: FontWeight.w800))),
                      DataCell(Text(money(b.salesPerCustomer),
                          style:
                              const TextStyle(fontWeight: FontWeight.w800))),
                      DataCell(Text(money(b.avgItem),
                          style:
                              const TextStyle(fontWeight: FontWeight.w800))),
                      DataCell(Text(_qty(b.qtyPerCustomer),
                          style:
                              const TextStyle(fontWeight: FontWeight.w800))),
                      DataCell(Text(money(b.salesPerCheck),
                          style:
                              const TextStyle(fontWeight: FontWeight.w800))),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
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
}
