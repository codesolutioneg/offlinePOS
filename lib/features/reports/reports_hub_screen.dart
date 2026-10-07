import 'dart:convert';

import 'package:flutter/material.dart';

import '../../core/audit/audit_log.dart';
import '../../core/db/attendance_store.dart';
import '../../core/db/shift_store.dart';
import '../../core/i18n/l10n.dart';
import '../../core/theme/app_colors.dart';
import '../../domain/catalogue.dart';
import '../../domain/delivery.dart';
import '../../domain/order.dart';
import '../../domain/shift.dart';
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
import 'receivables_report_screen.dart';
import 'refunds_voids_report_screen.dart';
import 'report_period_dialog.dart';
import 'revenue_center_report_screen.dart';
import 'rm/report_window.dart';
import 'rm/rm_bindings.dart';
import 'rm/rm_layout.dart';
import 'rm/rm_report_viewer.dart';
import 'rm/rm_table_page.dart';
import 'rm/thermal_report.dart';
import 'sales_by_time_report_screen.dart';
import 'sales_report_screen.dart';
import 'session_detail_report_screen.dart';
import 'session_summary_report_screen.dart';
import 'tax_report_screen.dart';
import 'today_glance_card.dart';
import 'top_products_report_screen.dart';

/// The reports hub, laid out the way a back-office report manager is: the reports
/// as a tree of folders, the period and filters as a form beside it, the shifts
/// down the far side, and one button that opens the picked report over all of it.
export 'report_period_dialog.dart' show ReportRange;
export 'rm/thermal_report.dart' show ThermalReport;

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
    this.onPrintReport,
    this.onPrintFlash,
    this.shopName = '',
    this.ranBy = '',
    this.drivers = const [],
    this.favoriteFilters,
    this.onFavoriteFiltersChanged,
  });

  /// The saved filter sets as the shell keeps them (JSON), and where a change to
  /// them goes. Without the second they last only as long as the screen.
  final String? favoriteFilters;
  final void Function(String json)? onFavoriteFiltersChanged;

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

  /// Prints an opened report on the receipt printer, set the way the back
  /// office sets its forty-column reports. Null hides the report window's
  /// thermal button.
  final Future<void> Function(ThermalReport report)? onPrintReport;

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

  /// The rest of the form. Empty or null narrows nothing.
  String? _tender;
  String? _driver;
  final _table = TextEditingController();
  final _check = TextEditingController();
  final _customer = TextEditingController();

  /// The report picked in the tree, by its key.
  String? _selected;

  /// Folders the manager has folded shut.
  final _closed = <String>{};
  final _find = TextEditingController();

  /// The period: a preset, unless a custom range or one shift was picked.
  ReportRange _range = ReportRange.today;
  DateTimeRange? _custom;
  Shift? _shiftPick;

  /// Touch rows instead of Mouse rows: the same screen with more to hit.
  bool _touch = false;

  /// The back-office report layouts bundled with the app, once they are read.
  List<RmReport> _rm = const [];

  @override
  void initState() {
    super.initState();
    _loadRmLayouts();
  }

  Future<void> _loadRmLayouts() async {
    try {
      // Read as bytes: loadString moves a file this size to another isolate.
      final data = await DefaultAssetBundle.of(context)
          .load('assets/report_layouts/layouts.json');
      final reports = parseRmReports(utf8.decode(data.buffer.asUint8List()));
      if (!mounted) return;
      setState(() {
        _rm = reports;
        // Folded shut to begin with: ninety layouts would bury the till's own.
        _closed.addAll({for (final r in reports) 'rm:${r.group}'});
      });
    } catch (_) {
      // A build without the layouts simply has no such folders.
    }
  }

  /// What the form is narrowed to, in words, for a layout's "Report filter" line.
  String _filterWords(BuildContext context) {
    final parts = [
      if (_cashier != null)
        '${tr(context, 'Employee')}: ${widget.staffNames[_cashier] ?? _cashier}',
      if (_type != null)
        '${tr(context, 'Revenue Center')}: ${tr(context, _type!.label)}',
      if (_table.text.trim().isNotEmpty)
        '${tr(context, 'Table')}: ${_table.text.trim()}',
      if (_check.text.trim().isNotEmpty)
        '${tr(context, 'Check Number')}: ${_check.text.trim()}',
      if (_tender != null) '${tr(context, 'Payment method')}: $_tender',
      if (_customer.text.trim().isNotEmpty)
        '${tr(context, 'Customer')}: ${_customer.text.trim()}',
      if (_driver != null) '${tr(context, 'Driver')}: $_driver',
    ];
    return parts.isEmpty ? tr(context, 'None') : parts.join(', ');
  }

  /// Open one of the bundled layouts in the page viewer, over the till's
  /// sales where the layout is connected to them.
  Future<void> _openRm(RmReport report) {
    final period = _period(context);
    final filter = _filterWords(context);
    final ranAt = DateTime.now();
    final labels = RmPageLabels(
      date: tr(context, 'Date'),
      time: tr(context, 'Time'),
      page: tr(context, 'Page'),
      session: tr(context, 'Session #'),
      filterSettings: tr(context, 'Filter Settings'),
    );
    final binding = bindRmReport(
      report.id,
      orders: _filteredFor(period),
      categories: widget.categories,
      costs: widget.costs,
      cashTenderIds: widget.cashTenderIds,
    );
    final document = layOutRmReport(
      report,
      RmSystem(
        shop: widget.shopName,
        report: report.name,
        period: period.label,
        ranAt: _stamp(DateTime.now()),
        filter: _filterWords(context),
      ),
      rows: binding?.rows,
      headless: binding?.headless ?? const {},
      // Over the till's data it opens with the heading every report page
      // has; as a bare layout it keeps the one it was designed with.
      pageHeading: binding == null
          ? null
          : (items, page, pageWidth) => putRmPageHeading(
                items,
                page: page,
                pageWidth: pageWidth,
                shop: widget.shopName,
                title: report.name,
                period: period.label,
                filter: filter,
                ranAt: ranAt,
                labels: labels,
              ),
    );
    return showReportWindow(
        context, RmReportViewer(title: report.name, document: document));
  }

  /// The filter sets saved under a name, as the shell last stored them.
  late final List<Map<String, dynamic>> _favorites = _readFavorites();

  List<Map<String, dynamic>> _readFavorites() {
    try {
      final saved = jsonDecode(widget.favoriteFilters ?? '[]');
      return [
        if (saved is List)
          for (final f in saved)
            if (f is Map) f.cast<String, dynamic>(),
      ];
    } on FormatException {
      return [];
    }
  }

  @override
  void dispose() {
    _table.dispose();
    _check.dispose();
    _customer.dispose();
    _find.dispose();
    super.dispose();
  }

  /// The tenders and drivers that appear in the recent orders, for their filters.
  List<String> get _tenders => ({
        for (final o in widget.allOrders)
          for (final p in o.payments) p.label ?? 'Cash',
      }.toList()
        ..sort());

  List<String> get _driverNames => ({
        for (final d in widget.drivers) d.name,
        for (final o in widget.allOrders)
          if ((o.driverName ?? '').isNotEmpty) o.driverName!,
      }.toList()
        ..sort());

  /// When the drawer currently open was opened, in local time, or null when there is
  /// no open shift (or no shift store at all).
  DateTime? get _shiftOpenedAt =>
      widget.shifts?.currentOpenShift()?.openedAt.toLocal();

  /// The cashiers who appear in the recent orders, for the cashier filter.
  List<String> get _cashiers =>
      (widget.allOrders.map((o) => o.cashierId).toSet().toList()..sort());

  bool _inPeriod(Order o, ReportPeriodChoice period) =>
      period.contains(o.createdAt, shiftOpenedAt: _shiftOpenedAt);

  List<Order> _applyStaffType(Iterable<Order> source) {
    bool has(String? value, String wanted) =>
        (value ?? '').toLowerCase().contains(wanted);
    final table = _table.text.trim().toLowerCase();
    final check = _check.text.trim().toLowerCase();
    final customer = _customer.text.trim().toLowerCase();
    return source
        .where((o) => _cashier == null || o.cashierId == _cashier)
        .where((o) => _type == null || o.type == _type)
        .where((o) => table.isEmpty || has(o.tableLabel, table))
        .where((o) => check.isEmpty || has(o.displayNo, check))
        .where((o) =>
            customer.isEmpty ||
            has(o.customerName, customer) ||
            has(o.customerPhone, customer))
        .where((o) => _driver == null || o.driverName == _driver)
        // An untendered sale is booked to cash, as the payment reports read it.
        .where((o) =>
            _tender == null ||
            (o.payments.isEmpty
                ? _tender == 'Cash'
                : o.payments.any((p) => (p.label ?? 'Cash') == _tender)))
        .toList();
  }

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

  /// Print the summary of the period and filters the form is set to.
  Future<void> _printSummary() async {
    final period = _period(context);
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

  /// Every report the hub can open, in no particular order: [_groups] decides
  /// where each one sits in the tree.
  List<_Report> _reports(BuildContext context) => [
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
      ];

  /// The folders of the tree, in the order they are listed, each with the reports
  /// filed under it. A report nobody filed lands in the last folder rather than
  /// vanishing.
  static const _groups = <(String, List<String>)>[
    (
      'Session Reports',
      [
        'rep-session-summary',
        'rep-session-detail',
        'rep-item-sales',
        'rep-detailed-discounts',
        'rep-time',
        'rep-expenses',
        'rep-refunds',
        'rep-activity',
        'rep-driver',
        'rep-payment',
      ]
    ),
    (
      'Sales Reports',
      [
        'rep-summary',
        'rep-tax',
        'rep-group-sales',
        'rep-revenue-center',
        'rep-daily-sales',
        'rep-top',
        'rep-category',
        'rep-discounts',
        'rep-refunds-summary',
        'rep-modifiers',
        'rep-period-compare',
      ]
    ),
    ('Labor Reports', ['rep-hours', 'rep-cashier']),
    ('Cost Reports', ['rep-cost-sales', 'rep-menu-eng']),
    ('Accounts Reports', ['rep-receivables']),
    ('POS Reports', ['rep-flash']),
  ];

  static const _flashKey = 'rep-flash';

  _Report _flash(BuildContext context) => _Report(
        key: _flashKey,
        title: tr(context, 'Flash reports'),
        icon: Icons.bolt,
        color: const Color(0xFFFBBF24),
      );

  /// The period the form is set to, labelled in the language on screen.
  ReportPeriodChoice _period(BuildContext context) {
    final shift = _shiftPick;
    if (shift != null) {
      return ReportPeriodChoice.exact(
        shift.openedAt.toLocal(),
        shift.closedAt?.toLocal(),
        '${tr(context, 'Session')} ${_stamp(shift.openedAt)}',
      );
    }
    final c = _custom;
    if (c != null) {
      return ReportPeriodChoice.customRange(
          c, '${_day(c.start)} → ${_day(c.end)}');
    }
    return ReportPeriodChoice.preset(_range, _range.label(context));
  }

  static String _two(int n) => n.toString().padLeft(2, '0');

  static String _day(DateTime x) {
    final l = x.toLocal();
    return '${l.year}-${_two(l.month)}-${_two(l.day)}';
  }

  static String _stamp(DateTime x) {
    final l = x.toLocal();
    return '${_day(l)} ${_two(l.hour)}:${_two(l.minute)}';
  }

  Future<void> _pickCustom() async {
    final now = DateTime.now();
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(now.year - 2),
      lastDate: now,
      initialDateRange: _custom ??
          DateTimeRange(
            start: DateTime(now.year, now.month, now.day),
            end: DateTime(now.year, now.month, now.day),
          ),
    );
    if (!mounted || picked == null) return;
    setState(() {
      _custom = picked;
      _shiftPick = null;
    });
  }

  void _clearFilters() => setState(() {
        _cashier = null;
        _type = null;
        _tender = null;
        _driver = null;
        _table.clear();
        _check.clear();
        _customer.clear();
        _range = ReportRange.today;
        _custom = null;
        _shiftPick = null;
      });

  /// Open the report picked in the tree over the period and filters in the form.
  Future<void> _run() async {
    final key = _selected;
    if (key == null) return;
    if (key == _flashKey) return _openFlashMenu();
    // A till report the back office has a connected layout for opens as that
    // layout, so its columns and sections are the back office's.
    final layout = _rm
        .where((r) =>
            'rm-${r.id}' == key || r.id == rmLayoutForReport[key])
        .firstOrNull;
    if (layout != null) return _openRm(layout);
    final report = _reports(context).where((r) => r.key == key).firstOrNull;
    final build = report?.build;
    if (build == null) return;
    final period = _period(context);
    final orders = _filteredFor(period);
    await showReportWindow(
      context,
      ReportWindow(
        shopName: widget.shopName,
        periodLabel: period.label,
        ranBy: widget.ranBy,
        filter: _filterWords(context),
        report: build(orders, period),
        onPrint: widget.onPrintReport,
      ),
    );
  }

  /// Open every report in the picked report's folder, one after the other: each
  /// opens when the one before it is closed.
  Future<void> _runGroup() async {
    final keys = _groupOf(_selected)?.$2 ?? const <String>[];
    final known = {for (final r in _reports(context)) r.key};
    for (final key in keys) {
      if (!mounted) return;
      if (!known.contains(key)) continue;
      setState(() => _selected = key);
      await _run();
    }
  }

  (String, List<String>)? _groupOf(String? key) =>
      _groups.where((g) => g.$2.contains(key)).firstOrNull;

  /// The form as it stands, for the favourites. The preset period only: a custom
  /// range or one shift is a date, and a date saved today is wrong tomorrow.
  Map<String, dynamic> _snapshot() => {
        'range': _range.name,
        'cashier': _cashier,
        'type': _type?.name,
        'tender': _tender,
        'driver': _driver,
        'table': _table.text,
        'check': _check.text,
        'customer': _customer.text,
      };

  void _applyFavorite(Map<String, dynamic> f) => setState(() {
        _range = ReportRange.values
                .where((r) => r.name == f['range'])
                .firstOrNull ??
            ReportRange.today;
        _custom = null;
        _shiftPick = null;
        _cashier = f['cashier'] as String?;
        _type =
            OrderType.values.where((t) => t.name == f['type']).firstOrNull;
        _tender = f['tender'] as String?;
        _driver = f['driver'] as String?;
        _table.text = (f['table'] as String?) ?? '';
        _check.text = (f['check'] as String?) ?? '';
        _customer.text = (f['customer'] as String?) ?? '';
      });

  void _storeFavorites() =>
      widget.onFavoriteFiltersChanged?.call(jsonEncode(_favorites));

  Future<void> _saveFilter() async {
    final name = TextEditingController();
    final picked = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr(ctx, 'Save Filter')),
        content: TextField(
          key: const Key('favorite-name'),
          controller: name,
          autofocus: true,
          decoration: InputDecoration(labelText: tr(ctx, 'Name')),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(tr(ctx, 'Cancel'))),
          FilledButton(
              key: const Key('favorite-save'),
              onPressed: () => Navigator.pop(ctx, name.text),
              child: Text(tr(ctx, 'Save'))),
        ],
      ),
    );
    final label = (picked ?? '').trim();
    if (!mounted || label.isEmpty) return;
    setState(() {
      _favorites.removeWhere((f) => f['name'] == label);
      _favorites.add({'name': label, ..._snapshot()});
    });
    _storeFavorites();
  }

  Future<void> _openFavorites() async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: Text(tr(ctx, 'Favorite Filters')),
          content: SizedBox(
            width: 360,
            child: _favorites.isEmpty
                ? Text(tr(ctx, 'No saved filters yet'))
                : ListView(shrinkWrap: true, children: [
                    for (final f in _favorites)
                      ListTile(
                        key: Key('favorite-${f['name']}'),
                        dense: true,
                        title: Text('${f['name']}'),
                        onTap: () {
                          _applyFavorite(f);
                          Navigator.pop(ctx);
                        },
                        trailing: IconButton(
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () {
                            setState(() => _favorites.remove(f));
                            setLocal(() {});
                            _storeFavorites();
                          },
                        ),
                      ),
                  ]),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text(tr(ctx, 'Close'))),
          ],
        ),
      ),
    );
  }

  // The look of the back-office report manager this screen is laid out after:
  // a grey window, square bordered controls, and one blue for whatever is picked.
  static const _face = Color(0xFFF0F0F0);
  static const _edge = Color(0xFFA0A0A0);
  static const _blue = Color(0xFF0078D7);
  static const _text = TextStyle(fontSize: 13, color: Colors.black, height: 1.2);

  /// Row padding: Touch gives a finger more to hit than Mouse does.
  double get _pad => _touch ? 9 : 3;

  Widget _button(Key key, String label, VoidCallback? onTap,
          {IconData? icon, bool strong = false}) =>
      Material(
        color: const Color(0xFFE1E1E1),
        shape: Border.all(
            color: strong ? const Color(0xFF404040) : const Color(0xFFADADAD),
            width: strong ? 1.5 : 1),
        child: InkWell(
          key: key,
          onTap: onTap,
          child: Container(
            height: _touch ? 44 : 34,
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              if (icon != null) ...[
                Icon(icon, size: 16, color: Colors.black87),
                const SizedBox(width: 6),
              ],
              Flexible(
                child: Text(label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: _text.copyWith(
                        color: onTap == null ? Colors.black38 : Colors.black)),
              ),
            ]),
          ),
        ),
      );

  Widget _box(Widget child) => Container(
        decoration: BoxDecoration(
            color: Colors.white, border: Border.all(color: _edge)),
        child: child,
      );

  Widget _panelBox(Widget child) => Container(
        decoration: BoxDecoration(
            color: Colors.white, border: Border.all(color: _edge)),
        child: child,
      );

  @override
  Widget build(BuildContext context) {
    final reports = [_flash(context), ..._reports(context)];
    final layout = _rm.where((r) => 'rm-${r.id}' == _selected).firstOrNull;
    final selected = reports.where((r) => r.key == _selected).firstOrNull ??
        (layout == null
            ? null
            : _Report(
                key: 'rm-${layout.id}',
                title: layout.name,
                icon: Icons.description_outlined,
                color: Colors.black54,
              ));
    return Scaffold(
      backgroundColor: _face,
      appBar: AppBar(title: Text(tr(context, 'Reports'))),
      // Laid out left to right whatever the language: the tree on the left and
      // the sessions on the right is the screen this one is modelled on.
      body: Directionality(
        textDirection: TextDirection.ltr,
        child: DefaultTextStyle.merge(
          style: _text,
          child: Column(
            children: [
              _outputBar(context, selected),
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(width: 230, child: _tree(context, reports)),
                    Expanded(child: _filterForm(context)),
                    SizedBox(width: 260, child: _sessions(context)),
                  ],
                ),
              ),
              Container(
                width: double.infinity,
                decoration: const BoxDecoration(
                    border: Border(top: BorderSide(color: _edge))),
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                child: Text(
                    widget.staffNames[widget.ranBy] ?? widget.ranBy,
                    style: _text.copyWith(fontSize: 12)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// The strip across the top: Mouse or Touch, where the report goes, the report
  /// itself, and every report in its folder.
  Widget _outputBar(BuildContext context, _Report? selected) {
    final output = tr(context, 'Output');
    final group = _groupOf(_selected);
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 2),
      child: Row(children: [
        SizedBox(
          width: 222,
          child: Row(children: [
            Text('${tr(context, 'Mode')}:', style: _text),
            const SizedBox(width: 8),
            Expanded(
              child: _button(
                const Key('report-mode'),
                tr(context, _touch ? 'Touch' : 'Mouse'),
                () => setState(() => _touch = !_touch),
              ),
            ),
          ]),
        ),
        const SizedBox(width: 8),
        SizedBox(
          width: 170,
          child: PopupMenuButton<String>(
            key: const Key('report-output'),
            tooltip: '',
            onSelected: (v) {
              if (v == 'print') _printSummary();
            },
            itemBuilder: (ctx) => [
              CheckedPopupMenuItem(
                value: 'screen',
                checked: true,
                child: Text(tr(ctx, 'Screen')),
              ),
              if (widget.onPrint != null)
                PopupMenuItem(
                  key: const Key('print-summary'),
                  value: 'print',
                  child: Text(tr(ctx, 'Print summary')),
                ),
            ],
            child: IgnorePointer(
              child: _button(const Key('report-output-face'),
                  '$output: ${tr(context, 'Screen')}', () {}),
            ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          flex: 3,
          child: _button(
            const Key('report-run'),
            selected == null
                ? tr(context, 'Pick a report first')
                : '$output: ${selected.title}',
            selected == null ? null : _run,
            strong: true,
          ),
        ),
        const SizedBox(width: 4),
        Expanded(
          flex: 3,
          child: _button(
            const Key('report-run-group'),
            group == null
                ? tr(context, 'Output all reports')
                : '${tr(context, 'Output all reports in')} ${tr(context, group.$1)}',
            group == null || _selected == _flashKey ? null : _runGroup,
          ),
        ),
      ]),
    );
  }

  /// The folders and their reports, with the search under them.
  Widget _tree(BuildContext context, List<_Report> reports) {
    final byKey = {for (final r in reports) r.key: r};
    final filed = {for (final (_, keys) in _groups) ...keys};
    final query = _find.text.trim().toLowerCase();
    bool shown(_Report r) =>
        query.isEmpty || r.title.toLowerCase().contains(query);

    final rows = <Widget>[];
    for (var i = 0; i < _groups.length; i++) {
      final (name, keys) = _groups[i];
      final items = [
        for (final k in keys) ?byKey[k],
        // Whatever nobody filed goes in the last folder.
        if (i == _groups.length - 1)
          for (final r in reports)
            if (!filed.contains(r.key)) r,
      ].where(shown).toList();
      if (items.isEmpty) continue;
      final open = !_closed.contains(name) || query.isNotEmpty;
      rows.add(InkWell(
        key: Key('rep-group-$i'),
        onTap: () => setState(() =>
            _closed.contains(name) ? _closed.remove(name) : _closed.add(name)),
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 6, vertical: _pad),
          child: Row(children: [
            Icon(open ? Icons.folder_open : Icons.folder,
                size: 16, color: const Color(0xFFE0A800)),
            const SizedBox(width: 6),
            Expanded(
              child: Text(tr(context, name),
                  style: _text, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
          ]),
        ),
      ));
      if (!open) continue;
      for (final r in items) {
        final picked = r.key == _selected;
        rows.add(Material(
          color: picked ? _blue : Colors.white,
          child: InkWell(
            key: Key(r.key),
            onTap: () => setState(() => _selected = r.key),
            child: Padding(
              padding: EdgeInsets.fromLTRB(28, _pad, 6, _pad),
              child: Row(children: [
                Icon(r.icon, size: 15, color: r.color),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(r.title,
                      style: _text.copyWith(
                          color: picked ? Colors.white : Colors.black),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                ),
              ]),
            ),
          ),
        ));
      }
    }

    // The bundled back-office layouts, in their own folders under the till's.
    final rmGroups = {
      for (final r in _rm)
        if (query.isEmpty || r.name.toLowerCase().contains(query)) r.group,
    }.toList();
    if (rmGroups.isNotEmpty) {
      rows.add(Container(
        color: const Color(0xFFE1E1E1),
        padding: EdgeInsets.symmetric(horizontal: 6, vertical: _pad),
        child: Text(tr(context, 'Other reports'),
            style: _text.copyWith(fontSize: 12)),
      ));
    }
    for (final name in rmGroups) {
      final open = !_closed.contains('rm:$name') || query.isNotEmpty;
      rows.add(InkWell(
        key: Key('rm-group-$name'),
        onTap: () => setState(() => _closed.contains('rm:$name')
            ? _closed.remove('rm:$name')
            : _closed.add('rm:$name')),
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 6, vertical: _pad),
          child: Row(children: [
            Icon(open ? Icons.folder_open : Icons.folder,
                size: 16, color: const Color(0xFFE0A800)),
            const SizedBox(width: 6),
            Expanded(
              child: Text(name,
                  style: _text, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
          ]),
        ),
      ));
      if (!open) continue;
      for (final r in _rm) {
        if (r.group != name) continue;
        if (query.isNotEmpty && !r.name.toLowerCase().contains(query)) continue;
        final picked = 'rm-${r.id}' == _selected;
        rows.add(Material(
          color: picked ? _blue : Colors.white,
          child: InkWell(
            key: Key('rm-${r.id}'),
            onTap: () => setState(() => _selected = 'rm-${r.id}'),
            child: Padding(
              padding: EdgeInsets.fromLTRB(28, _pad, 6, _pad),
              child: Row(children: [
                Icon(Icons.description_outlined,
                    size: 15, color: picked ? Colors.white : Colors.black54),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(r.name,
                      style: _text.copyWith(
                          color: picked ? Colors.white : Colors.black),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                ),
              ]),
            ),
          ),
        ));
      }
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 6, 4, 6),
      child: Column(children: [
        Expanded(child: _panelBox(ListView(children: rows))),
        const SizedBox(height: 6),
        _box(Row(children: [
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 6),
            child: Icon(Icons.search, size: 16, color: Colors.black54),
          ),
          Expanded(
            child: TextField(
              key: const Key('report-find'),
              controller: _find,
              style: _text,
              onChanged: (_) => setState(() {}),
              decoration: _bare.copyWith(hintText: tr(context, 'Find Report')),
            ),
          ),
        ])),
      ]),
    );
  }

  static const _bare = InputDecoration(
    isDense: true,
    filled: false,
    border: InputBorder.none,
    enabledBorder: InputBorder.none,
    focusedBorder: InputBorder.none,
    contentPadding: EdgeInsets.symmetric(horizontal: 6, vertical: 8),
  );

  /// One line of the form: what is being narrowed, and the control that does it.
  /// The first line is the one the form opens on, and is marked the way a picked
  /// row is.
  Widget _field(BuildContext context, String label, Widget control,
          {bool first = false}) =>
      Container(
        color: first ? _blue : null,
        padding: EdgeInsets.fromLTRB(26, _pad + 2, 26, _pad + 2),
        child: Row(children: [
          SizedBox(
            width: 150,
            child: Text(tr(context, label),
                style: _text.copyWith(
                    color: first ? Colors.white : Colors.black),
                maxLines: 1,
                overflow: TextOverflow.ellipsis),
          ),
          Expanded(child: control),
        ]),
      );

  Widget _textField(Key key, TextEditingController c) => _box(TextField(
        key: key,
        controller: c,
        style: _text,
        cursorColor: Colors.black,
        decoration: _bare,
      ));

  Widget _drop<T>(Key key, T value, List<(T, String, Key?)> options,
          ValueChanged<T?> onChanged) =>
      _box(Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
        child: DropdownButtonHideUnderline(
          child: DropdownButton<T>(
            key: key,
            value: value,
            isDense: true,
            isExpanded: true,
            style: _text,
            dropdownColor: Colors.white,
            items: [
              for (final (v, label, itemKey) in options)
                DropdownMenuItem<T>(
                  value: v,
                  child: Text(label,
                      key: itemKey, overflow: TextOverflow.ellipsis),
                ),
            ],
            onChanged: onChanged,
          ),
        ),
      ));

  /// The middle of the screen: the period and everything a report can be
  /// narrowed by, each on its own line.
  Widget _filterForm(BuildContext context) {
    final period = _period(context);
    final (from, to) = _windowOf(period);
    final all = tr(context, 'All');
    final tenders = _tenders;
    final drivers = _driverNames;
    Widget stamp(DateTime? at) => InkWell(
          onTap: _pickCustom,
          child: _box(Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 7),
            child: Text(at == null ? '' : _stamp(at), style: _text),
          )),
        );

    // What the period line shows as picked: a preset, the custom range, or the
    // one shift picked on the right.
    final periodValue = _shiftPick != null
        ? 'session'
        : _custom != null
            ? 'custom'
            : _range.name;

    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 6, 4, 6),
      child: Column(children: [
        Expanded(
          child: Container(
            decoration: BoxDecoration(
                color: _face, border: Border.all(color: _edge)),
            child: ListView(
              children: [
                _field(
                  context,
                  'Period',
                  _drop<String>(
                    const Key('report-period'),
                    periodValue,
                    [
                      if (_shiftPick != null)
                        ('session', period.label, null),
                      for (final r in [
                        if (_shiftOpenedAt != null) ReportRange.openShift,
                        ReportRange.today,
                        ReportRange.yesterday,
                        ReportRange.last7,
                        ReportRange.all,
                      ])
                        (r.name, r.label(context), Key('period-${r.name}')),
                      (
                        'custom',
                        _custom == null ? tr(context, 'Custom') : period.label,
                        const Key('period-custom')
                      ),
                    ],
                    (v) {
                      if (v == null || v == 'session') return;
                      if (v == 'custom') {
                        _pickCustom();
                        return;
                      }
                      setState(() {
                        _range =
                            ReportRange.values.firstWhere((r) => r.name == v);
                        _custom = null;
                        _shiftPick = null;
                      });
                    },
                  ),
                  first: true,
                ),
                _field(context, 'Session start date', stamp(from)),
                _field(context, 'Session end date', stamp(to)),
                _field(
                  context,
                  'Employee',
                  _drop<String?>(
                    const Key('report-cashier-filter'),
                    _cashier,
                    [
                      (null, tr(context, 'All cashiers'), null),
                      for (final id in _cashiers)
                        (id, widget.staffNames[id] ?? id, null),
                    ],
                    (v) => setState(() => _cashier = v),
                  ),
                ),
                _field(
                  context,
                  'Revenue Center',
                  _drop<OrderType?>(
                    const Key('report-type-filter'),
                    _type,
                    [
                      (null, tr(context, 'All types'), null),
                      for (final t in OrderType.values)
                        (t, tr(context, t.label), null),
                    ],
                    (v) => setState(() => _type = v),
                  ),
                ),
                _field(context, 'Dining Area / Table',
                    _textField(const Key('report-table-filter'), _table)),
                _field(context, 'Check Number',
                    _textField(const Key('report-check-filter'), _check)),
                _field(
                  context,
                  'Payment method',
                  _drop<String?>(
                    const Key('report-tender-filter'),
                    tenders.contains(_tender) ? _tender : null,
                    [
                      (null, all, null),
                      for (final t in tenders) (t, t, null),
                    ],
                    (v) => setState(() => _tender = v),
                  ),
                ),
                _field(context, 'Customer',
                    _textField(const Key('report-customer-filter'), _customer)),
                _field(
                  context,
                  'Driver',
                  _drop<String?>(
                    const Key('report-driver-filter'),
                    drivers.contains(_driver) ? _driver : null,
                    [
                      (null, all, null),
                      for (final d in drivers) (d, d, null),
                    ],
                    (v) => setState(() => _driver = v),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 6),
        Row(children: [
          Flexible(
            child: SizedBox(
            width: 150,
            child: _button(const Key('report-clear-filters'),
                tr(context, 'Clear filters'), _clearFilters),
          )),
          const SizedBox(width: 6),
          Flexible(
            child: SizedBox(
            width: 150,
            child: _button(const Key('report-favorites'),
                tr(context, 'Favorite Filters'), _openFavorites),
          )),
          const SizedBox(width: 6),
          Flexible(
            child: SizedBox(
            width: 150,
            child: _button(const Key('report-save-filter'),
                tr(context, 'Save Filter'), _saveFilter,
                icon: Icons.save),
          )),
        ]),
      ]),
    );
  }

  /// The right of the screen: the shifts, newest first. Picking one sets the
  /// period to exactly that shift.
  Widget _sessions(BuildContext context) {
    final store = widget.shifts;
    final shifts = <Shift>[
      ?store?.currentOpenShift(),
      ...?store?.recentClosed(limit: 50),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 6, 8, 6),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Expanded(child: _sessionList(context, shifts)),
        // Today's figures under the list, read the way the page is.
        Directionality(
          textDirection: Directionality.of(this.context),
          child: TodayGlanceCard(
            allOrders: widget.allOrders,
            formatAmount: widget.formatAmount,
            openTables: widget.openTables,
            cashTenderIds: widget.cashTenderIds,
          ),
        ),
      ]),
    );
  }

  Widget _sessionList(BuildContext context, List<Shift> shifts) => _panelBox(
        Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Container(
            decoration: const BoxDecoration(
              color: Color(0xFFE1E1E1),
              border: Border(bottom: BorderSide(color: _edge)),
            ),
            padding: EdgeInsets.symmetric(vertical: _pad + 4),
            alignment: Alignment.center,
            child: Text(tr(context, 'Sessions'), style: _text),
          ),
          Expanded(
            child: ListView(children: [
              for (var i = 0; i < shifts.length; i++)
                _sessionRow(context, shifts[i], shifts.length - i),
            ]),
          ),
        ]),
      );

  Widget _sessionRow(BuildContext context, Shift shift, int number) {
    final picked = _shiftPick?.id == shift.id;
    final who = widget.staffNames[shift.cashierId] ?? shift.cashierId;
    final style = _text.copyWith(color: picked ? Colors.white : Colors.black);
    final at = shift.openedAt.toLocal();
    return Material(
      color: picked ? _blue : Colors.white,
      child: InkWell(
        key: Key('report-session-${shift.id}'),
        onTap: () => setState(() {
          _shiftPick = picked ? null : shift;
          _custom = null;
        }),
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 6, vertical: _pad),
          child: Row(children: [
            SizedBox(width: 26, child: Text('$number', style: style)),
            SizedBox(width: 78, child: Text(_day(at), style: style)),
            SizedBox(
                width: 44,
                child: Text('${_two(at.hour)}:${_two(at.minute)}',
                    style: style)),
            Expanded(
              child: Text(
                '$who${shift.closedAt == null ? ' (${tr(context, 'Open')})' : ''}',
                style: style,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ]),
        ),
      ),
    );
  }

  /// One report as the tree lists it and the hub opens it.
  _Report _tile(
    String title,
    IconData icon,
    String key,
    Color color,
    Widget Function(List<Order> orders, ReportPeriodChoice period) build,
  ) =>
      _Report(key: key, title: title, icon: icon, color: color, build: build);
}

class _Report {
  const _Report({
    required this.key,
    required this.title,
    required this.icon,
    required this.color,
    this.build,
  });

  final String key;
  final String title;
  final IconData icon;
  final Color color;

  /// Null for a report that runs its own flow (Flash).
  final Widget Function(List<Order> orders, ReportPeriodChoice period)? build;
}
