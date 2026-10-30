import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/i18n/l10n.dart';
import '../core/theme/app_colors.dart';
import 'bytes_download_stub.dart'
    if (dart.library.html) 'bytes_download_web.dart';
import 'site_api.dart';
import 'site_widgets.dart';
import 'tax_eta_report_pdf.dart';
import 'tax_settings_page.dart';

enum _TaxPeriod { today, yesterday, week, all, custom }

/// Owner-only: migrated ETA receipts + submit new ones from the reports site.
class TaxUploadPage extends StatefulWidget {
  const TaxUploadPage({super.key, required this.api});

  final SiteApi api;

  @override
  State<TaxUploadPage> createState() => _TaxUploadPageState();
}

class _TaxUploadPageState extends State<TaxUploadPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  SiteTaxSettings? _settings;
  SiteTaxSummary? _summary;
  List<SiteTaxInvoice> _invoices = const [];
  List<SiteTaxPending> _pendingAll = const [];
  List<SiteTaxPaymentStat> _pendingPayments = const [];
  List<SiteTaxConnection> _connections = const [];
  var _busy = false;
  var _migrating = false;
  var _syncingPending = false;
  var _exporting = false;
  Object? _error;
  final _selected = <String>{};
  final _pmEnabled = <String>{};
  final _pmPercent = <String, double>{};
  _TaxPeriod _period = _TaxPeriod.today;
  DateTime? _from;
  DateTime? _to;
  String? _paymentFilter;
  String _uploadConnectionId = 'yFsBtvlradoAkKSascZ3';
  String? _uploadDateKey;
  String? _uploadSessionId;

  String get _connectionId =>
      _settings?.connectionId.isNotEmpty == true
          ? _settings!.connectionId
          : 'yFsBtvlradoAkKSascZ3';

  List<String> get _availableDateKeys {
    final keys = <String>{
      for (final p in _pendingAll)
        if (p.businessDateKey.trim().isNotEmpty) p.businessDateKey.trim(),
    };
    final list = keys.toList()..sort((a, b) => b.compareTo(a));
    return list;
  }

  List<({String id, int count, double amount})> get _sessionsForDate {
    final date = _uploadDateKey;
    if (date == null) return const [];
    final map = <String, ({int count, double amount})>{};
    for (final p in _pendingAll) {
      if (p.businessDateKey != date) continue;
      final sid = p.sessionId.trim().isEmpty ? '—' : p.sessionId.trim();
      final cur = map[sid] ?? (count: 0, amount: 0.0);
      map[sid] = (count: cur.count + 1, amount: cur.amount + p.amount);
    }
    final list = [
      for (final e in map.entries)
        (id: e.key, count: e.value.count, amount: e.value.amount),
    ]..sort((a, b) => a.id.compareTo(b.id));
    return list;
  }

  List<SiteTaxPending> get _sessionPending {
    final date = _uploadDateKey;
    final session = _uploadSessionId;
    if (date == null || session == null) return const [];
    return [
      for (final p in _pendingAll)
        if (p.businessDateKey == date &&
            (p.sessionId.trim().isEmpty ? '—' : p.sessionId.trim()) == session)
          p,
    ];
  }

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this);
    _tabs.addListener(() {
      if (!_tabs.indexIsChanging) setState(() {});
    });
    _applyPeriod(_TaxPeriod.today, reload: false);
    _bootstrap();
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  void _applyPeriod(_TaxPeriod p, {bool reload = true}) {
    final now = DateTime.now();
    final today = DateTime.utc(now.year, now.month, now.day);
    setState(() {
      _period = p;
      switch (p) {
        case _TaxPeriod.today:
          _from = today;
          _to = today.add(const Duration(days: 1));
        case _TaxPeriod.yesterday:
          _from = today.subtract(const Duration(days: 1));
          _to = today;
        case _TaxPeriod.week:
          _from = today.subtract(const Duration(days: 6));
          _to = today.add(const Duration(days: 1));
        case _TaxPeriod.all:
          _from = null;
          _to = null;
        case _TaxPeriod.custom:
          break;
      }
    });
    if (reload) _reloadSubmitted();
  }

  Future<void> _bootstrap() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final settings = await widget.api.taxSettings();
      if (!mounted) return;
      setState(() {
        _settings = settings;
        if (settings.connectionId.isNotEmpty) {
          _uploadConnectionId = settings.connectionId;
        }
      });
      await Future.wait([_loadSubmitted(), _loadConnections(), _loadPending()]);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _reloadSubmitted() async {
    setState(() => _busy = true);
    try {
      await _loadSubmitted();
    } catch (e) {
      if (mounted) showSiteError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _loadSubmitted() async {
    final summary = await widget.api.taxSummary(
      connectionId: _connectionId,
      from: _from,
      to: _to,
      payment: _paymentFilter,
    );
    final list = await widget.api.taxInvoices(
      connectionId: _connectionId,
      from: _from,
      to: _to,
      payment: _paymentFilter,
      limit: 200,
    );
    if (!mounted) return;
    setState(() {
      _summary = summary;
      _invoices = list.invoices;
    });
  }

  Future<void> _loadConnections() async {
    final list = await widget.api.taxConnections();
    if (!mounted) return;
    setState(() {
      _connections = list;
      if (list.isNotEmpty &&
          !list.any((c) => c.connectionId == _uploadConnectionId)) {
        _uploadConnectionId = list.first.connectionId;
      }
    });
  }

  Future<void> _loadPending() async {
    final page =
        await widget.api.taxPending(connectionId: _uploadConnectionId);
    if (!mounted) return;
    setState(() {
      _pendingAll = page.pending;
      _rebuildDateSessionAndPayments();
    });
  }

  void _rebuildDateSessionAndPayments() {
    final dates = _availableDateKeys;
    if (_uploadDateKey == null || !dates.contains(_uploadDateKey)) {
      _uploadDateKey = dates.isEmpty ? null : dates.first;
    }
    final sessions = _sessionsForDate;
    if (_uploadSessionId == null ||
        !sessions.any((s) => s.id == _uploadSessionId)) {
      _uploadSessionId = sessions.length == 1 ? sessions.first.id : null;
    }
    _rebuildPaymentsFromSession();
  }

  void _rebuildPaymentsFromSession() {
    final pool = _sessionPending;
    final pmMap = <String, SiteTaxPaymentStat>{};
    for (final p in pool) {
      final key = p.paymentMethod;
      final cur = pmMap[key];
      pmMap[key] = SiteTaxPaymentStat(
        paymentMethod: key,
        count: (cur?.count ?? 0) + 1,
        amount: (cur?.amount ?? 0) + p.amount,
      );
    }
    _pendingPayments = pmMap.values.toList()
      ..sort((a, b) => b.amount.compareTo(a.amount));
    final known = {for (final p in _pendingPayments) p.paymentMethod};
    _pmEnabled.removeWhere((pm) => !known.contains(pm));
    _pmPercent.removeWhere((pm, _) => !known.contains(pm));
    for (final p in _pendingPayments) {
      _pmPercent.putIfAbsent(p.paymentMethod, () => 100);
      _pmEnabled.add(p.paymentMethod);
    }
    _selected.removeWhere((id) => !pool.any((p) => p.id == id));
    _applyPercentSelection();
  }

  /// Dishflow-style: for each enabled PM in the selected session.
  void _applyPercentSelection() {
    _selected.clear();
    final sessionPool = _sessionPending;
    for (final pm in _pmEnabled) {
      final pool = [
        for (final p in sessionPool)
          if (p.paymentMethod == pm) p,
      ];
      if (pool.isEmpty) continue;
      final pct = _pmPercent[pm] ?? 100;
      if (pct <= 0) continue;
      if (pct >= 100) {
        _selected.addAll(pool.map((p) => p.id));
        continue;
      }
      final total = pool.fold<double>(0, (s, p) => s + p.amount);
      final target = total * pct / 100;
      final sorted = [...pool]..sort((a, b) => a.amount.compareTo(b.amount));
      var running = 0.0;
      for (final o in sorted) {
        if (running + o.amount <= target + 0.005) {
          running += o.amount;
          _selected.add(o.id);
        }
      }
    }
  }

  ({int count, double amount}) _willSendFor(String pm) {
    final pool = [
      for (final p in _sessionPending)
        if (p.paymentMethod == pm) p,
    ];
    final picked = pool.where((p) => _selected.contains(p.id));
    return (
      count: picked.length,
      amount: picked.fold<double>(0, (s, p) => s + p.amount),
    );
  }

  String _sessionLabel(String id) {
    if (id == '—') return tr(context, 'No session id');
    final lower = id.toLowerCase();
    if (lower.contains('morning')) return tr(context, 'Morning session');
    if (lower.contains('evening')) return tr(context, 'Evening session');
    if (lower.contains('night')) return tr(context, 'Night session');
    return id;
  }

  Future<void> _syncPending() async {
    if (_syncingPending) return;
    setState(() => _syncingPending = true);
    try {
      final r =
          await widget.api.taxSyncPending(connectionId: _uploadConnectionId);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(tr(context,
                'Synced {scanned} pending ({inserted} new, {updated} updated)')
            .replaceAll('{scanned}', '${r.scanned}')
            .replaceAll('{inserted}', '${r.inserted}')
            .replaceAll('{updated}', '${r.updated}')),
      ));
      await Future.wait([_loadPending(), _loadConnections()]);
    } catch (e) {
      if (mounted) showSiteError(context, e);
    } finally {
      if (mounted) setState(() => _syncingPending = false);
    }
  }

  Future<void> _migrate() async {
    if (_migrating) return;
    setState(() => _migrating = true);
    try {
      final r = await widget.api.taxMigrate(connectionId: _connectionId);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(tr(context,
                'Migrated {scanned} invoices ({inserted} new, {updated} updated)')
            .replaceAll('{scanned}', '${r.scanned}')
            .replaceAll('{inserted}', '${r.inserted}')
            .replaceAll('{updated}', '${r.updated}')),
      ));
      await _loadSubmitted();
    } catch (e) {
      if (mounted) showSiteError(context, e);
    } finally {
      if (mounted) setState(() => _migrating = false);
    }
  }

  Future<void> _submitSelected() async {
    if (_selected.isEmpty || _busy) return;
    final ok = await confirm(
      context,
      tr(context, 'Submit {n} receipts to ETA?')
          .replaceAll('{n}', '${_selected.length}'),
    );
    if (!ok || !mounted) return;
    setState(() => _busy = true);
    try {
      final r = await widget.api.taxSubmit(
        connectionId: _uploadConnectionId,
        invoiceIds: _selected.toList(),
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(tr(context, 'Accepted {a}, rejected {r}')
            .replaceAll('{a}', '${r.accepted}')
            .replaceAll('{r}', '${r.rejected}')),
      ));
      _selected.clear();
      await Future.wait([_loadSubmitted(), _loadPending()]);
    } catch (e) {
      if (mounted) showSiteError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pickCustomRange() async {
    final now = DateTime.now();
    final range = await showDateRangePicker(
      context: context,
      firstDate: DateTime(now.year - 2),
      lastDate: DateTime(now.year + 1),
      initialDateRange: _from != null && _to != null
          ? DateTimeRange(
              start: _from!,
              end: _to!.subtract(const Duration(days: 1)),
            )
          : DateTimeRange(start: now, end: now),
    );
    if (range == null || !mounted) return;
    setState(() {
      _period = _TaxPeriod.custom;
      _from = DateTime.utc(range.start.year, range.start.month, range.start.day);
      _to = DateTime.utc(range.end.year, range.end.month, range.end.day)
          .add(const Duration(days: 1));
    });
    await _reloadSubmitted();
  }

  String get _periodLabel {
    switch (_period) {
      case _TaxPeriod.today:
        return tr(context, 'Today');
      case _TaxPeriod.yesterday:
        return tr(context, 'Yesterday');
      case _TaxPeriod.week:
        return tr(context, 'Last 7 days');
      case _TaxPeriod.all:
        return tr(context, 'All dates');
      case _TaxPeriod.custom:
        if (_from == null || _to == null) return tr(context, 'Custom range');
        final end = _to!.subtract(const Duration(days: 1));
        return '${_ymd(_from!)} → ${_ymd(end)}';
    }
  }

  String _ymd(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  Future<void> _openSettings() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => TaxSettingsPage(api: widget.api),
      ),
    );
    if (!mounted) return;
    try {
      final settings = await widget.api.taxSettings();
      setState(() {
        _settings = settings;
        if (settings.connectionId.isNotEmpty) {
          _uploadConnectionId = settings.connectionId;
        }
      });
    } catch (_) {}
  }

  String get _periodLabelForReport {
    switch (_period) {
      case _TaxPeriod.today:
        return tr(context, 'Today');
      case _TaxPeriod.yesterday:
        return tr(context, 'Yesterday');
      case _TaxPeriod.week:
        return tr(context, 'Last 7 days');
      case _TaxPeriod.all:
        return tr(context, 'All dates');
      case _TaxPeriod.custom:
        return _periodLabel;
    }
  }

  Future<void> _exportEtaReport() async {
    if (_exporting) return;
    setState(() => _exporting = true);
    try {
      final list = await widget.api.taxInvoices(
        connectionId: _connectionId,
        from: _from,
        to: _to,
        payment: _paymentFilter,
        limit: 500,
      );
      final invoices = list.invoices;
      if (invoices.isEmpty) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(tr(context, 'No data to export'))),
        );
        return;
      }
      final bytes = await buildEtaSubmittedReportPdf(
        invoices: invoices,
        branchName: _settings?.connectionName.isNotEmpty == true
            ? _settings!.connectionName
            : tr(context, 'Balkans Nasr City'),
        periodLabel: _periodLabelForReport,
      );
      final stamp = DateTime.now();
      String two(int n) => n.toString().padLeft(2, '0');
      final name =
          'ETA_History_${stamp.year}-${two(stamp.month)}-${two(stamp.day)}.pdf';
      downloadBytes(name, bytes, 'application/pdf');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr(context, 'ETA report exported'))),
      );
    } catch (e) {
      if (mounted) showSiteError(context, e);
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF1F5F9),
      appBar: AppBar(
        elevation: 0,
        backgroundColor: Colors.white,
        foregroundColor: AppColors.brandNavy,
        leading: IconButton(
          tooltip: tr(context, 'Back'),
          onPressed: () => Navigator.of(context).maybePop(),
          icon: const Icon(Icons.arrow_back_rounded),
        ),
        title: Text(
          tr(context, 'Tax upload'),
          style: const TextStyle(fontWeight: FontWeight.w800, letterSpacing: -0.2),
        ),
        actions: [
          IconButton(
            tooltip: tr(context, 'Export ETA report'),
            onPressed: _busy || _exporting ? null : _exportEtaReport,
            icon: _exporting
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.picture_as_pdf_outlined),
          ),
          IconButton(
            tooltip: tr(context, 'Tax link settings'),
            onPressed: _openSettings,
            icon: const Icon(Icons.settings_rounded),
          ),
          IconButton(
            tooltip: tr(context, 'Refresh'),
            onPressed: _busy ? null : _bootstrap,
            icon: const Icon(Icons.refresh_rounded),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFFF8FAFC), Color(0xFFEEF2F7)],
          ),
        ),
        child: _error != null && _settings == null
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text('$_error', textAlign: TextAlign.center),
                ),
              )
            : TabBarView(
                controller: _tabs,
                children: [
                  _submittedTab(),
                  _uploadTab(),
                ],
              ),
      ),
      bottomNavigationBar: NavigationBar(
        height: 68,
        backgroundColor: Colors.white,
        indicatorColor: const Color(0xFFE0F2FE),
        selectedIndex: _tabs.index.clamp(0, 1),
        onDestinationSelected: (i) => _tabs.animateTo(i),
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        destinations: [
          NavigationDestination(
            icon: const Icon(Icons.receipt_long_outlined),
            selectedIcon: const Icon(Icons.receipt_long_rounded),
            label: tr(context, 'Submitted'),
          ),
          NavigationDestination(
            icon: const Icon(Icons.cloud_upload_outlined),
            selectedIcon: const Icon(Icons.cloud_upload_rounded),
            label: tr(context, 'Upload'),
          ),
        ],
      ),
    );
  }

  Widget _shell(List<Widget> children) {
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 28),
          children: children,
        ),
      ),
    );
  }

  Widget _hint(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Text(
        text,
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: AppColors.textSecondaryLight,
              height: 1.45,
            ),
      ),
    );
  }

  Widget _sectionTitle(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10, top: 8),
      child: Text(
        text,
        style: Theme.of(context).textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w800,
              color: AppColors.brandNavy,
              letterSpacing: -0.3,
            ),
      ),
    );
  }

  Widget _panel({required Widget child}) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE2E8F0)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x0A0F172A),
            blurRadius: 18,
            offset: Offset(0, 6),
          ),
        ],
      ),
      child: child,
    );
  }

  Widget _filterField({
    required String label,
    required Widget child,
    Color? headerColor,
  }) {
    return _panel(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.2,
                color: headerColor ?? AppColors.textSecondaryLight,
              ),
            ),
            const SizedBox(height: 8),
            child,
          ],
        ),
      ),
    );
  }

  Widget _primaryButton({
    required VoidCallback? onPressed,
    required String label,
  }) {
    return FilledButton(
      onPressed: onPressed,
      style: FilledButton.styleFrom(
        backgroundColor: AppColors.brandNavy,
        foregroundColor: Colors.white,
        disabledBackgroundColor: const Color(0xFFCBD5E1),
        padding: const EdgeInsets.symmetric(vertical: 16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        elevation: 0,
      ),
      child: Text(label, style: const TextStyle(fontWeight: FontWeight.w700)),
    );
  }

  Widget _secondaryButton({
    required VoidCallback? onPressed,
    required Widget icon,
    required String label,
  }) {
    return OutlinedButton.icon(
      onPressed: onPressed,
      icon: icon,
      label: Text(label),
      style: OutlinedButton.styleFrom(
        foregroundColor: AppColors.brandNavy,
        side: const BorderSide(color: Color(0xFFCBD5E1)),
        padding: const EdgeInsets.symmetric(vertical: 16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
    );
  }

  Widget _statTile(
    String label,
    String value, {
    String? subtitle,
    Color? accent,
  }) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: accent?.withValues(alpha: 0.35) ?? const Color(0xFFE2E8F0),
          ),
          boxShadow: const [
            BoxShadow(
              color: Color(0x080F172A),
              blurRadius: 12,
              offset: Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                color: accent ?? AppColors.textSecondaryLight,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              value,
              textDirection: TextDirection.ltr,
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w800,
                color: accent ?? AppColors.brandNavy,
                letterSpacing: -0.4,
              ),
            ),
            if (subtitle != null) ...[
              const SizedBox(height: 4),
              Text(
                subtitle,
                style: const TextStyle(
                  fontSize: 11,
                  color: AppColors.textMutedLight,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _submittedTab() {
    final summary = _summary;
    final payments = summary?.byPayment ?? const <SiteTaxPaymentStat>[];

    return RefreshIndicator(
      onRefresh: () async {
        await _loadSubmitted();
      },
      child: _shell([
        _hint(tr(context, 'Import pulls receipts already sent to ETA. New uploads use the Upload tab.')),
        _filterField(
          label: tr(context, 'Branch'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                tr(context, 'Balkans Nasr City'),
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 16,
                  color: AppColors.brandNavy,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                tr(context, 'Already uploaded history'),
                style: const TextStyle(color: AppColors.textMutedLight, fontSize: 13),
              ),
            ],
          ),
        ),
        _filterField(
          label: tr(context, 'Period'),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<_TaxPeriod>(
              isExpanded: true,
              value: _period == _TaxPeriod.custom ? _TaxPeriod.custom : _period,
              items: [
                DropdownMenuItem(value: _TaxPeriod.today, child: Text(tr(context, 'Today'))),
                DropdownMenuItem(value: _TaxPeriod.yesterday, child: Text(tr(context, 'Yesterday'))),
                DropdownMenuItem(value: _TaxPeriod.week, child: Text(tr(context, 'Last 7 days'))),
                DropdownMenuItem(value: _TaxPeriod.all, child: Text(tr(context, 'All dates'))),
                DropdownMenuItem(value: _TaxPeriod.custom, child: Text(_period == _TaxPeriod.custom ? _periodLabel : tr(context, 'Custom range'))),
              ],
              onChanged: (v) async {
                if (v == null) return;
                if (v == _TaxPeriod.custom) {
                  await _pickCustomRange();
                } else {
                  _applyPeriod(v);
                }
              },
            ),
          ),
        ),
        _filterField(
          label: tr(context, 'Payment method'),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<String?>(
              isExpanded: true,
              value: _paymentFilter,
              items: [
                DropdownMenuItem(value: null, child: Text(tr(context, 'All'))),
                for (final p in payments)
                  if (p.paymentMethod.trim().isNotEmpty)
                    DropdownMenuItem(
                      value: p.paymentMethod,
                      child: Text(p.paymentMethod),
                    ),
              ],
              onChanged: (v) {
                setState(() => _paymentFilter = v);
                _reloadSubmitted();
              },
            ),
          ),
        ),
        Row(
          children: [
            Expanded(
              child: _secondaryButton(
                onPressed: _migrating ? null : _migrate,
                icon: _migrating
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.cloud_download_outlined, size: 18),
                label: tr(context, 'Import from Firebase'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _primaryButton(
                onPressed: _busy ? null : _reloadSubmitted,
                label: tr(context, 'Show results'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),
        if (summary != null) ...[
          _sectionTitle(tr(context, 'Summary')),
          Row(
            children: [
              _statTile(
                tr(context, 'Uploaded to tax'),
                siteMoney(summary.submittedAmount),
                subtitle: '${summary.submittedCount} ${tr(context, 'receipts')}',
                accent: AppColors.success,
              ),
              const SizedBox(width: 10),
              _statTile(
                tr(context, 'Total before upload'),
                siteMoney(summary.grossAmount),
                subtitle: '${summary.grossCount} ${tr(context, 'receipts')}',
              ),
              const SizedBox(width: 10),
              _statTile(
                tr(context, 'Difference'),
                siteMoney(summary.differenceAmount),
                subtitle: '${summary.differenceCount} ${tr(context, 'receipts')}',
                accent: summary.differenceAmount > 0.009
                    ? AppColors.warning
                    : AppColors.success,
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              _statTile(tr(context, 'Tax sessions'), '${summary.sessions}'),
            ],
          ),
          if (payments.isNotEmpty) ...[
            const SizedBox(height: 8),
            _sectionTitle(tr(context, 'By payment')),
            _panel(
              child: Column(
                children: [
                  for (var i = 0; i < payments.length; i++) ...[
                    if (i > 0) const Divider(height: 1, color: Color(0xFFF1F5F9)),
                    _kvRow(
                      payments[i].paymentMethod.isEmpty ? '—' : payments[i].paymentMethod,
                      '${payments[i].count} · ${siteMoney(payments[i].amount)}',
                    ),
                  ],
                ],
              ),
            ),
          ],
          _sectionTitle(tr(context, 'Tax invoices')),
          if (_busy && _invoices.isEmpty)
            const Padding(
              padding: EdgeInsets.all(32),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_invoices.isEmpty)
            Text(tr(context, 'No submitted tax invoices yet. Import from Firebase first.'))
          else
            _panel(
              child: Column(
                children: [
                  for (var i = 0; i < _invoices.length; i++) ...[
                    if (i > 0) const Divider(height: 1, color: Color(0xFFF1F5F9)),
                    _invoiceRow(_invoices[i]),
                  ],
                ],
              ),
            ),
        ],
      ]),
    );
  }

  Widget _kvRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: const TextStyle(
                fontWeight: FontWeight.w600,
                color: AppColors.brandNavy,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Text(
            value,
            textDirection: TextDirection.ltr,
            style: const TextStyle(
              fontWeight: FontWeight.w700,
              color: AppColors.textSecondaryLight,
            ),
          ),
        ],
      ),
    );
  }

  Widget _invoiceRow(SiteTaxInvoice inv) {
    final when = inv.etaSubmittedAt == null ? '' : siteWhen(context, inv.etaSubmittedAt);
    final uuid = (inv.etaUuid ?? '').isEmpty
        ? ''
        : inv.etaUuid!.substring(0, inv.etaUuid!.length.clamp(0, 10));
    return InkWell(
      onLongPress: () {
        final text = [
          inv.orderNumber,
          inv.etaUuid,
          inv.etaLongId,
        ].whereType<String>().where((s) => s.isNotEmpty).join('\n');
        Clipboard.setData(ClipboardData(text: text));
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(tr(context, 'Copied'))),
        );
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    inv.orderNumber.isEmpty ? inv.id : inv.orderNumber,
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      color: AppColors.brandNavy,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    [
                      inv.paymentMethod,
                      if (when.isNotEmpty) when,
                      if (uuid.isNotEmpty) 'uuid $uuid…',
                    ].where((s) => s.trim().isNotEmpty).join(' · '),
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: AppColors.textMutedLight,
                        ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Text(
              siteMoney(inv.amount),
              textDirection: TextDirection.ltr,
              style: const TextStyle(
                fontWeight: FontWeight.w800,
                color: AppColors.brandNavy,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sessionTile({
    required String id,
    required int count,
    required double amount,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: selected ? const Color(0xFFEFF8FF) : const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: selected ? AppColors.primary : const Color(0xFFE2E8F0),
                width: selected ? 1.5 : 1,
              ),
            ),
            child: Row(
              children: [
                Icon(
                  selected
                      ? Icons.radio_button_checked_rounded
                      : Icons.radio_button_off_rounded,
                  size: 20,
                  color: selected ? AppColors.primary : AppColors.textMutedLight,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _sessionLabel(id),
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          color: selected
                              ? AppColors.brandNavy
                              : AppColors.textPrimaryLight,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '$count · ${siteMoney(amount)}',
                        textDirection: TextDirection.ltr,
                        style: const TextStyle(
                          fontSize: 13,
                          color: AppColors.textSecondaryLight,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _uploadTab() {
    final selectedAmount = _sessionPending
        .where((p) => _selected.contains(p.id))
        .fold<double>(0, (s, p) => s + p.amount);
    final selectedList = [
      for (final p in _sessionPending)
        if (_selected.contains(p.id)) p,
    ];
    final connItems = _connections.isEmpty
        ? [
            SiteTaxConnection(
              connectionId: _uploadConnectionId,
              name: tr(context, 'Balkans Nasr City'),
            ),
          ]
        : _connections;
    final dates = _availableDateKeys;
    final sessions = _sessionsForDate;

    return _shell([
      _hint(tr(
        context,
        'Pick branch, session date, then the session — same as Dishflow. Then set a percent per payment method.',
      )),
      _filterField(
        label: tr(context, 'Branch'),
        child: DropdownButtonHideUnderline(
          child: DropdownButton<String>(
            isExpanded: true,
            value: connItems.any((c) => c.connectionId == _uploadConnectionId)
                ? _uploadConnectionId
                : connItems.first.connectionId,
            items: [
              for (final c in connItems)
                DropdownMenuItem(
                  value: c.connectionId,
                  child: Text(
                    '${c.name.isEmpty ? c.connectionId : c.name} · ${c.pending} ${tr(context, 'pending')}',
                  ),
                ),
            ],
            onChanged: (v) async {
              if (v == null) return;
              setState(() {
                _uploadConnectionId = v;
                _uploadDateKey = null;
                _uploadSessionId = null;
                _selected.clear();
                _pmEnabled.clear();
                _pmPercent.clear();
              });
              setState(() => _busy = true);
              try {
                await _loadPending();
              } catch (e) {
                if (mounted) showSiteError(context, e);
              } finally {
                if (mounted) setState(() => _busy = false);
              }
            },
          ),
        ),
      ),
      _filterField(
        label: tr(context, 'Session date'),
        child: dates.isEmpty
            ? Text(
                tr(context, 'No session dates yet. Sync pending to server first.'),
                style: const TextStyle(color: AppColors.textMutedLight),
              )
            : DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  isExpanded: true,
                  value: dates.contains(_uploadDateKey)
                      ? _uploadDateKey
                      : dates.first,
                  items: [
                    for (final d in dates)
                      DropdownMenuItem(value: d, child: Text(d)),
                  ],
                  onChanged: (v) {
                    if (v == null) return;
                    setState(() {
                      _uploadDateKey = v;
                      _uploadSessionId = null;
                      _rebuildPaymentsFromSession();
                      final s = _sessionsForDate;
                      if (s.length == 1) {
                        _uploadSessionId = s.first.id;
                        _rebuildPaymentsFromSession();
                      }
                    });
                  },
                ),
              ),
      ),
      _filterField(
        label: tr(context, 'Tax session'),
        child: _uploadDateKey == null
            ? Text(
                tr(context, 'Pick a session date first'),
                style: const TextStyle(color: AppColors.textMutedLight),
              )
            : sessions.isEmpty
                ? Text(
                    tr(context, 'No sessions on this date'),
                    style: const TextStyle(color: AppColors.textMutedLight),
                  )
                : Column(
                    children: [
                      for (final s in sessions)
                        _sessionTile(
                          id: s.id,
                          count: s.count,
                          amount: s.amount,
                          selected: _uploadSessionId == s.id,
                          onTap: () {
                            setState(() {
                              _uploadSessionId = s.id;
                              _rebuildPaymentsFromSession();
                            });
                          },
                        ),
                    ],
                  ),
      ),
      Row(
        children: [
          Expanded(
            child: _primaryButton(
              onPressed: _uploadSessionId == null || _selected.isEmpty || _busy
                  ? null
                  : _submitSelected,
              label:
                  '${tr(context, 'Submit {n}').replaceAll('{n}', '${_selected.length}')} · ${siteMoney(selectedAmount)}',
            ),
          ),
        ],
      ),
      const SizedBox(height: 10),
      _secondaryButton(
        onPressed: _syncingPending ? null : _syncPending,
        icon: _syncingPending
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.sync_rounded, size: 18),
        label: tr(context, 'Sync pending to server'),
      ),
      const SizedBox(height: 20),
      _sectionTitle(tr(context, 'Percent per payment method')),
      Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Text(
          tr(context,
              'Set threshold per payment method. 100% = all orders for that method. Lower percent picks smallest first.'),
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: AppColors.textSecondaryLight,
                height: 1.4,
              ),
        ),
      ),
      if (_uploadSessionId == null)
        Text(
          tr(context, 'Pick a session to see payment methods'),
          style: const TextStyle(color: AppColors.textMutedLight),
        )
      else if (_pendingPayments.isEmpty)
        Text(
          tr(context, 'No pending sales to upload. Sync pending to server first.'),
          style: const TextStyle(color: AppColors.textMutedLight),
        )
      else
        for (final pm in _pendingPayments) _pmPercentCard(pm),
      if (selectedList.isNotEmpty) ...[
        const SizedBox(height: 8),
        _sectionTitle(
          '${tr(context, 'Will upload')} (${selectedList.length})',
        ),
        _panel(
          child: Column(
            children: [
              for (var i = 0; i < selectedList.length; i++) ...[
                if (i > 0) const Divider(height: 1, color: Color(0xFFF1F5F9)),
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              selectedList[i].orderNumber.isEmpty
                                  ? selectedList[i].id
                                  : selectedList[i].orderNumber,
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                                color: AppColors.brandNavy,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              [
                                selectedList[i].paymentMethod,
                                if (selectedList[i].timestamp != null)
                                  siteWhen(
                                      context, selectedList[i].timestamp),
                              ].where((s) => s.trim().isNotEmpty).join(' · '),
                              style: Theme.of(context)
                                  .textTheme
                                  .bodySmall
                                  ?.copyWith(
                                    color: AppColors.textMutedLight,
                                  ),
                            ),
                          ],
                        ),
                      ),
                      Text(
                        siteMoney(selectedList[i].amount),
                        textDirection: TextDirection.ltr,
                        style: const TextStyle(
                          fontWeight: FontWeight.w800,
                          color: AppColors.brandNavy,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    ]);
  }

  Widget _pmPercentCard(SiteTaxPaymentStat pm) {
    final key = pm.paymentMethod;
    final on = _pmEnabled.contains(key);
    final pct = _pmPercent[key] ?? 100;
    final will = _willSendFor(key);
    return _panel(
      child: Column(
        children: [
          CheckboxListTile(
            value: on,
            contentPadding: const EdgeInsets.fromLTRB(8, 4, 12, 4),
            controlAffinity: ListTileControlAffinity.leading,
            activeColor: AppColors.primary,
            title: Text(
              key.isEmpty ? '—' : key,
              style: const TextStyle(
                fontWeight: FontWeight.w800,
                color: AppColors.brandNavy,
              ),
            ),
            subtitle: Text(
              '${pm.count} · ${siteMoney(pm.amount)}',
              textDirection: TextDirection.ltr,
              style: const TextStyle(
                fontWeight: FontWeight.w600,
                color: AppColors.textSecondaryLight,
              ),
            ),
            onChanged: (v) {
              setState(() {
                if (v == true) {
                  _pmEnabled.add(key);
                } else {
                  _pmEnabled.remove(key);
                }
                _applyPercentSelection();
              });
            },
          ),
          if (on)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
              child: Container(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                decoration: BoxDecoration(
                  color: const Color(0xFFF0F9FF),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: const Color(0xFFBAE6FD)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Text(
                          tr(context, 'Percent'),
                          style: const TextStyle(
                            fontWeight: FontWeight.w700,
                            color: AppColors.brandNavy,
                          ),
                        ),
                        const Spacer(),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: const Color(0xFFE2E8F0)),
                          ),
                          child: DropdownButtonHideUnderline(
                            child: DropdownButton<double>(
                              value: const [100.0, 75.0, 50.0, 25.0]
                                      .contains(pct)
                                  ? pct
                                  : 100,
                              items: const [
                                DropdownMenuItem(
                                    value: 100, child: Text('100%')),
                                DropdownMenuItem(
                                    value: 75, child: Text('75%')),
                                DropdownMenuItem(
                                    value: 50, child: Text('50%')),
                                DropdownMenuItem(
                                    value: 25, child: Text('25%')),
                              ],
                              onChanged: (v) {
                                if (v == null) return;
                                setState(() {
                                  _pmPercent[key] = v;
                                  _applyPercentSelection();
                                });
                              },
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      tr(context, 'Will send {n} · {amount}')
                          .replaceAll('{n}', '${will.count}')
                          .replaceAll('{amount}', siteMoney(will.amount)),
                      style: const TextStyle(
                        color: AppColors.primaryDark,
                        fontWeight: FontWeight.w700,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
