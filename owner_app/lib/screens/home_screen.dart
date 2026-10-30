import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import '../api.dart';
import '../data_scope.dart';
import '../l10n.dart';
import '../orders.dart';
import '../report_keys.dart';
import '../theme.dart';
import '../widgets/dishflow_brand.dart';
import '../widgets/dishflow_loader.dart';
import 'costs_screen.dart';
import 'order_detail_screen.dart';
import 'sales_detail_screen.dart';
import 'sales_summary_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    required this.api,
    required this.session,
    required this.locale,
    required this.onLogout,
    required this.onRefreshSession,
  });

  final OwnerApi api;
  final OwnerSession session;
  final LocaleController locale;
  final VoidCallback onLogout;
  final Future<void> Function() onRefreshSession;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late final _data = OwnerData(widget.api);
  var _period = 'today';
  String? _branchId;
  var _loading = true;

  OwnerUser get _user => widget.session.user;

  @override
  void initState() {
    super.initState();
    final branches = widget.session.branches;
    _branchId = branches.length == 1 ? branches.single.id : null;
    _reload();
  }

  Future<void> _reload() async {
    setState(() => _loading = true);
    final now = DateTime.now();
    final (from, to) = periodWindow(_period, now);
    await _data.load(branchId: _branchId, from: from, to: to);
    if (mounted) setState(() => _loading = false);
  }

  void _open(Widget page) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));
  }

  Future<void> _logout() async {
    await widget.api.logout();
    widget.onLogout();
  }

  @override
  Widget build(BuildContext context) {
    final kpis = computeKpis(_data.orders, _data.costs);
    final arabic = widget.locale.isArabic;
    final branches = widget.session.branches;
    final showMargin = _user.canOpen('costs') ||
        _user.capabilities.contains('costs');

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        backgroundColor: AppColors.background,
        body: Column(
          children: [
            _HomeHeader(
              shopName: widget.session.shopName,
              userName: _user.displayName,
              arabic: arabic,
              loading: _loading,
              onRefresh: _loading ? null : _reload,
              onToggleLocale: () {
                widget.locale.toggle();
                setState(() {});
              },
              onLogout: _logout,
            ),
            Expanded(
              child: _loading && _data.orders.isEmpty && _data.error == null
                  ? const DishflowLoadingBody()
                  : _data.error != null
                      ? _ErrorBody(error: '${_data.error}', onRetry: _reload)
                      : RefreshIndicator(
                          color: AppColors.skyDark,
                          onRefresh: _reload,
                          child: ListView(
                            padding: const EdgeInsets.fromLTRB(16, 16, 16, 28),
                            children: [
                              _PeriodBar(
                                period: _period,
                                onChanged: (p) {
                                  setState(() => _period = p);
                                  _reload();
                                },
                              ),
                              const SizedBox(height: 12),
                              _BranchScope(
                                branches: branches,
                                branchId: _branchId,
                                onChanged: (v) {
                                  setState(() => _branchId = v);
                                  _reload();
                                },
                              ),
                              const SizedBox(height: 16),
                              _HeroSalesCard(
                                label: tr(context, 'Net sales'),
                                value: money(kpis.netSales),
                                subtitle:
                                    '${kpis.orders} ${tr(context, 'Orders').toLowerCase()}',
                              ),
                              const SizedBox(height: 12),
                              _KpiGrid(items: [
                                _KpiItem(
                                  tr(context, 'Orders'),
                                  '${kpis.orders}',
                                  Icons.receipt_long_outlined,
                                ),
                                _KpiItem(
                                  tr(context, 'Average check'),
                                  money(kpis.avgCheck),
                                  Icons.payments_outlined,
                                ),
                                _KpiItem(
                                  tr(context, 'Returns'),
                                  money(kpis.refunds),
                                  Icons.undo_rounded,
                                ),
                                if (showMargin)
                                  _KpiItem(
                                    tr(context, 'Margin'),
                                    money(kpis.margin),
                                    Icons.trending_up_rounded,
                                  ),
                              ]),
                              const SizedBox(height: 22),
                              Text(
                                arabic ? 'التقارير' : 'Reports',
                                style: GoogleFonts.cairo(
                                  fontWeight: FontWeight.w700,
                                  fontSize: 15,
                                  color: AppColors.navy,
                                ),
                              ),
                              const SizedBox(height: 10),
                              if (_user.canOpen('sales_summary'))
                                _ReportTile(
                                  title: reportLabel('sales_summary',
                                      arabic: arabic),
                                  icon: Icons.summarize_outlined,
                                  onTap: () => _open(SalesSummaryScreen(
                                    orders: _data.completed,
                                  )),
                                ),
                              if (_user.canOpen('sales_detail'))
                                _ReportTile(
                                  title: reportLabel('sales_detail',
                                      arabic: arabic),
                                  icon: Icons.receipt_long_outlined,
                                  onTap: () => _open(SalesDetailScreen(
                                    orders: _data.completed,
                                    onOpen: _user.canOpen('order_detail')
                                        ? (o) =>
                                            _open(OrderDetailScreen(order: o))
                                        : null,
                                  )),
                                ),
                              if (_user.canOpen('costs'))
                                _ReportTile(
                                  title:
                                      reportLabel('costs', arabic: arabic),
                                  icon: Icons.savings_outlined,
                                  onTap: () => _open(CostsScreen(
                                    orders: _data.completed,
                                    costs: _data.costs,
                                  )),
                                ),
                            ],
                          ),
                        ),
            ),
          ],
        ),
      ),
    );
  }

}

/// Branch filter: picker when the account sees more than one; otherwise a label.
class _BranchScope extends StatelessWidget {
  const _BranchScope({
    required this.branches,
    required this.branchId,
    required this.onChanged,
  });

  final List<OwnerBranch> branches;
  final String? branchId;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    if (branches.isEmpty) {
      return Text(
        tr(context, 'No branches assigned'),
        style: GoogleFonts.cairo(color: AppColors.danger, fontSize: 13),
      );
    }
    if (branches.length == 1) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.border),
        ),
        child: Row(
          children: [
            const Icon(Icons.storefront_outlined,
                size: 20, color: AppColors.skyDark),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                branches.single.name,
                style: GoogleFonts.cairo(
                  fontWeight: FontWeight.w700,
                  color: AppColors.navy,
                ),
              ),
            ),
          ],
        ),
      );
    }
    return DropdownButtonFormField<String?>(
      key: ValueKey(branchId ?? 'all'),
      initialValue: branchId,
      decoration: InputDecoration(
        labelText: tr(context, 'Branch'),
        prefixIcon: const Icon(Icons.storefront_outlined),
        isDense: true,
      ),
      items: [
        DropdownMenuItem(
            value: null, child: Text(tr(context, 'All branches'))),
        for (final b in branches)
          DropdownMenuItem(value: b.id, child: Text(b.name)),
      ],
      onChanged: onChanged,
    );
  }
}

class _HomeHeader extends StatelessWidget {
  const _HomeHeader({
    required this.shopName,
    required this.userName,
    required this.arabic,
    required this.loading,
    required this.onRefresh,
    required this.onToggleLocale,
    required this.onLogout,
  });

  final String shopName;
  final String userName;
  final bool arabic;
  final bool loading;
  final VoidCallback? onRefresh;
  final VoidCallback onToggleLocale;
  final Future<void> Function() onLogout;

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.paddingOf(context).top;
    return Container(
      width: double.infinity,
      padding: EdgeInsets.fromLTRB(20, top + 10, 12, 20),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color(0xFF152233),
            AppColors.navy,
            Color(0xFF163247),
          ],
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: DishflowBrandMark(
                  height: 36,
                  showSubtitle: false,
                  onDark: true,
                ),
              ),
              IconButton(
                tooltip: tr(context, 'Refresh'),
                onPressed: onRefresh,
                icon: loading
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.refresh_rounded, color: Colors.white),
              ),
              TextButton(
                onPressed: onToggleLocale,
                child: Text(
                  arabic ? 'EN' : 'ع',
                  style: GoogleFonts.cairo(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              PopupMenuButton<String>(
                icon: const Icon(Icons.more_vert, color: Colors.white),
                color: Colors.white,
                onSelected: (v) async {
                  if (v == 'logout') await onLogout();
                },
                itemBuilder: (_) => [
                  PopupMenuItem(
                    value: 'logout',
                    child: Text(
                      tr(context, 'Sign out'),
                      style: GoogleFonts.cairo(fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 18),
          Text(
            shopName,
            style: GoogleFonts.cairo(
              color: Colors.white.withValues(alpha: 0.55),
              fontSize: 13,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.3,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '${tr(context, 'Welcome')}, $userName',
            style: GoogleFonts.cairo(
              color: Colors.white,
              fontSize: 22,
              fontWeight: FontWeight.w700,
              height: 1.2,
            ),
          ),
        ],
      ),
    );
  }
}

class _PeriodBar extends StatelessWidget {
  const _PeriodBar({required this.period, required this.onChanged});

  final String period;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final items = [
      ('today', tr(context, 'Today')),
      ('yesterday', tr(context, 'Yesterday')),
      ('last7', tr(context, 'Last 7 days')),
    ];
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: const Color(0xFFEEF2F7),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          for (final (key, label) in items)
            Expanded(
              child: GestureDetector(
                onTap: () => onChanged(key),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  curve: Curves.easeOut,
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  decoration: BoxDecoration(
                    color: period == key ? Colors.white : Colors.transparent,
                    borderRadius: BorderRadius.circular(11),
                    boxShadow: period == key
                        ? [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.06),
                              blurRadius: 8,
                              offset: const Offset(0, 2),
                            ),
                          ]
                        : null,
                  ),
                  child: Text(
                    label,
                    textAlign: TextAlign.center,
                    style: GoogleFonts.cairo(
                      fontSize: 13,
                      fontWeight:
                          period == key ? FontWeight.w700 : FontWeight.w500,
                      color: period == key
                          ? AppColors.navy
                          : AppColors.muted,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _HeroSalesCard extends StatelessWidget {
  const _HeroSalesCard({
    required this.label,
    required this.value,
    required this.subtitle,
  });

  final String label;
  final String value;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [AppColors.skyDark, Color(0xFF0369A1)],
        ),
        boxShadow: [
          BoxShadow(
            color: AppColors.skyDark.withValues(alpha: 0.28),
            blurRadius: 16,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(Icons.payments_outlined,
                    color: Colors.white, size: 20),
              ),
              const SizedBox(width: 10),
              Text(
                label,
                style: GoogleFonts.cairo(
                  color: Colors.white.withValues(alpha: 0.9),
                  fontWeight: FontWeight.w600,
                  fontSize: 14,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Text(
            value,
            style: GoogleFonts.cairo(
              color: Colors.white,
              fontWeight: FontWeight.w800,
              fontSize: 30,
              height: 1.1,
              letterSpacing: -0.5,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            subtitle,
            style: GoogleFonts.cairo(
              color: Colors.white.withValues(alpha: 0.7),
              fontSize: 13,
            ),
          ),
        ],
      ),
    );
  }
}

class _KpiItem {
  const _KpiItem(this.label, this.value, this.icon);
  final String label;
  final String value;
  final IconData icon;
}

class _KpiGrid extends StatelessWidget {
  const _KpiGrid({required this.items});
  final List<_KpiItem> items;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        final gap = 10.0;
        final width = (box.maxWidth - gap) / 2;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (final item in items)
              SizedBox(
                width: width,
                child: Container(
                  padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: AppColors.border),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(item.icon, size: 18, color: AppColors.skyDark),
                      const SizedBox(height: 10),
                      Text(
                        item.label,
                        style: GoogleFonts.cairo(
                          color: AppColors.muted,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        item.value,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.cairo(
                          color: AppColors.navy,
                          fontWeight: FontWeight.w800,
                          fontSize: 17,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _ReportTile extends StatelessWidget {
  const _ReportTile({
    required this.title,
    required this.icon,
    required this.onTap,
  });

  final String title;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(16),
          child: Ink(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: AppColors.border),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
              child: Row(
                children: [
                  Container(
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      color: const Color(0xFFE0F2FE),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(icon, color: AppColors.skyDark, size: 22),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      title,
                      style: GoogleFonts.cairo(
                        fontWeight: FontWeight.w700,
                        fontSize: 15,
                        color: AppColors.navy,
                      ),
                    ),
                  ),
                  Icon(
                    Icons.chevron_right_rounded,
                    color: AppColors.muted.withValues(alpha: 0.7),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ErrorBody extends StatelessWidget {
  const _ErrorBody({required this.error, required this.onRetry});
  final String error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              error,
              textAlign: TextAlign.center,
              style: GoogleFonts.cairo(color: AppColors.danger),
            ),
            const SizedBox(height: 14),
            FilledButton(
              onPressed: onRetry,
              child: Text(tr(context, 'Try again')),
            ),
          ],
        ),
      ),
    );
  }
}
