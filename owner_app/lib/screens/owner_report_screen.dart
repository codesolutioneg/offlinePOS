import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../api.dart';
import '../orders.dart';
import '../owner_report_math.dart';
import '../report_catalog.dart';
import '../sessions.dart';
import '../theme.dart';
import '../widgets/dishflow_loader.dart';
import '../widgets/owner_ui.dart';

class OwnerReportScreen extends StatefulWidget {
  const OwnerReportScreen({
    super.key,
    required this.api,
    required this.reportKey,
    required this.completed,
    required this.costs,
    required this.periodLabel,
    required this.branchLabel,
    required this.arabic,
    required this.branchId,
    required this.periodFrom,
    required this.periodTo,
    this.previous = const [],
    this.sessions = const [],
  });

  final OwnerApi api;
  final String reportKey;
  final List<OwnerOrder> completed;
  final Map<int, double> costs;
  final String periodLabel;
  final String branchLabel;
  final bool arabic;
  final String? branchId;
  final DateTime periodFrom;
  final DateTime periodTo;
  final List<OwnerOrder> previous;
  final List<OwnerSessionInfo> sessions;

  @override
  State<OwnerReportScreen> createState() => _OwnerReportScreenState();
}

class _OwnerReportScreenState extends State<OwnerReportScreen> {
  var _loading = false;
  Object? _error;
  List<({String reason, double amount, DateTime at, String? category})>
      _expenses = const [];
  List<OwnerOrder> _previous = const [];

  OwnerReportDef? get _def => ownerReportDef(widget.reportKey);

  @override
  void initState() {
    super.initState();
    _previous = widget.previous;
    _prepare();
  }

  Future<void> _prepare() async {
    final needsExpenses = widget.reportKey == 'rep-expenses';
    final needsPrev = widget.reportKey == 'rep-period-compare' &&
        widget.previous.isEmpty;
    if (!needsExpenses && !needsPrev) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      if (needsExpenses) {
        final from = widget.periodFrom.subtract(const Duration(days: 7));
        final rows = await widget.api.records(
          const ['shift'],
          branchId: widget.branchId,
          from: from,
          to: widget.periodTo,
        );
        final out =
            <({String reason, double amount, DateTime at, String? category})>[];
        for (final r in rows) {
          if (r.kind != 'shift') continue;
          final raw = r.payload['movements'];
          List list = const [];
          if (raw is String) {
            // Already decoded lists come from API; string is rare.
            continue;
          } else if (raw is List) {
            list = raw;
          }
          for (final m in list) {
            if (m is! Map) continue;
            final type = '${m['type'] ?? ''}';
            if (type != 'out') continue;
            final at = DateTime.tryParse('${m['at'] ?? ''}');
            if (at == null) continue;
            final localDay = DateTime(at.toLocal().year, at.toLocal().month,
                at.toLocal().day);
            if (localDay.isBefore(widget.periodFrom) ||
                !localDay.isBefore(widget.periodTo)) {
              continue;
            }
            out.add((
              reason: '${m['reason'] ?? ''}',
              amount: (m['amount'] as num?)?.toDouble() ?? 0,
              at: at,
              category: m['category'] as String?,
            ));
          }
        }
        out.sort((a, b) => a.at.compareTo(b.at));
        _expenses = out;
      }
      if (needsPrev) {
        final length = widget.periodTo.difference(widget.periodFrom);
        final prevFrom = widget.periodFrom.subtract(length);
        final prevTo = widget.periodFrom;
        // Fetch orders in previous window by created_at; shift-day bucketing
        // for previous is approximate (same calendar span).
        final rows = await widget.api.records(
          const ['order'],
          branchId: widget.branchId,
          from: prevFrom,
          to: prevTo.add(const Duration(days: 1)),
        );
        final byUuid = <String, OwnerOrder>{};
        for (final r in rows) {
          if (r.kind != 'order') continue;
          final o = OwnerOrder.fromRecord(r.payload, branchId: r.branchId);
          if (!o.isCompleted) continue;
          final day = DateTime(o.createdAt.toLocal().year,
              o.createdAt.toLocal().month, o.createdAt.toLocal().day);
          if (day.isBefore(prevFrom) || !day.isBefore(prevTo)) continue;
          byUuid[o.uuid] = o;
        }
        _previous = byUuid.values.toList();
      }
    } catch (e) {
      _error = e;
    }
    if (mounted) {
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final def = _def;
    final title = def?.label(arabic: widget.arabic) ?? widget.reportKey;
    final table = _loading
        ? null
        : buildOwnerReport(
            key: widget.reportKey,
            completed: widget.completed,
            costs: widget.costs,
            previous: _previous,
            expenses: _expenses,
            sessions: widget.sessions,
            arabic: widget.arabic,
          );

    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: _loading
          ? const DishflowLoadingBody()
          : _error != null
              ? Center(
                  child: Text('$_error',
                      style: const TextStyle(color: AppColors.danger)))
              : table == null || table.rows.isEmpty
                  ? EmptyHint(
                      widget.arabic
                          ? 'لا بيانات في هذه الفترة'
                          : 'No data in this period',
                      icon: def?.icon ?? Icons.inbox_outlined,
                    )
                  : ListView(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
                      children: [
                        OwnerCard(
                          padding: const EdgeInsets.all(14),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(widget.periodLabel,
                                  style: GoogleFonts.cairo(
                                      fontWeight: FontWeight.w800,
                                      color: AppColors.navy)),
                              Text(widget.branchLabel,
                                  style: GoogleFonts.cairo(
                                      color: AppColors.muted,
                                      fontWeight: FontWeight.w600,
                                      fontSize: 12)),
                              const SizedBox(height: 4),
                              Text(
                                widget.arabic
                                    ? 'حسب يوم فتح السيشن'
                                    : 'By session opening day',
                                style: GoogleFonts.cairo(
                                    color: AppColors.skyDark,
                                    fontWeight: FontWeight.w700,
                                    fontSize: 12),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 12),
                        OwnerCard(
                          padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
                          child: SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            child: ConstrainedBox(
                              constraints: BoxConstraints(
                                minWidth:
                                    MediaQuery.sizeOf(context).width - 56,
                              ),
                              child: DataTable(
                                headingRowHeight: 40,
                                dataRowMinHeight: 36,
                                dataRowMaxHeight: 52,
                                columnSpacing: 18,
                                headingTextStyle: GoogleFonts.cairo(
                                  fontWeight: FontWeight.w800,
                                  color: AppColors.muted,
                                  fontSize: 12,
                                ),
                                dataTextStyle: GoogleFonts.cairo(
                                  fontWeight: FontWeight.w600,
                                  color: AppColors.navy,
                                  fontSize: 13,
                                ),
                                columns: [
                                  for (final h in table.headers)
                                    DataColumn(label: Text(h)),
                                ],
                                rows: [
                                  for (final r in table.rows)
                                    DataRow(cells: [
                                      for (final c in r) DataCell(Text(c)),
                                    ]),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
    );
  }
}
