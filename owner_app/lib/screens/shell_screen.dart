import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import '../analytics.dart';
import '../api.dart';
import '../data_scope.dart';
import '../flash/flash_flow.dart';
import '../l10n.dart';
import '../orders.dart';
import '../owner_controller.dart';
import '../owner_period.dart';
import '../pdf_export.dart';
import '../report_catalog.dart';
import '../report_keys.dart';
import '../theme.dart';
import '../widgets/dishflow_brand.dart';
import '../widgets/dishflow_loader.dart';
import '../widgets/owner_ui.dart';
import '../widgets/session_status.dart';
import 'costs_screen.dart';
import 'order_detail_screen.dart';
import 'owner_report_screen.dart';
import 'sales_detail_screen.dart';
import 'sales_summary_screen.dart';
import 'sessions_screen.dart';

class ShellScreen extends StatefulWidget {
  const ShellScreen({
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
  State<ShellScreen> createState() => _ShellScreenState();
}

class _ShellScreenState extends State<ShellScreen> {
  late final OwnerController _c;
  var _tab = 0;

  @override
  void initState() {
    super.initState();
    _c = OwnerController(api: widget.api, session: widget.session);
    _c.addListener(_onChanged);
    _c.reload();
  }

  @override
  void didUpdateWidget(covariant ShellScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.session.user.id != widget.session.user.id ||
        oldWidget.session.branches.length != widget.session.branches.length) {
      _c.updateSession(widget.session);
    }
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _c.removeListener(_onChanged);
    _c.dispose();
    super.dispose();
  }

  bool _can(String key) => _c.user.canOpen(key);

  List<_NavItem> get _items {
    final arabic = widget.locale.isArabic;
    return [
      _NavItem(Icons.dashboard_outlined, Icons.dashboard,
          arabic ? 'الرئيسية' : 'Home', true),
      if (_can('sales_summary') || _can('sales_detail'))
        _NavItem(Icons.point_of_sale_outlined, Icons.point_of_sale,
            arabic ? 'المبيعات' : 'Sales', true),
      if (_can('costs'))
        _NavItem(Icons.savings_outlined, Icons.savings,
            arabic ? 'التكلفة' : 'Costs', true),
      _NavItem(Icons.more_horiz, Icons.more_horiz,
          arabic ? 'المزيد' : 'More', true),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    if (_tab >= items.length) _tab = 0;
    final arabic = widget.locale.isArabic;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.dark,
      child: Scaffold(
        backgroundColor: AppColors.background,
        body: IndexedStack(
          index: _tab,
          children: [
            for (var i = 0; i < items.length; i++)
              _pageFor(items, i, arabic),
          ],
        ),
        bottomNavigationBar: Container(
          decoration: BoxDecoration(
            color: Colors.white,
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF0F172A).withValues(alpha: 0.08),
                blurRadius: 24,
                offset: const Offset(0, -8),
              ),
            ],
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: NavigationBar(
            height: 70,
            elevation: 0,
            selectedIndex: _tab,
            onDestinationSelected: (i) => setState(() => _tab = i),
            backgroundColor: Colors.transparent,
            surfaceTintColor: Colors.transparent,
            indicatorColor: AppColors.navy.withValues(alpha: 0.08),
            labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
            destinations: [
              for (final n in items)
                NavigationDestination(
                  icon: Icon(n.icon, color: AppColors.muted),
                  selectedIcon: Icon(n.activeIcon, color: AppColors.navy),
                  label: n.label,
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _pageFor(List<_NavItem> items, int i, bool arabic) {
    final label = items[i].label;
    if (i == 0) return _DashboardTab(controller: _c, locale: widget.locale);
    if (label == 'Sales' || label == 'المبيعات') {
      return _SalesTab(controller: _c, locale: widget.locale);
    }
    if (label == 'Costs' || label == 'التكلفة') {
      return _CostsTab(controller: _c, locale: widget.locale);
    }
    return _MoreTab(
      controller: _c,
      locale: widget.locale,
      api: widget.api,
      onLogout: widget.onLogout,
      onRefreshSession: () async {
        await widget.onRefreshSession();
      },
    );
  }
}

class _NavItem {
  const _NavItem(this.icon, this.activeIcon, this.label, this.visible);
  final IconData icon;
  final IconData activeIcon;
  final String label;
  final bool visible;
}

class _ShellHeader extends StatelessWidget {
  const _ShellHeader({
    required this.controller,
    required this.locale,
    required this.title,
    this.subtitle,
    this.actions = const [],
  });

  final OwnerController controller;
  final LocaleController locale;
  final String title;
  final String? subtitle;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.paddingOf(context).top;
    return Padding(
      padding: EdgeInsets.fromLTRB(20, top + 10, 12, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const DishflowBrandIcon(size: 34),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Dishflow',
                        style: GoogleFonts.cairo(
                          fontWeight: FontWeight.w800,
                          fontSize: 18,
                          color: AppColors.navy,
                          height: 1.1,
                        )),
                    Text(controller.session.shopName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.cairo(
                          color: AppColors.muted,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        )),
                  ],
                ),
              ),
              _RoundIconButton(
                onPressed: controller.loading ? null : controller.reload,
                child: controller.loading
                    ? const DishflowLoader(size: 22)
                    : const Icon(Icons.refresh_rounded, size: 20),
              ),
              const SizedBox(width: 6),
              _RoundIconButton(
                onPressed: () => locale.toggle(),
                child: Text(locale.isArabic ? 'EN' : 'ع',
                    style: GoogleFonts.cairo(
                        fontWeight: FontWeight.w800, fontSize: 12)),
              ),
              ...actions,
            ],
          ),
          const SizedBox(height: 18),
          if (subtitle != null) ...[
            Text(subtitle!,
                style: GoogleFonts.cairo(
                    color: AppColors.muted,
                    fontWeight: FontWeight.w600,
                    fontSize: 13)),
            const SizedBox(height: 2),
          ],
          Text(title,
              style: GoogleFonts.cairo(
                  color: AppColors.navy,
                  fontSize: 26,
                  fontWeight: FontWeight.w800,
                  height: 1.15,
                  letterSpacing: -0.4)),
        ],
      ),
    );
  }
}

class _RoundIconButton extends StatelessWidget {
  const _RoundIconButton({required this.child, this.onPressed});
  final Widget child;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      shape: const CircleBorder(),
      elevation: 0,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onPressed,
        child: SizedBox(width: 40, height: 40, child: Center(child: child)),
      ),
    );
  }
}

class _DashboardHero extends StatelessWidget {
  const _DashboardHero({
    required this.controller,
    required this.arabic,
    required this.onPickCustom,
  });

  final OwnerController controller;
  final bool arabic;
  final VoidCallback onPickCustom;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final kpis = c.kpis;
    final branchName = () {
      if (c.branches.isEmpty) return '—';
      if (c.branchId == null) {
        return c.branches.length == 1
            ? c.branches.single.name
            : (arabic ? 'كل الفروع' : 'All branches');
      }
      for (final b in c.branches) {
        if (b.id == c.branchId) return b.name;
      }
      return c.branchId!;
    }();

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 20),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(28),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color(0xFFFFFFFF),
            Color(0xFFF0F7FC),
            Color(0xFFE8F4FB),
          ],
        ),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF0F172A).withValues(alpha: 0.06),
            blurRadius: 28,
            offset: const Offset(0, 12),
          ),
        ],
        border: Border.all(color: Colors.white.withValues(alpha: 0.9)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: const Color(0xFFE0F2FE),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: const Icon(Icons.storefront_rounded,
                    color: AppColors.skyDark, size: 22),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(branchName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.cairo(
                            fontWeight: FontWeight.w800,
                            fontSize: 15,
                            color: AppColors.navy,
                            height: 1.1)),
                    Text(
                      arabic ? 'حسب يوم فتح السيشن' : 'By session opening day',
                      style: GoogleFonts.cairo(
                          color: AppColors.muted,
                          fontSize: 11,
                          fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
              ),
              if (c.branches.length > 1)
                TextButton(
                  onPressed: () async {
                    final next = await showModalBottomSheet<String>(
                      context: context,
                      showDragHandle: true,
                      builder: (ctx) => SafeArea(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            ListTile(
                              title: Text(arabic ? 'كل الفروع' : 'All branches',
                                  style: GoogleFonts.cairo(
                                      fontWeight: FontWeight.w700)),
                              trailing: c.branchId == null
                                  ? const Icon(Icons.check_rounded,
                                      color: AppColors.skyDark)
                                  : null,
                              onTap: () => Navigator.pop(ctx, ''),
                            ),
                            for (final b in c.branches)
                              ListTile(
                                title: Text(b.name,
                                    style: GoogleFonts.cairo(
                                        fontWeight: FontWeight.w700)),
                                trailing: c.branchId == b.id
                                    ? const Icon(Icons.check_rounded,
                                        color: AppColors.skyDark)
                                    : null,
                                onTap: () => Navigator.pop(ctx, b.id),
                              ),
                          ],
                        ),
                      ),
                    );
                    if (!context.mounted || next == null) return;
                    final id = next.isEmpty ? null : next;
                    if (id != c.branchId) c.setBranch(id);
                  },
                  child: Text(arabic ? 'تغيير' : 'Change',
                      style: GoogleFonts.cairo(
                          fontWeight: FontWeight.w800,
                          color: AppColors.skyDark)),
                ),
            ],
          ),
          const SizedBox(height: 16),
          PeriodBar(
            period: c.period,
            onChanged: c.setPeriod,
            customLabel: c.customLabel,
            arabic: arabic,
            onCustom: onPickCustom,
          ),
          const SizedBox(height: 20),
          Text(tr(context, 'Net sales'),
              style: GoogleFonts.cairo(
                  color: AppColors.muted,
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
                  letterSpacing: 0.2)),
          const SizedBox(height: 6),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: AlignmentDirectional.centerStart,
            child: Text(
              money(kpis.netSales),
              style: GoogleFonts.cairo(
                fontSize: 40,
                fontWeight: FontWeight.w800,
                color: AppColors.navy,
                height: 1.0,
                letterSpacing: -1.2,
              ),
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _HeroChip(
                icon: Icons.receipt_long_rounded,
                label:
                    '${kpis.orders} ${tr(context, 'Orders').toLowerCase()}',
              ),
              _HeroChip(
                icon: Icons.schedule_rounded,
                label: c.periodLabel(arabic: arabic),
              ),
              _HeroChip(
                icon: Icons.payments_rounded,
                label: money(kpis.avgCheck),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _HeroChip extends StatelessWidget {
  const _HeroChip({required this.icon, required this.label});
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border.withValues(alpha: 0.7)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: AppColors.skyDark),
          const SizedBox(width: 6),
          Text(label,
              style: GoogleFonts.cairo(
                  fontWeight: FontWeight.w700,
                  fontSize: 12,
                  color: AppColors.navy)),
        ],
      ),
    );
  }
}

class _DashboardTab extends StatelessWidget {
  const _DashboardTab({required this.controller, required this.locale});
  final OwnerController controller;
  final LocaleController locale;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final arabic = locale.isArabic;
    final kpis = c.kpis;
    final trend = salesTrend(c.data.completed, c.period);
    final types = salesByType(c.data.completed);
    final pays = salesByPayment(c.data.completed);

    return Column(
      children: [
        _ShellHeader(
          controller: c,
          locale: locale,
          subtitle: tr(context, 'Welcome'),
          title: c.user.displayName,
          actions: [
            const SizedBox(width: 6),
            _RoundIconButton(
              onPressed: c.loading
                  ? null
                  : () => exportOwnerPeriodPdf(
                        shopName: c.session.shopName,
                        periodLabel: c.periodLabel(arabic: arabic),
                        branchLabel: c.branchLabel(arabic: arabic),
                        kpis: kpis,
                        completed: c.data.completed,
                        arabic: arabic,
                      ),
              child: const Icon(Icons.ios_share_rounded, size: 18),
            ),
          ],
        ),
        Expanded(
          child: c.loading && c.data.completed.isEmpty && c.data.error == null
              ? const DishflowLoadingBody()
              : c.data.error != null
                  ? Center(
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                      Text('${c.data.error}',
                          style: const TextStyle(color: AppColors.danger)),
                      FilledButton(
                          onPressed: c.reload,
                          child: Text(tr(context, 'Try again'))),
                    ]))
                  : RefreshIndicator(
                      onRefresh: c.reload,
                      child: ListView(
                        padding: const EdgeInsets.fromLTRB(20, 4, 20, 28),
                        children: [
                          _DashboardHero(
                            controller: c,
                            arabic: arabic,
                            onPickCustom: () async {
                              final choice = await pickOwnerCustomDates(
                                  context,
                                  arabic: arabic);
                              if (choice == null) return;
                              c.applyPeriodChoice(choice);
                              await c.reload();
                            },
                          ),
                          const SizedBox(height: 14),
                          SessionStatusSummary(
                            sessions: c.data.sessions,
                            arabic: arabic,
                            onTap: () => Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => SessionsScreen(
                                  sessions: c.data.sessions,
                                  arabic: arabic,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 18),
                          LayoutBuilder(builder: (context, box) {
                            final w = (box.maxWidth - 12) / 2;
                            final tiles = <Widget>[
                              SizedBox(
                                width: w,
                                child: MetricTile(
                                  label: tr(context, 'Orders'),
                                  value: '${kpis.orders}',
                                  icon: Icons.receipt_long_rounded,
                                ),
                              ),
                              SizedBox(
                                width: w,
                                child: MetricTile(
                                  label: tr(context, 'Average check'),
                                  value: money(kpis.avgCheck),
                                  icon: Icons.payments_rounded,
                                  accent: AppColors.success,
                                ),
                              ),
                              SizedBox(
                                width: w,
                                child: MetricTile(
                                  label: tr(context, 'Returns'),
                                  value: money(kpis.refunds),
                                  icon: Icons.undo_rounded,
                                  accent: AppColors.danger,
                                ),
                              ),
                              if (c.user.canOpen('costs'))
                                SizedBox(
                                  width: w,
                                  child: MetricTile(
                                    label: tr(context, 'Margin'),
                                    value: money(kpis.margin),
                                    icon: Icons.trending_up_rounded,
                                    accent: const Color(0xFF7C3AED),
                                  ),
                                ),
                            ];
                            return Wrap(
                                spacing: 12, runSpacing: 12, children: tiles);
                          }),
                          const SizedBox(height: 16),
                          SalesTrendChart(
                            title: arabic
                                ? 'اتجاه المبيعات'
                                : 'Sales trend',
                            points: trend,
                          ),
                          const SizedBox(height: 12),
                          BreakdownList(
                            title: arabic
                                ? 'حسب نوع الطلب'
                                : 'By order type',
                            points: types,
                          ),
                          const SizedBox(height: 12),
                          BreakdownList(
                            title:
                                arabic ? 'حسب الدفع' : 'By payment',
                            points: pays,
                          ),
                        ],
                      ),
                    ),
        ),
      ],
    );
  }
}

class _SalesTab extends StatelessWidget {
  const _SalesTab({required this.controller, required this.locale});
  final OwnerController controller;
  final LocaleController locale;

  Future<void> _openReport(BuildContext context, String key) async {
    final c = controller;
    final arabic = locale.isArabic;
    if (key == 'rep-flash') {
      await runOwnerFlashFlow(
        context,
        api: c.api,
        branchId: c.branchId,
        shopName: c.session.shopName,
        arabic: arabic,
        fallbackOrders: c.data.completed,
        fallbackPeriodLabel: c.periodLabel(arabic: arabic),
      );
      return;
    }

    final period = await showOwnerPeriodDialog(context, arabic: arabic);
    if (!context.mounted || period == null) return;

    showDishflowLoadingDialog(context);
    List<OwnerOrder> completed = c.data.completed;
    var costs = c.data.costs;
    var sessions = c.data.sessions;
    try {
      final scoped = OwnerData(c.api);
      await scoped.load(
          branchId: c.branchId, from: period.from, to: period.to);
      completed = scoped.completed;
      costs = scoped.costs;
      sessions = scoped.sessions;
    } finally {
      if (context.mounted) {
        Navigator.of(context, rootNavigator: true).pop();
      }
    }
    if (!context.mounted) return;

    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => OwnerReportScreen(
        api: c.api,
        reportKey: key,
        completed: completed,
        costs: costs,
        periodLabel: period.label,
        branchLabel: c.branchLabel(arabic: arabic),
        arabic: arabic,
        branchId: c.branchId,
        periodFrom: period.from,
        periodTo: period.to,
        sessions: sessions,
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final arabic = locale.isArabic;
    final kpis = c.kpis;
    final defs = {for (final d in kOwnerReportDefs) d.key: d};

    return Column(
      children: [
        _ShellHeader(
          controller: c,
          locale: locale,
          subtitle: arabic
              ? 'حسب يوم فتح السيشن'
              : 'By session opening day',
          title: arabic ? 'التقارير' : 'Reports',
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
            children: [
              PeriodBar(
                period: c.period,
                onChanged: c.setPeriod,
                customLabel: c.customLabel,
                arabic: arabic,
                onCustom: () async {
                  final choice =
                      await pickOwnerCustomDates(context, arabic: arabic);
                  if (choice == null) return;
                  c.applyPeriodChoice(choice);
                  await c.reload();
                },
              ),
              const SizedBox(height: 14),
              BranchScopeBar(
                branches: c.branches,
                branchId: c.branchId,
                onChanged: c.setBranch,
              ),
              const SizedBox(height: 16),
              Text(money(kpis.netSales),
                  style: GoogleFonts.cairo(
                      fontSize: 30,
                      fontWeight: FontWeight.w800,
                      color: AppColors.navy,
                      height: 1.05,
                      letterSpacing: -0.8)),
              Text(
                '${kpis.orders} ${tr(context, 'Orders').toLowerCase()} · ${c.periodLabel(arabic: arabic)}',
                style: GoogleFonts.cairo(
                    color: AppColors.muted, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 18),
              for (final group in kOwnerReportGroups) ...[
                Row(
                  children: [
                    Container(
                      width: 34,
                      height: 34,
                      decoration: BoxDecoration(
                        color: const Color(0xFFFEF3C7),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Icon(Icons.folder_rounded,
                          color: Color(0xFFD97706), size: 18),
                    ),
                    const SizedBox(width: 10),
                    Text(group.title(arabic: arabic),
                        style: GoogleFonts.cairo(
                            fontWeight: FontWeight.w800,
                            fontSize: 16,
                            color: AppColors.navy)),
                  ],
                ),
                const SizedBox(height: 10),
                for (final key in group.keys)
                  if (c.user.canOpen(key) || c.user.isOwner)
                    if (defs[key] case final def?)
                      _LinkCard(
                        title: def.label(arabic: arabic),
                        icon: def.icon,
                        accent: def.color,
                        onTap: () => _openReport(context, key),
                      ),
                const SizedBox(height: 8),
              ],
              if (c.user.canOpen('sales_detail'))
                _LinkCard(
                  title: reportLabel('sales_detail', arabic: arabic),
                  icon: Icons.receipt_long_outlined,
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => SalesDetailScreen(
                      orders: c.data.completed,
                      onOpen: c.user.canOpen('order_detail')
                          ? (o) => Navigator.of(context).push(
                              MaterialPageRoute(
                                  builder: (_) =>
                                      OrderDetailScreen(order: o)))
                          : null,
                    ),
                  )),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _CostsTab extends StatelessWidget {
  const _CostsTab({required this.controller, required this.locale});
  final OwnerController controller;
  final LocaleController locale;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    return Column(
      children: [
        _ShellHeader(
          controller: c,
          locale: locale,
          subtitle: c.periodLabel(arabic: locale.isArabic),
          title: locale.isArabic ? 'التكلفة' : 'Costs',
        ),
        Expanded(
          child: CostsScreen(
            orders: c.data.completed,
            costs: c.data.costs,
            embedded: true,
          ),
        ),
      ],
    );
  }
}

class _MoreTab extends StatelessWidget {
  const _MoreTab({
    required this.controller,
    required this.locale,
    required this.api,
    required this.onLogout,
    required this.onRefreshSession,
  });

  final OwnerController controller;
  final LocaleController locale;
  final OwnerApi api;
  final VoidCallback onLogout;
  final Future<void> Function() onRefreshSession;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final arabic = locale.isArabic;
    return Column(
      children: [
        _ShellHeader(
          controller: c,
          locale: locale,
          subtitle: c.user.displayName,
          title: arabic ? 'المزيد' : 'More',
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
            children: [
              _LinkCard(
                title: tr(context, 'Export PDF'),
                icon: Icons.picture_as_pdf_outlined,
                onTap: () => exportOwnerPeriodPdf(
                  shopName: c.session.shopName,
                  periodLabel: c.periodLabel(arabic: arabic),
                  branchLabel: c.branchLabel(arabic: arabic),
                  kpis: c.kpis,
                  completed: c.data.completed,
                  arabic: arabic,
                ),
              ),
              if (c.user.canOpen('sales_summary'))
                _LinkCard(
                  title: reportLabel('sales_summary', arabic: arabic),
                  icon: Icons.summarize_outlined,
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) =>
                        SalesSummaryScreen(orders: c.data.completed),
                  )),
                ),
              if (c.user.canOpen('costs'))
                _LinkCard(
                  title: reportLabel('costs', arabic: arabic),
                  icon: Icons.savings_outlined,
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => CostsScreen(
                        orders: c.data.completed, costs: c.data.costs),
                  )),
                ),
              _LinkCard(
                title: tr(context, 'Sign out'),
                icon: Icons.logout,
                danger: true,
                onTap: () async {
                  await api.logout();
                  onLogout();
                },
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _LinkCard extends StatelessWidget {
  const _LinkCard({
    required this.title,
    required this.icon,
    required this.onTap,
    this.danger = false,
    this.accent,
  });

  final String title;
  final IconData icon;
  final VoidCallback onTap;
  final bool danger;
  final Color? accent;

  @override
  Widget build(BuildContext context) {
    final color = danger
        ? AppColors.danger
        : (accent ?? AppColors.skyDark);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: OwnerCard(
        onTap: onTap,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        child: Row(
          children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, color: color),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(title,
                  style: GoogleFonts.cairo(
                    fontWeight: FontWeight.w700,
                    fontSize: 15,
                    color: danger ? AppColors.danger : AppColors.navy,
                  )),
            ),
            Icon(Icons.chevron_right_rounded,
                color: AppColors.muted.withValues(alpha: 0.7)),
          ],
        ),
      ),
    );
  }
}
