import 'package:flutter/material.dart';

import '../../core/audit/audit_log.dart';
import '../../core/db/attendance_store.dart';
import '../../core/db/shift_store.dart';
import '../../core/export/data_export.dart';
import '../../core/export/pdf_export.dart';
import '../../core/i18n/l10n.dart';
import '../../core/theme/app_colors.dart';
import '../../domain/catalogue.dart';
import '../../domain/order.dart';
import 'activity_report_screen.dart';
import 'attendance_report_screen.dart';
import 'cashier_report_screen.dart';
import 'category_report_screen.dart';
import 'discounts_report_screen.dart';
import 'expenses_report_screen.dart';
import 'modifier_report_screen.dart';
import 'payment_analysis_report_screen.dart';
import 'period_comparison_report_screen.dart';
import 'receivables_report_screen.dart';
import 'refunds_voids_report_screen.dart';
import 'sales_by_time_report_screen.dart';
import 'sales_report_screen.dart';
import 'tax_report_screen.dart';
import 'today_glance_card.dart';
import 'top_products_report_screen.dart';

/// The reports hub, with a date-range filter applied to every report it opens.
///
/// Reports used to be locked to the last 500 orders with no way to say "yesterday"
/// or "this month". The range is chosen here once and threaded into each report, so
/// a manager sees the period they actually care about.
enum ReportRange { today, yesterday, last7, all }

extension _RangeLabel on ReportRange {
  String label(BuildContext context) => switch (this) {
        ReportRange.today => tr(context, 'Today'),
        ReportRange.yesterday => tr(context, 'Yesterday'),
        ReportRange.last7 => tr(context, 'Last 7 days'),
        ReportRange.all => tr(context, 'All'),
      };
}

class ReportsHubScreen extends StatefulWidget {
  const ReportsHubScreen({
    super.key,
    required this.allOrders,
    required this.categories,
    required this.formatAmount,
    required this.audit,
    this.shifts,
    this.attendance,
    this.staffNames = const {},
    this.openTables,
    this.onPrint,
  });

  /// The recent completed orders; this screen filters them by the chosen range.
  final List<Order> allOrders;
  final List<Category> categories;
  final String Function(double) formatAmount;

  /// The audit trail, for the cancelled/voided/refunded activity report.
  final AuditLog audit;

  /// The shifts, read across the chosen range for the expenses report. Null hides
  /// that tile, for a caller that has no drawer to report on.
  final ShiftStore? shifts;

  /// Staff clock-ins, read across the chosen range for the hours report. Null
  /// hides that tile, the way a missing shift store hides expenses.
  final AttendanceStore? attendance;

  /// Staff id to name, so the hours report reads as people rather than as ids.
  final Map<String, String> staffNames;

  /// Tables with an order parked on them right now, for the glance card.
  final int? openTables;

  /// Prints a report to the receipt printer. Null hides the print action.
  final Future<void> Function(String title, List<(String, String)> rows)? onPrint;

  @override
  State<ReportsHubScreen> createState() => _ReportsHubScreenState();
}

class _ReportsHubScreenState extends State<ReportsHubScreen> {
  ReportRange _range = ReportRange.today;

  /// A manager-picked from/to range; when set it overrides the preset chips so a
  /// report can cover any period, not just today/yesterday/7-day.
  DateTimeRange? _custom;

  /// Narrow the window to one cashier / one order type before a report opens.
  /// Null means "all", so the reports keep working exactly as before until a
  /// manager actually picks a value.
  String? _cashier;
  OrderType? _type;

  /// Orders whose local sale date falls inside the chosen range and match the
  /// cashier/order-type filters.
  List<Order> get _filtered {
    final now = DateTime.now();
    final startOfToday = DateTime(now.year, now.month, now.day);
    bool inRange(Order o) {
      final at = o.createdAt.toLocal();
      if (_custom != null) {
        final end = _custom!.end.add(const Duration(days: 1));
        return !at.isBefore(_custom!.start) && at.isBefore(end);
      }
      return switch (_range) {
        ReportRange.today => !at.isBefore(startOfToday),
        ReportRange.yesterday => !at.isBefore(startOfToday.subtract(const Duration(days: 1))) &&
            at.isBefore(startOfToday),
        ReportRange.last7 => !at.isBefore(startOfToday.subtract(const Duration(days: 6))),
        ReportRange.all => true,
      };
    }

    return widget.allOrders
        .where(inRange)
        .where((o) => _cashier == null || o.cashierId == _cashier)
        .where((o) => _type == null || o.type == _type)
        .toList();
  }

  /// The cashiers who appear in the recent orders, for the cashier filter.
  List<String> get _cashiers =>
      (widget.allOrders.map((o) => o.cashierId).toSet().toList()..sort());

  /// The chosen range as explicit bounds, for reports that also read the audit
  /// trail (which is not a list of orders). Null means unbounded on that side.
  DateTime? get _windowFrom {
    if (_custom != null) return _custom!.start;
    final now = DateTime.now();
    final startOfToday = DateTime(now.year, now.month, now.day);
    return switch (_range) {
      ReportRange.today => startOfToday,
      ReportRange.yesterday => startOfToday.subtract(const Duration(days: 1)),
      ReportRange.last7 => startOfToday.subtract(const Duration(days: 6)),
      ReportRange.all => null,
    };
  }

  DateTime? get _windowTo {
    if (_custom != null) return _custom!.end.add(const Duration(days: 1));
    final now = DateTime.now();
    final startOfToday = DateTime(now.year, now.month, now.day);
    return _range == ReportRange.yesterday ? startOfToday : null;
  }

  /// The chosen window with both ends filled in: an open-ended range runs to the
  /// end of today, so a period comparison measures whole days against whole days
  /// rather than "today so far" against a full day.
  ({DateTime from, DateTime to})? get _closedWindow {
    final from = _windowFrom;
    if (from == null) return null;
    final now = DateTime.now();
    final endOfToday =
        DateTime(now.year, now.month, now.day).add(const Duration(days: 1));
    return (from: from, to: _windowTo ?? endOfToday);
  }

  /// The same-length period immediately before the chosen one, with the same
  /// cashier and order-type filters. Empty for 'All', which has no before.
  List<Order> get _previousPeriod {
    final window = _closedWindow;
    if (window == null) return const [];
    final length = window.to.difference(window.from);
    final from = window.from.subtract(length);
    return widget.allOrders.where((o) {
      final at = o.createdAt.toLocal();
      return !at.isBefore(from) && at.isBefore(window.from);
    }).where(_matchesFilters).toList();
  }

  bool _matchesFilters(Order o) =>
      (_cashier == null || o.cashierId == _cashier) &&
      (_type == null || o.type == _type);

  /// The paid-outs and paid-ins inside the chosen window, for the expenses
  /// report. Read straight from the shift store, which is local, so this works
  /// with the network down like everything else here.
  List<ShiftMovement> get _movements =>
      widget.shifts?.movements(
        from: _windowFrom,
        to: _windowTo,
        cashierId: _cashier,
      ) ??
      const [];

  /// The clock-ins inside the chosen window, for the hours report. Local read,
  /// filtered by the same cashier picker as everything else here.
  List<AttendanceEntry> get _attendance =>
      widget.attendance?.between(
        from: _windowFrom,
        to: _windowTo,
        staffId: _cashier,
      ) ??
      const [];

  /// What the chosen period is called, for a report that names it on screen.
  String _rangeLabel(BuildContext context) => _custom == null
      ? _range.label(context)
      : '${_custom!.start.month}/${_custom!.start.day} - ${_custom!.end.month}/${_custom!.end.day}';

  Future<void> _pickCustom() async {
    final now = DateTime.now();
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(now.year - 2),
      lastDate: now,
      initialDateRange: _custom,
    );
    if (!mounted) return;
    if (picked != null) setState(() => _custom = picked);
  }

  void _open(Widget Function(List<Order>) build) {
    Navigator.of(context)
        .push(MaterialPageRoute<void>(builder: (_) => build(_filtered)));
  }

  /// Print the sales summary for the current range to the receipt printer.
  Future<void> _printSummary() async {
    final o = _filtered;
    final f = widget.formatAmount;
    final gross = o.fold(0.0, (s, x) => s + x.total);
    final discounts =
        o.fold(0.0, (s, x) => s + x.subtotal * x.discountPercent / 100);
    final delivery = o.fold(0.0, (s, x) => s + x.deliveryCost);
    final tips = o.fold(0.0, (s, x) => s + x.tip);
    final tax = o.fold(0.0, (s, x) => s + x.taxTotal);
    final byMethod = <String, double>{};
    for (final x in o) {
      if (x.payments.isEmpty) {
        byMethod['Cash'] = (byMethod['Cash'] ?? 0) + x.total;
      } else {
        for (final p in x.payments) {
          final k = p.label ?? 'Cash';
          byMethod[k] = (byMethod[k] ?? 0) + p.amount;
        }
      }
    }
    final rows = <(String, String)>[
      ('Orders', '${o.length}'),
      ('Gross sales', f(gross)),
      ('Discounts', f(discounts)),
      ('Delivery', f(delivery)),
      ('Tips', f(tips)),
      ('Tax (incl.)', f(tax)),
      for (final e in byMethod.entries) (e.key, f(e.value)),
    ];
    await widget.onPrint?.call('Sales summary', rows);
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(tr(context, 'Summary sent to printer'))));
    }
  }

  /// The windowed, filtered orders as one row each, the shape both the CSV and
  /// the PDF export share. Columns are the order-level facts a manager needs off
  /// the till: reference, when, who, type, item count and total.
  (List<String>, List<List<String>>) _ordersTable() {
    String ref(String uuid) =>
        uuid.length <= 6 ? uuid : uuid.replaceAll('-', '').substring(0, 6).toUpperCase();
    String at(DateTime d) {
      final l = d.toLocal();
      String two(int n) => n.toString().padLeft(2, '0');
      return '${l.year}-${two(l.month)}-${two(l.day)} ${two(l.hour)}:${two(l.minute)}';
    }

    const header = ['Ref', 'Date', 'Cashier', 'Type', 'Items', 'Total'];
    final rows = [
      for (final o in _filtered)
        [
          ref(o.uuid),
          at(o.createdAt),
          o.cashierId,
          o.type.label,
          '${o.lines.length}',
          o.total.toStringAsFixed(2),
        ],
    ];
    return (header, rows);
  }

  Future<void> _downloadCsv() async {
    final (header, rows) = _ordersTable();
    final name = exportFileName('report-sales', DateTime.now(), 'csv');
    await _save(() => writeTextExport(name, buildCsv(header, rows)));
  }

  Future<void> _downloadPdf() async {
    final (header, rows) = _ordersTable();
    final name = exportFileName('report-sales', DateTime.now(), 'pdf');
    await _save(() async => writeBytesExport(
          name,
          await buildPdfTable(tr(context, 'Sales report'), header, rows),
        ));
  }

  /// Runs a file-writing action and tells the user where it landed, or that it
  /// could not be saved, rather than failing silently.
  Future<void> _save(Future<String> Function() write) async {
    try {
      final path = await write();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${tr(context, 'Saved to')}: $path')),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr(context, 'Could not save file'))),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final count = _filtered.length;
    return Scaffold(
      appBar: AppBar(
        title: Text(tr(context, 'Reports')),
        actions: [
          IconButton(
            key: const Key('report-download-csv'),
            tooltip: tr(context, 'Download CSV'),
            icon: const Icon(Icons.download),
            onPressed: _downloadCsv,
          ),
          IconButton(
            key: const Key('report-download-pdf'),
            tooltip: tr(context, 'Download PDF'),
            icon: const Icon(Icons.picture_as_pdf_outlined),
            onPressed: _downloadPdf,
          ),
        ],
      ),
      floatingActionButton: widget.onPrint == null
          ? null
          : FloatingActionButton.extended(
              key: const Key('print-summary'),
              icon: const Icon(Icons.print),
              label: Text(tr(context, 'Print summary')),
              onPressed: _printSummary,
            ),
      body: Column(
        children: [
          TodayGlanceCard(
            allOrders: widget.allOrders,
            formatAmount: widget.formatAmount,
            openTables: widget.openTables,
          ),
          Padding(
            padding: const EdgeInsets.all(8),
            child: Wrap(
              spacing: 8,
              children: [
                for (final r in ReportRange.values)
                  ChoiceChip(
                    key: Key('range-${r.name}'),
                    label: Text(r.label(context)),
                    selected: _custom == null && _range == r,
                    onSelected: (_) => setState(() {
                      _range = r;
                      _custom = null;
                    }),
                  ),
                ChoiceChip(
                  key: const Key('range-custom'),
                  avatar: const Icon(Icons.date_range, size: 16),
                  label: Text(_custom == null
                      ? tr(context, 'Custom')
                      : '${_custom!.start.month}/${_custom!.start.day} - ${_custom!.end.month}/${_custom!.end.day}'),
                  selected: _custom != null,
                  onSelected: (_) => _pickCustom(),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<String?>(
                    key: const Key('report-cashier-filter'),
                    initialValue: _cashier,
                    decoration: InputDecoration(
                      labelText: tr(context, 'Cashier'),
                      border: const OutlineInputBorder(),
                      isDense: true,
                    ),
                    items: [
                      DropdownMenuItem<String?>(
                        value: null,
                        child: Text(tr(context, 'All cashiers')),
                      ),
                      for (final c in _cashiers)
                        DropdownMenuItem<String?>(value: c, child: Text(c)),
                    ],
                    onChanged: (v) => setState(() => _cashier = v),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: DropdownButtonFormField<OrderType?>(
                    key: const Key('report-type-filter'),
                    initialValue: _type,
                    decoration: InputDecoration(
                      labelText: tr(context, 'Order type'),
                      border: const OutlineInputBorder(),
                      isDense: true,
                    ),
                    items: [
                      DropdownMenuItem<OrderType?>(
                        value: null,
                        child: Text(tr(context, 'All types')),
                      ),
                      for (final t in OrderType.values)
                        DropdownMenuItem<OrderType?>(
                          value: t,
                          child: Text(tr(context, t.label)),
                        ),
                    ],
                    onChanged: (v) => setState(() => _type = v),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Text('$count order(s) in range', key: const Key('range-count')),
          const Divider(),
          Expanded(
            child: ListView(
              children: [
                _tile(tr(context, 'Sales summary'), Icons.summarize, 'rep-summary',
                    AppColors.info,
                    (o) => SalesReportScreen(orders: o, formatAmount: widget.formatAmount)),
                _tile(tr(context, 'Tax'), Icons.receipt, 'rep-tax', const Color(0xFF2563EB),
                    (o) => TaxReportScreen(orders: o, formatAmount: widget.formatAmount)),
                _tile(tr(context, 'Top products'), Icons.star, 'rep-top', const Color(0xFF0EA5E9),
                    (o) => TopProductsReportScreen(orders: o, formatAmount: widget.formatAmount)),
                _tile(tr(context, 'Category performance'), Icons.category, 'rep-category',
                    const Color(0xFF6366F1),
                    (o) => CategoryReportScreen(
                        orders: o, categories: widget.categories, formatAmount: widget.formatAmount)),
                _tile(tr(context, 'Payment analysis'), Icons.payments, 'rep-payment',
                    const Color(0xFF06B6D4),
                    (o) => PaymentAnalysisReportScreen(orders: o, formatAmount: widget.formatAmount)),
                _tile(tr(context, 'Discounts'), Icons.percent, 'rep-discounts', AppColors.warning,
                    (o) => DiscountsReportScreen(orders: o, formatAmount: widget.formatAmount)),
                _tile(tr(context, 'Cashier performance'), Icons.badge_outlined, 'rep-cashier',
                    const Color(0xFFEA580C),
                    (o) => CashierReportScreen(orders: o, formatAmount: widget.formatAmount)),
                _tile(tr(context, 'Cancelled, voided & refunded'), Icons.gpp_bad,
                    'rep-activity', AppColors.error,
                    (o) => ActivityReportScreen(
                          orders: o,
                          audit: widget.audit,
                          formatAmount: widget.formatAmount,
                          from: _windowFrom,
                          to: _windowTo,
                          // Narrow voids/cancels to the same cashier as the refunds.
                          actor: _cashier,
                        )),
                _tile(tr(context, 'Sales by hour'), Icons.schedule, 'rep-time',
                    const Color(0xFF14B8A6),
                    (o) => SalesByTimeReportScreen(orders: o, formatAmount: widget.formatAmount)),
                _tile(tr(context, 'Period comparison'), Icons.compare_arrows,
                    'rep-comparison', const Color(0xFF14B8A6),
                    (o) => PeriodComparisonReportScreen(
                          current: o,
                          previous: _previousPeriod,
                          currentLabel: _rangeLabel(context),
                          previousLabel: tr(context, 'Previous period'),
                          formatAmount: widget.formatAmount,
                        )),
                _tile(tr(context, 'Modifiers'), Icons.tune, 'rep-modifiers',
                    const Color(0xFF0EA5E9),
                    (o) => ModifierReportScreen(
                        orders: o, formatAmount: widget.formatAmount)),
                _tile(tr(context, 'Refunds & voids'), Icons.undo, 'rep-refunds',
                    AppColors.error,
                    (o) => RefundsVoidsReportScreen(
                          orders: o,
                          audit: widget.audit,
                          formatAmount: widget.formatAmount,
                          from: _windowFrom,
                          to: _windowTo,
                          actor: _cashier,
                        )),
                if (widget.shifts != null)
                  _tile(tr(context, 'Expenses'), Icons.money_off, 'rep-expenses',
                      AppColors.warning,
                      (_) => ExpensesReportScreen(
                          movements: _movements,
                          formatAmount: widget.formatAmount)),
                _tile(tr(context, 'On account'), Icons.account_balance_wallet_outlined,
                    'rep-receivables', const Color(0xFFEA580C),
                    (o) => ReceivablesReportScreen(
                        orders: o, formatAmount: widget.formatAmount)),
                if (widget.attendance != null)
                  _tile(tr(context, 'Hours worked'), Icons.schedule,
                      'rep-attendance', const Color(0xFF6366F1),
                      (_) => AttendanceReportScreen(
                          entries: _attendance, staffNames: widget.staffNames)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// A rounded, bordered card with a coloured icon badge, tinted per report
  /// family so financial reports and audit/oversight reports read apart in the
  /// list rather than as one flat wall of grey tiles.
  Widget _tile(String title, IconData icon, String key, Color color,
          Widget Function(List<Order>) build) =>
      Card(
        key: Key(key),
        margin: const EdgeInsets.symmetric(vertical: 4),
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: color.withValues(alpha: 0.25)),
        ),
        clipBehavior: Clip.antiAlias,
        child: ListTile(
          leading: Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: color, size: 20),
          ),
          title: Text(title),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _open(build),
        ),
      );
}
