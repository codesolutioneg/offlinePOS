import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/i18n/l10n.dart';
import '../core/theme/app_colors.dart';
import '../domain/order.dart';
import 'branches_page.dart';
import 'reports_page.dart';
import 'site_api.dart';
import 'site_widgets.dart';
import 'users_page.dart';

enum _Period { today, yesterday, week }

typedef _Sale = ({String branchId, Order order});

class _Stats {
  double sales = 0;
  double gross = 0;
  int orders = 0;
  double refunds = 0;
  int refundCount = 0;

  double get average => orders == 0 ? 0 : gross / orders;

  void add(Order o) {
    sales += o.total;
    if (o.isRefund || o.total < 0) {
      refunds += o.total.abs();
      refundCount++;
    } else {
      gross += o.total;
      orders++;
    }
  }

  static _Stats of(Iterable<_Sale> sales) {
    final s = _Stats();
    for (final x in sales) {
      s.add(x.order);
    }
    return s;
  }
}

enum _Link { online, late, offline, none }

/// How recently a branch's tills were heard from, by its freshest one.
_Link _linkOf(Iterable<SiteDevice> devices, DateTime now) {
  DateTime? last;
  for (final d in devices) {
    final t = d.lastSyncAt ?? d.lastSeenAt;
    if (t != null && (last == null || t.isAfter(last))) last = t;
  }
  if (last == null) return devices.isEmpty ? _Link.none : _Link.offline;
  final age = now.difference(last);
  if (age < const Duration(minutes: 10)) return _Link.online;
  if (age < const Duration(hours: 2)) return _Link.late;
  return _Link.offline;
}

Color _linkColor(_Link l) => switch (l) {
      _Link.online => AppColors.success,
      _Link.late => AppColors.warning,
      _Link.offline => AppColors.error,
      _Link.none => AppColors.textMutedLight,
    };

String _ago(BuildContext context, DateTime? t, DateTime now) {
  if (t == null) return tr(context, 'Never');
  final age = now.difference(t);
  if (age < const Duration(minutes: 1)) return tr(context, 'just now');
  if (age < const Duration(hours: 1)) {
    return tr(context, '{n} min ago').replaceAll('{n}', '${age.inMinutes}');
  }
  if (age < const Duration(hours: 24)) {
    return tr(context, '{n} h ago').replaceAll('{n}', '${age.inHours}');
  }
  return siteWhen(context, t);
}

/// Amounts with thousands grouped, for the big figures.
String _grouped(double v) {
  final fixed = v.abs().toStringAsFixed(2);
  final dot = fixed.indexOf('.');
  final whole = fixed.substring(0, dot);
  final out = StringBuffer();
  for (var i = 0; i < whole.length; i++) {
    if (i > 0 && (whole.length - i) % 3 == 0) out.write(',');
    out.write(whole[i]);
  }
  return '${v < 0 ? '-' : ''}$out${fixed.substring(dot)}';
}

/// The site's front page: the period's figures across the branches the account
/// may see, how each branch and its tills are doing, and the way into the
/// reports and, for the owner, the branches and accounts.
class HomePage extends StatefulWidget {
  const HomePage({
    super.key,
    required this.api,
    required this.session,
    required this.locale,
    required this.onLogout,
    required this.onChanged,
  });

  final SiteApi api;
  final SiteSession session;
  final LocaleController locale;
  final VoidCallback onLogout;

  /// The session may have changed (a branch added or renamed): read it again.
  final VoidCallback onChanged;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  _Period _period = _Period.today;
  List<SiteBranch>? _branches;
  List<_Sale>? _current;
  List<_Sale> _previous = const [];
  Object? _error;
  DateTime? _updatedAt;
  bool _loading = true;
  int _generation = 0;
  Timer? _timer;

  SiteUser get _user => widget.session.user;

  @override
  void initState() {
    super.initState();
    _load();
    _timer = Timer.periodic(const Duration(minutes: 1), (_) => _load());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  /// The period's window and the one it is compared with: the same stretch
  /// before it, cut at the same time of day so a morning is not set against a
  /// whole day.
  ({DateTime from, DateTime to, DateTime prevFrom, DateTime prevTo}) _window(DateTime now) {
    final days = _period == _Period.week ? 7 : 1;
    final today = DateTime(now.year, now.month, now.day);
    final from = switch (_period) {
      _Period.today => today,
      _Period.yesterday => DateTime(now.year, now.month, now.day - 1),
      _Period.week => DateTime(now.year, now.month, now.day - 6),
    };
    final to = _period == _Period.yesterday ? today : DateTime(now.year, now.month, now.day + 1);
    final cut = to.isAfter(now) ? now : to;
    DateTime back(DateTime t) =>
        DateTime(t.year, t.month, t.day - days, t.hour, t.minute, t.second);
    return (from: from, to: to, prevFrom: back(from), prevTo: back(cut));
  }

  Future<void> _load() async {
    final generation = ++_generation;
    if (!_loading) setState(() => _loading = true);
    try {
      final now = DateTime.now();
      final w = _window(now);
      final branches = await widget.api.branches();
      final rows = await widget.api.records(['order'], from: w.prevFrom, to: w.to);
      final current = <_Sale>[];
      final previous = <_Sale>[];
      for (final r in rows) {
        final order = Order.fromMap(r.payload.cast<String, dynamic>());
        if (order.state != OrderState.paid && order.state != OrderState.synced) continue;
        final at = order.createdAt.toLocal();
        final sale = (branchId: r.branchId, order: order);
        if (!at.isBefore(w.from) && at.isBefore(w.to)) {
          current.add(sale);
        } else if (!at.isBefore(w.prevFrom) && at.isBefore(w.prevTo)) {
          previous.add(sale);
        }
      }
      if (!mounted || generation != _generation) return;
      setState(() {
        _branches = branches;
        _current = current;
        _previous = previous;
        _error = null;
        _updatedAt = now;
        _loading = false;
      });
    } catch (e) {
      if (e is SiteError && e.signedOut) return widget.onLogout();
      if (mounted && generation == _generation) {
        setState(() {
          _error = e;
          _loading = false;
        });
      }
    }
  }

  void _pick(_Period p) {
    if (p == _period) return;
    setState(() {
      _period = p;
      _current = null;
    });
    _load();
  }

  Future<void> _open(Widget page) async {
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));
    widget.onChanged();
    _load();
  }

  void _openReports([String? branchId]) =>
      _open(ReportsPage(api: widget.api, session: widget.session, initialBranch: branchId));

  // ── Layout ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: AppColors.background,
        appBar: _appBar(context),
        body: RefreshIndicator(
          onRefresh: _load,
          child: LayoutBuilder(builder: (context, box) {
            final wide = box.maxWidth >= 1000;
            return ListView(
              padding: EdgeInsets.symmetric(horizontal: wide ? 32 : 16, vertical: 24),
              children: [
                Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 1320),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      _header(context, wide),
                      const SizedBox(height: 24),
                      _actions(context, wide),
                      const SizedBox(height: 24),
                      if (_error != null) ...[
                        _errorBanner(context),
                        const SizedBox(height: 24),
                      ],
                      ..._body(context, wide),
                    ]),
                  ),
                ),
              ],
            );
          }),
        ),
      );

  PreferredSizeWidget _appBar(BuildContext context) {
    final theme = Theme.of(context);
    final compact = MediaQuery.sizeOf(context).width < 700;
    return AppBar(
      backgroundColor: Colors.white,
      surfaceTintColor: Colors.white,
      elevation: 0,
      scrolledUnderElevation: 1,
      titleSpacing: 24,
      automaticallyImplyLeading: false,
      title: Row(children: [
        Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            gradient: const LinearGradient(
                colors: [AppColors.primaryLight, AppColors.primaryDark]),
            borderRadius: BorderRadius.circular(10),
          ),
          child: const Icon(Icons.insights, color: Colors.white, size: 22),
        ),
        const SizedBox(width: 12),
        Flexible(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(widget.session.shopName,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
            if (!compact)
              Text(tr(context, 'Reports site'),
                  style:
                      theme.textTheme.bodySmall?.copyWith(color: AppColors.textSecondaryLight)),
          ]),
        ),
      ]),
      actions: [
        IconButton(
          key: const Key('home-refresh'),
          tooltip: tr(context, 'Refresh'),
          onPressed: _loading ? null : _load,
          icon: _loading
              ? const SizedBox.square(
                  dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.refresh),
        ),
        siteLanguageButton(context, widget.locale),
        const SizedBox(width: 4),
        PopupMenuButton<String>(
          key: const Key('site-account'),
          tooltip: _user.displayName,
          offset: const Offset(0, 48),
          onSelected: (v) {
            if (v == 'password') changePasswordDialog(context, widget.api);
            if (v == 'logout') widget.onLogout();
          },
          itemBuilder: (ctx) => [
            PopupMenuItem(
              enabled: false,
              child: Text('${_user.displayName} · ${roleLabel(ctx, _user.role)}'),
            ),
            const PopupMenuDivider(),
            PopupMenuItem(
              value: 'password',
              child: ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.key_outlined),
                title: Text(tr(ctx, 'Change password')),
              ),
            ),
            PopupMenuItem(
              key: const Key('site-logout'),
              value: 'logout',
              child: ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.logout),
                title: Text(tr(ctx, 'Sign out')),
              ),
            ),
          ],
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              CircleAvatar(
                radius: 17,
                backgroundColor: AppColors.primary.withValues(alpha: 0.12),
                child: Text(
                  _user.displayName.isEmpty ? '?' : _user.displayName.characters.first.toUpperCase(),
                  style: const TextStyle(color: AppColors.primaryDark, fontWeight: FontWeight.w700),
                ),
              ),
              if (!compact) ...[
                const SizedBox(width: 8),
                Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(_user.displayName,
                        style:
                            theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
                    Text(roleLabel(context, _user.role),
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: AppColors.textSecondaryLight)),
                  ],
                ),
              ],
              const Icon(Icons.expand_more, size: 20),
            ]),
          ),
        ),
        const SizedBox(width: 12),
      ],
    );
  }

  Widget _header(BuildContext context, bool wide) {
    final theme = Theme.of(context);
    final now = DateTime.now();
    final title = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('${tr(context, 'Welcome')}، ${_user.displayName}',
          style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700)),
      const SizedBox(height: 4),
      Text(
        [
          siteWhen(context, now).split(' ').first,
          if (_updatedAt != null)
            '${tr(context, 'Updated')} ${_ago(context, _updatedAt, now)}',
        ].join('  ·  '),
        style: theme.textTheme.bodyMedium?.copyWith(color: AppColors.textSecondaryLight),
      ),
    ]);
    final picker = SegmentedButton<_Period>(
      key: const Key('home-period'),
      showSelectedIcon: false,
      segments: [
        for (final (p, label) in const [
          (_Period.today, 'Today'),
          (_Period.yesterday, 'Yesterday'),
          (_Period.week, 'Last 7 days'),
        ])
          ButtonSegment(
              value: p, label: Text(tr(context, label), key: Key('period-${p.name}'))),
      ],
      selected: {_period},
      onSelectionChanged: (s) => _pick(s.first),
    );
    if (!wide) {
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        title,
        const SizedBox(height: 16),
        picker,
      ]);
    }
    return Row(children: [Expanded(child: title), picker]);
  }

  Widget _actions(BuildContext context, bool wide) {
    final cards = [
      _ActionCard(
        key: const Key('home-reports'),
        icon: Icons.bar_chart_rounded,
        color: AppColors.primary,
        title: tr(context, 'Reports'),
        subtitle: tr(context, "Every report from the till, in the till's design"),
        onTap: _openReports,
      ),
      _ActionCard(
        key: const Key('home-branches'),
        icon: Icons.storefront_outlined,
        color: AppColors.success,
        title: tr(context, 'Branches and tills'),
        subtitle: tr(context, 'Branches, pairing codes and how each till is doing'),
        onTap: () => _open(BranchesPage(api: widget.api, canManage: _user.isOwner)),
      ),
      if (_user.isOwner)
        _ActionCard(
          key: const Key('home-users'),
          icon: Icons.manage_accounts_outlined,
          color: AppColors.accent,
          title: tr(context, 'Users and permissions'),
          subtitle: tr(context, 'Accounts, their branches and what each may see'),
          onTap: () => _open(UsersPage(api: widget.api, me: _user)),
        ),
    ];
    return _row(cards, wide ? cards.length : 1, gap: 16);
  }

  List<Widget> _body(BuildContext context, bool wide) {
    final current = _current;
    final branches = _branches;
    if (current == null || branches == null) {
      return [
        if (_error == null)
          const Padding(
            padding: EdgeInsets.all(48),
            child: Center(child: CircularProgressIndicator()),
          ),
      ];
    }
    final now = DateTime.now();
    final stats = _Stats.of(current);
    final before = _Stats.of(_previous);
    final compare = tr(context, switch (_period) {
      _Period.today => 'vs yesterday',
      _Period.yesterday => 'vs the day before',
      _Period.week => 'vs the 7 days before',
    });
    final kpis = [
      _KpiCard(
        key: const Key('kpi-sales'),
        icon: Icons.payments_outlined,
        color: AppColors.primary,
        label: tr(context, 'Net sales'),
        value: _grouped(stats.sales),
        delta: _delta(stats.sales, before.sales),
        compare: compare,
      ),
      _KpiCard(
        key: const Key('kpi-orders'),
        icon: Icons.receipt_long_outlined,
        color: AppColors.success,
        label: tr(context, 'Orders'),
        value: '${stats.orders}',
        delta: _delta(stats.orders.toDouble(), before.orders.toDouble()),
        compare: compare,
      ),
      _KpiCard(
        key: const Key('kpi-average'),
        icon: Icons.shopping_basket_outlined,
        color: AppColors.accent,
        label: tr(context, 'Average ticket'),
        value: _grouped(stats.average),
        delta: _delta(stats.average, before.average),
        compare: compare,
      ),
      _KpiCard(
        key: const Key('kpi-refunds'),
        icon: Icons.assignment_return_outlined,
        color: AppColors.error,
        label: tr(context, 'Refunds'),
        value: _grouped(stats.refunds),
        note: '${stats.refundCount} ${tr(context, 'orders')}',
        delta: _delta(stats.refunds, before.refunds),
        compare: compare,
        upIsGood: false,
      ),
    ];

    final chart = _Panel(
      title: tr(context, _period == _Period.week ? 'Sales by day' : 'Sales by hour'),
      trailing: _peakNote(context, current),
      child: SizedBox(height: 240, child: _chart(context, current)),
    );
    final types = _Panel(title: tr(context, 'Order types'), child: _typeMix(context, current));

    final byBranch = <String, _Stats>{};
    for (final s in current) {
      (byBranch[s.branchId] ??= _Stats()).add(s.order);
    }
    final branchCards = [
      for (final b in branches)
        _BranchCard(
          key: Key('branch-card-${b.id}'),
          branch: b,
          stats: byBranch[b.id] ?? _Stats(),
          link: _linkOf(b.devices, now),
          now: now,
          onReports: () => _openReports(b.id),
        ),
    ];

    return [
      _row(kpis, wide ? 4 : 2, gap: 16),
      const SizedBox(height: 24),
      if (wide)
        IntrinsicHeight(
          child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Expanded(flex: 3, child: chart),
            const SizedBox(width: 16),
            Expanded(flex: 2, child: types),
          ]),
        )
      else ...[
        chart,
        const SizedBox(height: 16),
        types,
      ],
      const SizedBox(height: 32),
      _sectionTitle(context, tr(context, 'Branches'), '${branches.length}'),
      const SizedBox(height: 12),
      if (branches.isEmpty)
        _Panel(child: Text(tr(context, 'No branches yet')))
      else
        _row(branchCards, wide ? 3 : 1, gap: 16),
      const SizedBox(height: 32),
      _sectionTitle(context, tr(context, 'Latest orders'), null),
      const SizedBox(height: 12),
      _latest(context, current, branches),
    ];
  }

  double? _delta(double now, double before) {
    if (before == 0) return now == 0 ? 0 : null;
    return (now - before) / before.abs() * 100;
  }

  /// [children] in rows of [perRow], the last row padded so cards keep a width.
  Widget _row(List<Widget> children, int perRow, {double gap = 16}) {
    final rows = <Widget>[];
    for (var i = 0; i < children.length; i += perRow) {
      final slice = children.sublist(i, math.min(i + perRow, children.length));
      rows.add(IntrinsicHeight(
        child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          for (var j = 0; j < perRow; j++) ...[
            if (j > 0) SizedBox(width: gap),
            Expanded(child: j < slice.length ? slice[j] : const SizedBox()),
          ],
        ]),
      ));
    }
    return Column(children: [
      for (var i = 0; i < rows.length; i++) ...[
        if (i > 0) SizedBox(height: gap),
        rows[i],
      ],
    ]);
  }

  Widget _sectionTitle(BuildContext context, String title, String? count) => Row(children: [
        Text(title,
            style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
        if (count != null) ...[
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(count, style: const TextStyle(fontWeight: FontWeight.w600)),
          ),
        ],
      ]);

  Widget _errorBanner(BuildContext context) {
    final color = Theme.of(context).colorScheme.error;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(children: [
        Icon(Icons.cloud_off_outlined, color: color),
        const SizedBox(width: 12),
        Expanded(child: Text('$_error', style: TextStyle(color: color))),
        TextButton(onPressed: _load, child: Text(tr(context, 'Try again'))),
      ]),
    );
  }

  // ── Chart, order types, latest ─────────────────────────────────────────────

  ({List<double> values, List<String> labels}) _series(List<_Sale> sales) {
    if (_period == _Period.week) {
      final now = DateTime.now();
      final days = [for (var i = 6; i >= 0; i--) DateTime(now.year, now.month, now.day - i)];
      final values = List<double>.filled(7, 0);
      for (final s in sales) {
        final t = s.order.createdAt.toLocal();
        final i = days.indexWhere((d) => d.year == t.year && d.month == t.month && d.day == t.day);
        if (i >= 0) values[i] += s.order.total;
      }
      return (values: values, labels: [for (final d in days) '${d.day}/${d.month}']);
    }
    final hours = List<double>.filled(24, 0);
    for (final s in sales) {
      hours[s.order.createdAt.toLocal().hour] += s.order.total;
    }
    var first = hours.indexWhere((v) => v != 0);
    var last = hours.lastIndexWhere((v) => v != 0);
    if (first < 0) {
      first = 8;
      last = 23;
    }
    // At least a working day's width, so two busy hours do not fill the card.
    while (last - first < 11) {
      if (first > 0) first--;
      if (last - first < 11 && last < 23) last++;
      if (first == 0 && last == 23) break;
    }
    return (
      values: hours.sublist(first, last + 1),
      labels: [for (var h = first; h <= last; h++) h.toString().padLeft(2, '0')],
    );
  }

  Widget _chart(BuildContext context, List<_Sale> sales) {
    final s = _series(sales);
    final style = (Theme.of(context).textTheme.bodySmall ?? const TextStyle())
        .copyWith(color: AppColors.textMutedLight, fontSize: 11);
    return Directionality(
      textDirection: TextDirection.ltr,
      child: CustomPaint(painter: _BarsPainter(s.values, s.labels, style), size: Size.infinite),
    );
  }

  Widget? _peakNote(BuildContext context, List<_Sale> sales) {
    final s = _series(sales);
    var best = -1;
    for (var i = 0; i < s.values.length; i++) {
      if (s.values[i] > 0 && (best < 0 || s.values[i] > s.values[best])) best = i;
    }
    if (best < 0) return null;
    final label = _period == _Period.week ? s.labels[best] : '${s.labels[best]}:00';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: AppColors.warning.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.local_fire_department, size: 16, color: AppColors.warning),
        const SizedBox(width: 4),
        Text('${tr(context, _period == _Period.week ? 'Best day' : 'Peak hour')}: ',
            style: const TextStyle(fontSize: 12)),
        Text(label,
            textDirection: TextDirection.ltr,
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
      ]),
    );
  }

  Widget _typeMix(BuildContext context, List<_Sale> sales) {
    final byType = <OrderType, ({int count, double total})>{};
    var all = 0.0;
    for (final s in sales) {
      if (s.order.isRefund || s.order.total < 0) continue;
      final was = byType[s.order.type] ?? (count: 0, total: 0.0);
      byType[s.order.type] = (count: was.count + 1, total: was.total + s.order.total);
      all += s.order.total;
    }
    if (byType.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 32),
        child: Center(
          child: Text(tr(context, 'No sales in this period'),
              style: const TextStyle(color: AppColors.textSecondaryLight)),
        ),
      );
    }
    const palette = [
      AppColors.primary,
      AppColors.success,
      AppColors.warning,
      AppColors.accent,
      AppColors.pending,
      AppColors.error,
    ];
    final entries = byType.entries.toList()..sort((a, b) => b.value.total.compareTo(a.value.total));
    return Column(children: [
      for (var i = 0; i < entries.length; i++)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                    color: palette[i % palette.length], shape: BoxShape.circle),
              ),
              const SizedBox(width: 8),
              Expanded(child: Text(tr(context, entries[i].key.label))),
              Text('${entries[i].value.count}',
                  style: const TextStyle(color: AppColors.textSecondaryLight)),
              const SizedBox(width: 12),
              Text(_grouped(entries[i].value.total),
                  textDirection: TextDirection.ltr,
                  style: const TextStyle(fontWeight: FontWeight.w600)),
            ]),
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: all == 0 ? 0 : entries[i].value.total / all,
                minHeight: 8,
                backgroundColor: AppColors.surface,
                color: palette[i % palette.length],
              ),
            ),
          ]),
        ),
    ]);
  }

  Widget _latest(BuildContext context, List<_Sale> sales, List<SiteBranch> branches) {
    final theme = Theme.of(context);
    final names = {for (final b in branches) b.id: b.name};
    final showBranch = branches.length > 1;
    final rows = [...sales]..sort((a, b) => b.order.createdAt.compareTo(a.order.createdAt));
    if (rows.isEmpty) {
      return _Panel(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 24),
          child: Center(
            child: Text(tr(context, 'No sales in this period'),
                style: const TextStyle(color: AppColors.textSecondaryLight)),
          ),
        ),
      );
    }
    final head = theme.textTheme.bodySmall
        ?.copyWith(color: AppColors.textSecondaryLight, fontWeight: FontWeight.w600);
    Widget line(List<Widget> cells, {Color? color}) => Container(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 10),
          color: color,
          child: Row(children: [
            SizedBox(width: 90, child: cells[0]),
            SizedBox(width: 110, child: cells[1]),
            if (showBranch) Expanded(child: cells[2]),
            Expanded(child: cells[3]),
            SizedBox(width: 120, child: Align(alignment: AlignmentDirectional.centerEnd, child: cells[4])),
          ]),
        );
    return _Panel(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Column(children: [
        line([
          Text('#', style: head),
          Text(tr(context, 'Time'), style: head),
          Text(tr(context, 'Branch'), style: head),
          Text(tr(context, 'Type'), style: head),
          Text(tr(context, 'Total'), style: head),
        ]),
        const Divider(height: 1),
        for (final s in rows.take(10)) ...[
          line([
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: Text(s.order.displayNo,
                  textDirection: TextDirection.ltr,
                  style: const TextStyle(fontWeight: FontWeight.w600)),
            ),
            Text(_period == _Period.week
                ? siteWhen(context, s.order.createdAt).substring(5)
                : siteWhen(context, s.order.createdAt).split(' ').last),
            Text(names[s.branchId] ?? ''),
            Row(children: [
              if (s.order.isRefund) ...[
                const Icon(Icons.undo, size: 16, color: AppColors.error),
                const SizedBox(width: 4),
              ],
              Flexible(
                child: Text(tr(context, s.order.isRefund ? 'Refund' : s.order.type.label),
                    overflow: TextOverflow.ellipsis),
              ),
            ]),
            Text(_grouped(s.order.total),
                textDirection: TextDirection.ltr,
                style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: s.order.total < 0 ? AppColors.error : AppColors.textPrimaryLight)),
          ]),
          const Divider(height: 1, color: AppColors.surface),
        ],
      ]),
    );
  }
}

// ── Pieces ───────────────────────────────────────────────────────────────────

class _Panel extends StatelessWidget {
  const _Panel({
    required this.child,
    this.title,
    this.trailing,
    this.padding = const EdgeInsets.all(20),
    this.fill = false,
  });

  final Widget child;
  final String? title;
  final Widget? trailing;
  final EdgeInsets padding;

  /// Stretch [child] down the panel; only where the panel's height is bounded,
  /// as in a row of equal cards.
  final bool fill;

  @override
  Widget build(BuildContext context) => Container(
        padding: padding,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.surface),
          boxShadow: const [
            BoxShadow(color: Color(0x0A000000), blurRadius: 12, offset: Offset(0, 4)),
          ],
        ),
        child: Column(
            mainAxisSize: fill ? MainAxisSize.max : MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
          if (title != null) ...[
            Row(children: [
              Expanded(
                child: Text(title!,
                    style: Theme.of(context)
                        .textTheme
                        .titleMedium
                        ?.copyWith(fontWeight: FontWeight.w700)),
              ),
              ?trailing,
            ]),
            const SizedBox(height: 16),
          ],
          if (fill) Expanded(child: child) else child,
        ]),
      );
}

class _ActionCard extends StatefulWidget {
  const _ActionCard({
    super.key,
    required this.icon,
    required this.color,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  State<_ActionCard> createState() => _ActionCardState();
}

class _ActionCardState extends State<_ActionCard> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
              color: _hover ? widget.color.withValues(alpha: 0.5) : AppColors.surface),
          boxShadow: [
            BoxShadow(
              color: _hover ? widget.color.withValues(alpha: 0.15) : const Color(0x0A000000),
              blurRadius: _hover ? 20 : 12,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: widget.onTap,
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Row(children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: widget.color.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(widget.icon, color: widget.color, size: 26),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(widget.title,
                        style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                    const SizedBox(height: 2),
                    Text(widget.subtitle,
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: AppColors.textSecondaryLight)),
                  ]),
                ),
                Icon(Directionality.of(context) == TextDirection.rtl
                        ? Icons.chevron_left
                        : Icons.chevron_right,
                    color: AppColors.textMutedLight),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

class _KpiCard extends StatelessWidget {
  const _KpiCard({
    super.key,
    required this.icon,
    required this.color,
    required this.label,
    required this.value,
    required this.delta,
    required this.compare,
    this.note,
    this.upIsGood = true,
  });

  final IconData icon;
  final Color color;
  final String label;
  final String value;
  final double? delta;
  final String compare;
  final String? note;
  final bool upIsGood;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final d = delta;
    final good = d == null || d == 0 ? null : (d > 0) == upIsGood;
    final deltaColor = good == null
        ? AppColors.textSecondaryLight
        : good
            ? AppColors.success
            : AppColors.error;
    return _Panel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
            child: Text(label,
                style: theme.textTheme.bodyMedium?.copyWith(color: AppColors.textSecondaryLight)),
          ),
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: color, size: 20),
          ),
        ]),
        const SizedBox(height: 8),
        Text(value,
            textDirection: TextDirection.ltr,
            style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800)),
        if (note != null)
          Text(note!, style: theme.textTheme.bodySmall?.copyWith(color: AppColors.textSecondaryLight)),
        const SizedBox(height: 10),
        Row(children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: deltaColor.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              if (d != null && d != 0)
                Icon(d > 0 ? Icons.arrow_upward : Icons.arrow_downward,
                    size: 14, color: deltaColor),
              Text(d == null ? '—' : '${d.abs().toStringAsFixed(d.abs() >= 10 ? 0 : 1)}%',
                  textDirection: TextDirection.ltr,
                  style: TextStyle(
                      color: deltaColor, fontWeight: FontWeight.w700, fontSize: 12)),
            ]),
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Text(compare,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(color: AppColors.textMutedLight)),
          ),
        ]),
      ]),
    );
  }
}

class _BranchCard extends StatelessWidget {
  const _BranchCard({
    super.key,
    required this.branch,
    required this.stats,
    required this.link,
    required this.now,
    required this.onReports,
  });

  final SiteBranch branch;
  final _Stats stats;
  final _Link link;
  final DateTime now;
  final VoidCallback onReports;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = _linkColor(link);
    final status = tr(context, switch (link) {
      _Link.online => 'Online',
      _Link.late => 'Late to sync',
      _Link.offline => 'Offline',
      _Link.none => 'No till paired yet',
    });
    Widget figure(String label, String value, {Key? key}) => Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label,
                style: theme.textTheme.bodySmall?.copyWith(color: AppColors.textSecondaryLight)),
            const SizedBox(height: 2),
            Text(value,
                key: key,
                textDirection: TextDirection.ltr,
                style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
          ]),
        );
    return _Panel(
      fill: true,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: AppColors.primary.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(Icons.storefront, color: AppColors.primary),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(branch.name,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(status,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w600)),
                ),
              ]),
            ),
          ),
        ]),
        const SizedBox(height: 18),
        Row(children: [
          figure(tr(context, 'Net sales'), siteMoney(stats.sales),
              key: Key('branch-sales-${branch.id}')),
          figure(tr(context, 'Orders'), '${stats.orders}'),
          figure(tr(context, 'Average ticket'), siteMoney(stats.average)),
        ]),
        const SizedBox(height: 16),
        const Divider(height: 1, color: AppColors.surface),
        const SizedBox(height: 12),
        if (branch.devices.isEmpty)
          Text(tr(context, 'Pair a till with the code under Branches and tills'),
              style: theme.textTheme.bodySmall?.copyWith(color: AppColors.textSecondaryLight))
        else
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final d in branch.devices)
              Tooltip(
                message: '${tr(context, 'Last sync')}: ${siteWhen(context, d.lastSyncAt)}',
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: AppColors.background,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: AppColors.surface),
                  ),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.point_of_sale,
                        size: 16, color: _linkColor(_linkOf([d], now))),
                    const SizedBox(width: 6),
                    Text(d.name, style: theme.textTheme.bodySmall),
                    const SizedBox(width: 6),
                    Text(_ago(context, d.lastSyncAt, now),
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: AppColors.textMutedLight)),
                  ]),
                ),
              ),
          ]),
        const Spacer(),
        const SizedBox(height: 12),
        Align(
          alignment: AlignmentDirectional.centerEnd,
          child: OutlinedButton.icon(
            key: Key('branch-reports-${branch.id}'),
            onPressed: onReports,
            icon: const Icon(Icons.bar_chart_rounded, size: 18),
            label: Text(tr(context, 'Branch reports')),
          ),
        ),
      ]),
    );
  }
}

class _BarsPainter extends CustomPainter {
  _BarsPainter(this.values, this.labels, this.muted);

  final List<double> values;
  final List<String> labels;
  final TextStyle muted;

  @override
  void paint(Canvas canvas, Size size) {
    const axis = 22.0;
    const left = 52.0;
    final top = max == 0 ? 1.0 : _nice(max);
    final chart = Rect.fromLTRB(left, 8, size.width, size.height - axis);
    final grid = Paint()
      ..color = AppColors.surface
      ..strokeWidth = 1;

    for (var i = 0; i <= 4; i++) {
      final y = chart.bottom - chart.height * i / 4;
      canvas.drawLine(Offset(chart.left, y), Offset(chart.right, y), grid);
      _text(canvas, _short(top * i / 4), Offset(chart.left - 8, y), muted, alignEnd: true);
    }

    if (values.isEmpty) return;
    final slot = chart.width / values.length;
    final bar = math.min(slot * 0.6, 36.0);
    final peak = values.reduce(math.max);
    final every = (values.length / 12).ceil();
    for (var i = 0; i < values.length; i++) {
      final v = math.max(values[i], 0.0);
      final h = chart.height * v / top;
      final x = chart.left + slot * i + (slot - bar) / 2;
      if (h > 0) {
        final rect = Rect.fromLTWH(x, chart.bottom - h, bar, h);
        final isPeak = values[i] == peak && peak > 0;
        canvas.drawRRect(
          RRect.fromRectAndCorners(rect,
              topLeft: const Radius.circular(6), topRight: const Radius.circular(6)),
          Paint()
            ..shader = LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: isPeak
                  ? const [AppColors.warning, Color(0xFFD97706)]
                  : const [AppColors.primaryLight, AppColors.primaryDark],
            ).createShader(rect),
        );
      }
      if (i % every == 0) {
        _text(canvas, labels[i], Offset(chart.left + slot * i + slot / 2, chart.bottom + 12),
            muted, center: true);
      }
    }
  }

  double get max => values.isEmpty ? 0 : values.reduce(math.max);

  static double _nice(double v) {
    final exp = math.pow(10, (math.log(v) / math.ln10).floor()).toDouble();
    for (final m in const [1.0, 2.0, 2.5, 5.0, 10.0]) {
      if (v <= m * exp) return m * exp;
    }
    return 10 * exp;
  }

  static String _short(double v) {
    if (v >= 1000000) return '${(v / 1000000).toStringAsFixed(v % 1000000 == 0 ? 0 : 1)}M';
    if (v >= 1000) return '${(v / 1000).toStringAsFixed(v % 1000 == 0 ? 0 : 1)}k';
    return v.toStringAsFixed(0);
  }

  void _text(Canvas canvas, String s, Offset at, TextStyle style,
      {bool alignEnd = false, bool center = false}) {
    final tp = TextPainter(
      text: TextSpan(text: s, style: style),
      textDirection: TextDirection.ltr,
    )..layout();
    final dx = alignEnd ? at.dx - tp.width : (center ? at.dx - tp.width / 2 : at.dx);
    tp.paint(canvas, Offset(dx, at.dy - tp.height / 2));
  }

  @override
  bool shouldRepaint(covariant _BarsPainter old) =>
      old.values != values || old.labels != labels || old.muted != muted;
}
