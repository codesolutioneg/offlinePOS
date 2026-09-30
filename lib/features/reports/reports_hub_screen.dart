import 'package:flutter/material.dart';

import '../../core/audit/audit_log.dart';
import '../../core/db/attendance_store.dart';
import '../../core/db/shift_store.dart';
import '../../core/i18n/l10n.dart';
import '../../core/theme/app_colors.dart';
import '../../domain/catalogue.dart';
import '../../domain/delivery.dart';
import '../../domain/order.dart';
import 'activity_report_screen.dart';
import 'attendance_report_screen.dart';
import 'cashier_report_screen.dart';
import 'category_report_screen.dart';
import 'cost_sales_report_screen.dart';
import 'daily_sales_report_screen.dart';
import 'detailed_discounts_report_screen.dart';
import 'discounts_report_screen.dart';
import 'driver_delivery_report_screen.dart';
import 'expenses_report_screen.dart';
import 'flash/flash_flow.dart';
import 'flash/flash_report_data.dart';
import 'flash/flash_type_dialog.dart';
import 'group_sales_report_screen.dart';
import 'item_sales_report_screen.dart';
import 'menu_engineering_report_screen.dart';
import 'modifier_report_screen.dart';
import 'payment_analysis_report_screen.dart';
import 'period_comparison_report_screen.dart';
import 'refunds_summary_report_screen.dart';
import 'report_export.dart';
import 'receivables_report_screen.dart';
import 'refunds_voids_report_screen.dart';
import 'report_period_dialog.dart';
import 'revenue_center_report_screen.dart';
import 'sales_by_time_report_screen.dart';
import 'sales_report_screen.dart';
import 'session_detail_report_screen.dart';
import 'session_summary_report_screen.dart';
import 'tax_report_screen.dart';
import 'today_glance_card.dart';
import 'top_products_report_screen.dart';

/// The reports hub. Each report asks for its own period when opened (Dishflow),
/// so the chips are not a global filter over every tile.
export 'report_period_dialog.dart' show ReportRange;

class ReportsHubScreen extends StatefulWidget {
  const ReportsHubScreen({
    super.key,
    required this.allOrders,
    this.shopOrders,
    this.ordersIn,
    this.shopOrdersIn,
    this.cashTenderIds = const {},
    required this.categories,
    required this.formatAmount,
    required this.audit,
    this.costs = const {},
    this.shifts,
    this.attendance,
    this.staffNames = const {},
    this.openTables,
    this.onPrint,
    this.onPrintFlash,
    this.shopName = '',
    this.ranBy = '',
    this.drivers = const [],
  });

  /// The shop the exported reports are headed with, and the cashier who ran them.
  /// Empty simply leaves that line off the header.
  /// The tenders Odoo says are cash, so the glance card can total them without
  /// reading their names. Empty on a till that has never pulled.
  final Set<int> cashTenderIds;

  final String shopName;
  final String ranBy;

  /// Local delivery drivers for the Dishflow settlement report.
  final List<Driver> drivers;

  /// The recent completed orders; this screen filters them by the chosen range.
  final List<Order> allOrders;

  /// Paid/synced sales from every till on the LAN (for Flash). Falls back to
  /// [allOrders] when null so a single-till shop still works.
  final List<Order>? shopOrders;

  /// This till's sales between two local moments (`to` exclusive, null open),
  /// read without a cap. When set, reports read their period through it rather
  /// than from [allOrders], which is only the most recent slice.
  final List<Order> Function(DateTime? from, DateTime? to)? ordersIn;

  /// The same across every till on the LAN, for Flash; ahead of [shopOrders].
  final List<Order> Function(DateTime? from, DateTime? to)? shopOrdersIn;
  final List<Category> categories;
  final String Function(double) formatAmount;

  /// The audit trail, for the cancelled/voided/refunded activity report.
  final AuditLog audit;

  /// Product id to unit cost, from the catalogue. Empty until an Odoo that states
  /// costs has been synced, which is what the margin reports say on their face
  /// rather than showing every dish as pure profit.
  final Map<int, double> costs;

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

  /// Dishflow-layout Flash thermal print. Null falls back to [onPrint] rows.
  final Future<void> Function(FlashReportData data, FlashKind kind)? onPrintFlash;

  @override
  State<ReportsHubScreen> createState() => _ReportsHubScreenState();
}

class _ReportsHubScreenState extends State<ReportsHubScreen> {
  /// Narrow to one cashier / one order type before a report opens.
  /// Null means "all".
  String? _cashier;
  OrderType? _type;

  /// When the drawer currently open was opened, in local time, or null when there is
  /// no open shift (or no shift store at all).
  DateTime? get _shiftOpenedAt =>
      widget.shifts?.currentOpenShift()?.openedAt.toLocal();

  /// The cashiers who appear in the recent orders, for the cashier filter.
  List<String> get _cashiers =>
      (widget.allOrders.map((o) => o.cashierId).toSet().toList()..sort());

  bool _inPeriod(Order o, ReportPeriodChoice period) =>
      period.contains(o.createdAt, shiftOpenedAt: _shiftOpenedAt);

  List<Order> _applyStaffType(Iterable<Order> source) => source
      .where((o) => _cashier == null || o.cashierId == _cashier)
      .where((o) => _type == null || o.type == _type)
      .toList();

  /// This till's sales in a window, read from the store when it can be asked
  /// and from the preloaded list otherwise.
  List<Order> _localIn(DateTime? from, DateTime? to) =>
      widget.ordersIn?.call(from, to) ?? widget.allOrders;

  /// Local till orders in [period].
  List<Order> _filteredFor(ReportPeriodChoice period) {
    final (from, to) = _windowOf(period);
    return _applyStaffType(_localIn(from, to).where((o) => _inPeriod(o, period)));
  }

  /// Every till on the LAN in [period] (Flash).
  List<Order> _shopFilteredFor(ReportPeriodChoice period) {
    final (from, to) = _windowOf(period);
    final source = widget.shopOrdersIn?.call(from, to) ??
        widget.shopOrders ??
        _localIn(from, to);
    return _applyStaffType(source.where((o) => _inPeriod(o, period)));
  }

  (DateTime?, DateTime?) _windowOf(ReportPeriodChoice period) =>
      period.window(shiftOpenedAt: _shiftOpenedAt);

  double? _rangeHoursOf(ReportPeriodChoice period) {
    final (from, to) = _windowOf(period);
    if (from == null) return null;
    final end = to ?? DateTime.now();
    final hours = end.difference(from).inMinutes / 60.0;
    return hours <= 0 ? null : hours;
  }

  Future<ReportPeriodChoice?> _askPeriod([String? title]) =>
      showReportPeriodDialog(
        context,
        title: title,
        shiftOpenedAt: _shiftOpenedAt,
      );

  // Attendance rows that fall inside the picked window for session summary.
  List<AttendanceEntry> _attendanceFor(ReportPeriodChoice period) {
    final store = widget.attendance;
    if (store == null) return const [];
    final (from, to) = _windowOf(period);
    return store.between(from: from, to: to, staffId: _cashier);
  }

  Future<void> _openFlashMenu() => runFlashFlow(
        context,
        ordersFor: _shopFilteredFor,
        formatAmount: widget.formatAmount,
        shiftOpenedAt: _shiftOpenedAt,
        staffNames: widget.staffNames,
        shopName: widget.shopName,
        categories: widget.categories,
        cashTenderIds: widget.cashTenderIds,
        onPrint: widget.onPrint,
        onPrintFlash: widget.onPrintFlash,
      );

  Future<void> _open(
    Widget Function(List<Order> orders, ReportPeriodChoice period) build,
  ) async {
    final period = await _askPeriod();
    if (!mounted || period == null) return;
    final orders = _filteredFor(period);
    final scope = ReportScope(
      shopName: widget.shopName,
      periodLabel: period.label,
      ranBy: widget.ranBy,
      child: build(orders, period),
    );
    if (!mounted) return;
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => scope));
  }

  /// Print summary: pick period first, then print.
  Future<void> _printSummary() async {
    final period = await _askPeriod(tr(context, 'Print summary'));
    if (!mounted || period == null) return;
    final o = _filteredFor(period);
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
      ('Period', period.label),
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
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(tr(context, 'Summary sent to printer'))));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(tr(context, 'Reports')),
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
            cashTenderIds: widget.cashTenderIds,
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: Text(
              tr(context, 'Pick a report, then choose its period'),
              style: const TextStyle(
                fontSize: 12.5,
                color: AppColors.textMutedLight,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<String?>(
                    key: const Key('report-cashier-filter'),
                    isExpanded: true,
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
                      for (final id in _cashiers)
                        DropdownMenuItem<String?>(
                          value: id,
                          child: Text(widget.staffNames[id] ?? id,
                              overflow: TextOverflow.ellipsis),
                        ),
                    ],
                    onChanged: (v) => setState(() => _cashier = v),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: DropdownButtonFormField<OrderType?>(
                    key: const Key('report-type-filter'),
                    isExpanded: true,
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
                          child: Text(tr(context, t.label),
                              overflow: TextOverflow.ellipsis),
                        ),
                    ],
                    onChanged: (v) => setState(() => _type = v),
                  ),
                ),
              ],
            ),
          ),
          const Divider(),
          Expanded(
            child: ListView(
              children: [
                Card(
                  key: const Key('rep-flash'),
                  margin: const EdgeInsets.symmetric(vertical: 4),
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                    side: BorderSide(
                        color: const Color(0xFFFBBF24).withValues(alpha: 0.35)),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: ListTile(
                    leading: Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: const Color(0xFFFBBF24).withValues(alpha: 0.18),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Icon(Icons.bolt,
                          color: Color(0xFFFBBF24), size: 20),
                    ),
                    title: Text(tr(context, 'Flash reports')),
                    subtitle: Text(
                      tr(context, 'Includes every till on the network'),
                      style: const TextStyle(fontSize: 12),
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: _openFlashMenu,
                  ),
                ),
                _tile(tr(context, 'Sales summary'), Icons.summarize, 'rep-summary',
                    AppColors.info,
                    (o, _) => SalesReportScreen(
                        orders: o, formatAmount: widget.formatAmount)),
                _tile(tr(context, 'Tax'), Icons.receipt, 'rep-tax',
                    const Color(0xFF2563EB),
                    (o, _) => TaxReportScreen(
                        orders: o, formatAmount: widget.formatAmount)),
                _tile(
                    tr(context, 'Group sales'),
                    Icons.dashboard_customize,
                    'rep-group-sales',
                    const Color(0xFF6366F1),
                    (o, _) => GroupSalesReportScreen(
                        orders: o,
                        categories: widget.categories,
                        costs: widget.costs,
                        formatAmount: widget.formatAmount)),
                _tile(
                    tr(context, 'Item sales'),
                    Icons.list_alt,
                    'rep-item-sales',
                    const Color(0xFF0EA5E9),
                    (o, _) => ItemSalesReportScreen(
                        orders: o,
                        categories: widget.categories,
                        costs: widget.costs,
                        formatAmount: widget.formatAmount)),
                _tile(
                    tr(context, 'Session detail'),
                    Icons.receipt_long,
                    'rep-session-detail',
                    const Color(0xFF2563EB),
                    (o, _) => SessionDetailReportScreen(
                        orders: o, formatAmount: widget.formatAmount)),
                _tile(
                    tr(context, 'Sales by revenue center'),
                    Icons.storefront,
                    'rep-revenue-center',
                    const Color(0xFF06B6D4),
                    (o, _) => RevenueCenterReportScreen(
                        orders: o, formatAmount: widget.formatAmount)),
                _tile(
                    tr(context, 'Daily sales'),
                    Icons.calendar_month,
                    'rep-daily-sales',
                    const Color(0xFF14B8A6),
                    (o, _) => DailySalesReportScreen(
                        orders: o, formatAmount: widget.formatAmount)),
                _tile(
                    tr(context, 'Detailed discounts'),
                    Icons.discount,
                    'rep-detailed-discounts',
                    AppColors.warning,
                    (o, _) => DetailedDiscountsReportScreen(
                        orders: o, formatAmount: widget.formatAmount)),
                _tile(
                    tr(context, 'Refunds summary'),
                    Icons.assignment_return,
                    'rep-refunds-summary',
                    AppColors.error,
                    (o, _) => RefundsSummaryReportScreen(
                        orders: o, formatAmount: widget.formatAmount)),
                _tile(
                    tr(context, 'Session summary'),
                    Icons.summarize_outlined,
                    'rep-session-summary',
                    const Color(0xFF9333EA),
                    (o, p) => SessionSummaryReportScreen(
                        orders: o,
                        categories: widget.categories,
                        costs: widget.costs,
                        formatAmount: widget.formatAmount,
                        attendance: _attendanceFor(p),
                        rangeHours: _rangeHoursOf(p))),
                _tile(tr(context, 'Top products'), Icons.star, 'rep-top',
                    const Color(0xFF0EA5E9),
                    (o, _) => TopProductsReportScreen(
                        orders: o, formatAmount: widget.formatAmount)),
                _tile(
                    tr(context, 'Category performance'),
                    Icons.category,
                    'rep-category',
                    const Color(0xFF6366F1),
                    (o, _) => CategoryReportScreen(
                        orders: o,
                        categories: widget.categories,
                        formatAmount: widget.formatAmount)),
                _tile(
                    tr(context, 'Payment analysis'),
                    Icons.payments,
                    'rep-payment',
                    const Color(0xFF06B6D4),
                    (o, _) => PaymentAnalysisReportScreen(
                        orders: o, formatAmount: widget.formatAmount)),
                _tile(tr(context, 'Discounts'), Icons.percent, 'rep-discounts',
                    AppColors.warning,
                    (o, _) => DiscountsReportScreen(
                        orders: o, formatAmount: widget.formatAmount)),
                _tile(
                    tr(context, 'Cashier performance'),
                    Icons.badge_outlined,
                    'rep-cashier',
                    const Color(0xFF8B5CF6),
                    (o, _) => CashierReportScreen(
                        orders: o, formatAmount: widget.formatAmount)),
                _tile(
                    tr(context, 'Driver account'),
                    Icons.delivery_dining,
                    'rep-driver',
                    const Color(0xFF10B981),
                    (o, _) => DriverDeliveryReportScreen(
                        orders: o,
                        drivers: widget.drivers,
                        formatAmount: widget.formatAmount)),
                _tile(
                    tr(context, 'Cancelled, voided & refunded'),
                    Icons.gpp_bad,
                    'rep-activity',
                    AppColors.error,
                    (o, p) {
                      final (from, to) = _windowOf(p);
                      return ActivityReportScreen(
                        orders: o,
                        audit: widget.audit,
                        from: from,
                        to: to,
                        formatAmount: widget.formatAmount,
                      );
                    }),
                _tile(tr(context, 'Sales by hour'), Icons.schedule, 'rep-time',
                    const Color(0xFF64748B),
                    (o, _) => SalesByTimeReportScreen(
                        orders: o, formatAmount: widget.formatAmount)),
                _tile(
                    tr(context, 'Period comparison'),
                    Icons.compare_arrows,
                    'rep-period-compare',
                    const Color(0xFF475569),
                    (o, p) {
                      List<Order> previous = const [];
                      final (from, to) = _windowOf(p);
                      if (from != null) {
                        final end = to ??
                            DateTime.now()
                                .add(const Duration(days: 1));
                        final length = end.difference(from);
                        final prevFrom = from.subtract(length);
                        previous = _applyStaffType(
                            _localIn(prevFrom, from).where((x) {
                          final at = x.createdAt.toLocal();
                          return !at.isBefore(prevFrom) && at.isBefore(from);
                        }));
                      }
                      return PeriodComparisonReportScreen(
                        current: o,
                        previous: previous,
                        currentLabel: p.label,
                        previousLabel: tr(context, 'Previous period'),
                        formatAmount: widget.formatAmount,
                      );
                    }),
                _tile(tr(context, 'Modifiers'), Icons.tune, 'rep-modifiers',
                    const Color(0xFFA855F7),
                    (o, _) => ModifierReportScreen(
                        orders: o, formatAmount: widget.formatAmount)),
                _tile(
                    tr(context, 'Refunds & voids'),
                    Icons.undo,
                    'rep-refunds',
                    AppColors.error,
                    (o, p) {
                      final (from, to) = _windowOf(p);
                      return RefundsVoidsReportScreen(
                        orders: o,
                        audit: widget.audit,
                        from: from,
                        to: to,
                        actor: _cashier,
                        formatAmount: widget.formatAmount,
                      );
                    }),
                _tile(
                    tr(context, 'Cost vs sales'),
                    Icons.savings_outlined,
                    'rep-cost-sales',
                    const Color(0xFF059669),
                    (o, _) => CostSalesReportScreen(
                        orders: o,
                        costs: widget.costs,
                        formatAmount: widget.formatAmount)),
                _tile(
                    tr(context, 'Menu engineering'),
                    Icons.restaurant_menu,
                    'rep-menu-eng',
                    const Color(0xFFD97706),
                    (o, _) => MenuEngineeringReportScreen(
                        orders: o,
                        costs: widget.costs,
                        formatAmount: widget.formatAmount)),
                if (widget.shifts != null)
                  _tile(tr(context, 'Expenses'), Icons.money_off, 'rep-expenses',
                      const Color(0xFFDC2626), (o, p) {
                    final (from, to) = _windowOf(p);
                    final movements = widget.shifts?.movements(
                          from: from,
                          to: to,
                          cashierId: _cashier,
                        ) ??
                        const [];
                    return ExpensesReportScreen(
                      movements: movements,
                      formatAmount: widget.formatAmount,
                    );
                  }),
                _tile(
                    tr(context, 'On account'),
                    Icons.account_balance_wallet_outlined,
                    'rep-receivables',
                    const Color(0xFF0D9488),
                    (o, _) => ReceivablesReportScreen(
                        orders: o, formatAmount: widget.formatAmount)),
                if (widget.attendance != null)
                  _tile(tr(context, 'Hours worked'), Icons.schedule,
                      'rep-hours', const Color(0xFF4F46E5), (o, p) {
                    return AttendanceReportScreen(
                      entries: _attendanceFor(p),
                      staffNames: widget.staffNames,
                    );
                  }),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// A rounded, bordered card with a coloured icon badge.
  Widget _tile(
    String title,
    IconData icon,
    String key,
    Color color,
    Widget Function(List<Order> orders, ReportPeriodChoice period) build,
  ) =>
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
