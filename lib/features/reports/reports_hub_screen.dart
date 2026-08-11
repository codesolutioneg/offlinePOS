import 'package:flutter/material.dart';

import '../../domain/catalogue.dart';
import '../../domain/order.dart';
import 'cashier_report_screen.dart';
import 'category_report_screen.dart';
import 'discounts_report_screen.dart';
import 'payment_analysis_report_screen.dart';
import 'sales_by_time_report_screen.dart';
import 'sales_report_screen.dart';
import 'tax_report_screen.dart';
import 'top_products_report_screen.dart';

/// The reports hub, with a date-range filter applied to every report it opens.
///
/// Reports used to be locked to the last 500 orders with no way to say "yesterday"
/// or "this month". The range is chosen here once and threaded into each report, so
/// a manager sees the period they actually care about.
enum ReportRange { today, yesterday, last7, all }

extension _RangeLabel on ReportRange {
  String get label => switch (this) {
        ReportRange.today => 'Today',
        ReportRange.yesterday => 'Yesterday',
        ReportRange.last7 => 'Last 7 days',
        ReportRange.all => 'All',
      };
}

class ReportsHubScreen extends StatefulWidget {
  const ReportsHubScreen({
    super.key,
    required this.allOrders,
    required this.categories,
    required this.formatAmount,
  });

  /// The recent completed orders; this screen filters them by the chosen range.
  final List<Order> allOrders;
  final List<Category> categories;
  final String Function(double) formatAmount;

  @override
  State<ReportsHubScreen> createState() => _ReportsHubScreenState();
}

class _ReportsHubScreenState extends State<ReportsHubScreen> {
  ReportRange _range = ReportRange.today;

  /// Orders whose local sale date falls inside the chosen range.
  List<Order> get _filtered {
    final now = DateTime.now();
    final startOfToday = DateTime(now.year, now.month, now.day);
    bool inRange(Order o) {
      final at = o.createdAt.toLocal();
      return switch (_range) {
        ReportRange.today => !at.isBefore(startOfToday),
        ReportRange.yesterday => !at.isBefore(startOfToday.subtract(const Duration(days: 1))) &&
            at.isBefore(startOfToday),
        ReportRange.last7 => !at.isBefore(startOfToday.subtract(const Duration(days: 6))),
        ReportRange.all => true,
      };
    }

    return widget.allOrders.where(inRange).toList();
  }

  void _open(Widget Function(List<Order>) build) {
    Navigator.of(context)
        .push(MaterialPageRoute<void>(builder: (_) => build(_filtered)));
  }

  @override
  Widget build(BuildContext context) {
    final count = _filtered.length;
    return Scaffold(
      appBar: AppBar(title: const Text('Reports')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(8),
            child: Wrap(
              spacing: 8,
              children: [
                for (final r in ReportRange.values)
                  ChoiceChip(
                    key: Key('range-${r.name}'),
                    label: Text(r.label),
                    selected: _range == r,
                    onSelected: (_) => setState(() => _range = r),
                  ),
              ],
            ),
          ),
          Text('$count order(s) in range', key: const Key('range-count')),
          const Divider(),
          Expanded(
            child: ListView(
              children: [
                _tile('Sales summary', Icons.summarize, 'rep-summary',
                    (o) => SalesReportScreen(orders: o, formatAmount: widget.formatAmount)),
                _tile('Tax', Icons.receipt, 'rep-tax',
                    (o) => TaxReportScreen(orders: o, formatAmount: widget.formatAmount)),
                _tile('Top products', Icons.star, 'rep-top',
                    (o) => TopProductsReportScreen(orders: o, formatAmount: widget.formatAmount)),
                _tile('Category performance', Icons.category, 'rep-category',
                    (o) => CategoryReportScreen(
                        orders: o, categories: widget.categories, formatAmount: widget.formatAmount)),
                _tile('Payment analysis', Icons.payments, 'rep-payment',
                    (o) => PaymentAnalysisReportScreen(orders: o, formatAmount: widget.formatAmount)),
                _tile('Discounts', Icons.percent, 'rep-discounts',
                    (o) => DiscountsReportScreen(orders: o, formatAmount: widget.formatAmount)),
                _tile('Cashier performance', Icons.badge_outlined, 'rep-cashier',
                    (o) => CashierReportScreen(orders: o, formatAmount: widget.formatAmount)),
                _tile('Sales by hour', Icons.schedule, 'rep-time',
                    (o) => SalesByTimeReportScreen(orders: o, formatAmount: widget.formatAmount)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _tile(String title, IconData icon, String key, Widget Function(List<Order>) build) =>
      ListTile(
        key: Key(key),
        leading: Icon(icon),
        title: Text(title),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => _open(build),
      );
}
