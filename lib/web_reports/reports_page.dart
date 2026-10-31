import 'dart:async';

import 'package:flutter/material.dart';

import '../core/i18n/l10n.dart';
import '../features/reports/report_access.dart';
import '../features/reports/reports_hub_screen.dart';
import 'site_api.dart';
import 'site_report_data.dart';
import 'site_widgets.dart';

/// The till's reports screen, over the uploaded rows of one branch or all of
/// them, showing only the reports the signed-in account may open.
class ReportsPage extends StatefulWidget {
  const ReportsPage({super.key, required this.api, required this.session, this.initialBranch});

  final SiteApi api;
  final SiteSession session;

  /// The branch to open on; null picks for the account.
  final String? initialBranch;

  @override
  State<ReportsPage> createState() => _ReportsPageState();
}

class _ReportsPageState extends State<ReportsPage> {
  /// Null for all the branches the account may see.
  String? _branch;
  SiteReportData? _data;
  Object? _error;

  @override
  void initState() {
    super.initState();
    // One branch is the usual question; all of them is one pick away.
    final branches = widget.session.branches;
    final asked = widget.initialBranch;
    _branch = asked != null && branches.any((b) => b.id == asked)
        ? asked
        : branches.length == 1
            ? branches.single.id
            : null;
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _data = null;
      _error = null;
    });
    final data = SiteReportData(widget.api, branchId: _branch);
    try {
      await data.load();
      if (mounted) setState(() => _data = data);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  /// Fetches a window before a report reads it, with a wait spinner over the
  /// screen so a long month does not look like a dead button.
  Future<void> _prepare(SiteReportData data, DateTime? from, DateTime? to) async {
    final navigator = Navigator.of(context);
    var shown = false;
    final slow = Timer(const Duration(milliseconds: 300), () {
      if (!mounted) return;
      shown = true;
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => const Center(child: CircularProgressIndicator()),
      );
    });
    try {
      await data.prepare(from, to);
    } catch (e) {
      if (mounted) showSiteError(context, e);
      rethrow;
    } finally {
      slow.cancel();
      if (shown) navigator.pop();
    }
  }

  Widget _branchPicker(BuildContext context) {
    final branches = widget.session.branches;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String?>(
          key: const Key('reports-branch'),
          value: _branch,
          dropdownColor: Theme.of(context).colorScheme.surface,
          items: [
            if (branches.length > 1)
              DropdownMenuItem(value: null, child: Text(tr(context, 'All branches'))),
            for (final b in branches) DropdownMenuItem(value: b.id, child: Text(b.name)),
          ],
          onChanged: (v) {
            if (v == _branch) return;
            _branch = v;
            _load();
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final data = _data;
    if (data == null) {
      return Scaffold(
        appBar: AppBar(title: Text(tr(context, 'Reports')), actions: [_branchPicker(context)]),
        body: Center(
          child: _error == null
              ? const CircularProgressIndicator()
              : Column(mainAxisSize: MainAxisSize.min, children: [
                  Text('$_error', style: TextStyle(color: Theme.of(context).colorScheme.error)),
                  const SizedBox(height: 12),
                  FilledButton(onPressed: _load, child: Text(tr(context, 'Try again'))),
                ]),
        ),
      );
    }
    final caps = widget.session.user.capabilities;
    final lookups = data.lookups;
    final branchName = widget.session.branches
        .where((b) => b.id == _branch)
        .map((b) => b.name)
        .firstOrNull;
    final shop = lookups.shopName.isNotEmpty ? lookups.shopName : widget.session.shopName;
    return ReportsHubScreen(
      key: ValueKey(_branch ?? 'all'),
      actions: [_branchPicker(context)],
      allOrders: data.latestOrders(),
      shopOrders: data.latestOrders(limit: 2000),
      ordersIn: data.ordersIn,
      shopOrdersIn: data.ordersIn,
      prepare: (from, to) => _prepare(data, from, to),
      canOpen: (key) => canOpenReport(key, caps),
      cashTenderIds: lookups.cashTenderIds,
      categories: lookups.categories,
      costs: caps.contains('costs') ? lookups.costs : const {},
      formatAmount: siteMoney,
      audit: data,
      shifts: data.shifts,
      attendance: caps.contains('staff') ? data : null,
      staffNames: lookups.staffNames,
      drivers: lookups.drivers,
      shopName: branchName == null ? shop : '$shop — $branchName',
      ranBy: widget.session.user.displayName,
    );
  }
}
