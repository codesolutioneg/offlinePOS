import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/db/shift_store.dart';
import '../../core/i18n/l10n.dart';
import '../../core/theme/app_colors.dart';
import '../../core/widgets/numeric_keypad.dart';
import '../../domain/shift.dart';

/// Open a shift with a float, record cash in/out, and close with an End-of-Day
/// ceremony shaped like Dishflow's session close: idle summary → blockers →
/// count → progress while syncing → done with Z totals.
class ShiftScreen extends StatefulWidget {
  const ShiftScreen({
    super.key,
    required this.store,
    this.authorizeClose,
    required this.cashierId,
    required this.formatAmount,
    this.cashMethodIds = const {},
    this.onCloseSync,
    this.onPrintReport,
    this.onZClosed,
    this.openWork,
    this.onCloseBlocked,
    this.cashVarianceTolerance = 0,
    this.expenseCategories = const ['Transport', 'Food', 'Supplies', 'Maintenance', 'Other'],
    this.onShiftOpened,
    this.onNavigateToFloor,
    this.pendingSyncCount,
    this.sessionPartnerName,
    this.onPrepareCloseSync,
    this.startCloseOnOpen = false,
  });

  /// When true and a shift is already open, jump straight into the End-of-Day
  /// close ceremony (Dishflow "End shift" from the floor).
  final bool startCloseOnOpen;

  /// Called right after a shift is opened, so the host can ask who is working this
  /// session and clock them in. Null skips the prompt.
  final VoidCallback? onShiftOpened;

  /// Leave the cash-up and go finish unfinished floor work (Dishflow's
  /// "go to tables"). Null keeps only the "Go back" action on the blockers dialog.
  final VoidCallback? onNavigateToFloor;

  /// How many paid sales are still waiting to reach Odoo. Shown as a warning on
  /// the idle card the way Dishflow names local unsynced orders before close.
  final int Function()? pendingSyncCount;

  /// Session-report customer name (Dishflow). Shown on End of Day so the cashier
  /// sees who the consolidated invoice will book under. Null means none set.
  final String? Function()? sessionPartnerName;

  /// Dishflow gate before counting cash: returns null to proceed, or an error
  /// message that blocks close (e.g. consolidated mode without a session partner).
  final Future<String?> Function()? onPrepareCloseSync;

  final ShiftStore store;
  final String cashierId;
  final String Function(double) formatAmount;

  /// The payment methods that land in the drawer, so the X/Z drawer total counts
  /// cash and leaves card and other tenders out.
  final Set<int> cashMethodIds;

  /// Pushes the shift's orders to Odoo as one batch when the shift closes, and
  /// returns a message describing the outcome. Null on a build with no server.
  final Future<String> Function()? onCloseSync;

  /// Checked BEFORE the shift is closed: returns true if the cashier may close it
  /// (their role permits it, or a manager approved). Null means no gate. Closing is
  /// irreversible, so this must pass before [ShiftStore.closeShift] runs.
  final Future<bool> Function()? authorizeClose;

  /// Prints a shift report (X or Z) to the receipt printer. Null hides the print
  /// action. Rows are (label, value) pairs.
  final Future<void> Function(String title, List<(String, String)> rows)? onPrintReport;

  /// The shift that has just closed, with the same rows the Z ticket prints, for
  /// anything that wants a copy of the day (the emailed report). Fire and forget:
  /// it runs after the close, it is never awaited, and a throw from it is caught
  /// here so it cannot reach the cashier.
  final void Function(Shift closed, List<(String, String)> rows)? onZClosed;

  /// What is still unfinished on the till, read on every build and again the moment a
  /// Z is attempted. Null means nothing is checked and the close goes straight
  /// through, which is how this screen behaved before the guard existed.
  final OpenWork Function()? openWork;

  /// A close was refused, with the reason as a short event name for the audit trail.
  /// The shift is untouched when this fires.
  final void Function(String reason)? onCloseBlocked;

  /// How far the counted drawer may sit from the expected drawer and still close.
  /// Zero, the default, means an exact match to the cent. A shop that rounds its
  /// change sets a small allowance instead; there is no override above it, because
  /// a drawer that does not add up is the one thing a Z must not paper over.
  final double cashVarianceTolerance;

  /// The buckets offered when recording a paid-out (an expense), so petty cash is
  /// categorised rather than an unexplained drawer swing.
  final List<String> expenseCategories;

  @override
  State<ShiftScreen> createState() => _ShiftScreenState();
}

enum _Phase { idle, closing, done }

class _ShiftScreenState extends State<ShiftScreen> {
  Shift? _shift;
  _Phase _phase = _Phase.idle;
  Shift? _closed;
  String? _syncMessage;
  String? _odooOrderRef;

  @override
  void initState() {
    super.initState();
    _shift = widget.store.currentOpenShift();
    if (widget.startCloseOnOpen && _shift != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_runCloseCeremony());
      });
    }
  }

  void _refresh() => setState(() => _shift = widget.store.currentOpenShift());

  /// A short local timestamp, so the shift header reads "2026-08-11 14:03" rather
  /// than a raw DateTime with microseconds.
  static String _stamp(DateTime utc) {
    final d = utc.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
  }

  Future<double?> _promptAmount(String title, {String label = 'Amount'}) async {
    // A touch number pad rather than the OS keyboard: this is a till, and a float
    // or a cash count is never negative, so a bad entry just cancels.
    final v = await promptNumber(context, title: label, decimal: true);
    return (v != null && v >= 0) ? v : null;
  }

  /// An amount plus a short reason, and for a paid-out an expense category, so a
  /// drawer swing is auditable. [categories] non-empty shows the category picker.
  Future<({double amount, String reason, String? category})?> _promptMovement(
    String title, {
    List<String> categories = const [],
  }) {
    final amountC = TextEditingController();
    final reasonC = TextEditingController();
    String? category = categories.isEmpty ? null : categories.first;
    return showDialog<({double amount, String reason, String? category})>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: Text(title),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(
              controller: amountC,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(
                  labelText: tr(ctx, 'Amount'), border: const OutlineInputBorder()),
            ),
            const SizedBox(height: 8),
            if (categories.isNotEmpty)
              DropdownButtonFormField<String>(
                initialValue: category,
                items: [
                  for (final c in categories)
                    DropdownMenuItem(value: c, child: Text(tr(ctx, c))),
                ],
                onChanged: (v) => setLocal(() => category = v),
                decoration: InputDecoration(
                    labelText: tr(ctx, 'Category'), border: const OutlineInputBorder()),
              ),
            if (categories.isNotEmpty) const SizedBox(height: 8),
            TextField(
              controller: reasonC,
              decoration: InputDecoration(
                  labelText: tr(ctx, 'Reason (optional)'), border: const OutlineInputBorder()),
            ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr(ctx, 'Cancel'))),
            FilledButton(
              onPressed: () {
                // A cash movement is a positive amount; its direction is the in/out
                // button, so a zero or negative entry is a mistake, not a reverse
                // movement that would silently swing the drawer the wrong way.
                final a = double.tryParse(amountC.text.trim());
                if (a == null || a <= 0) {
                  Navigator.pop(ctx);
                  return;
                }
                Navigator.pop(ctx,
                    (amount: a, reason: reasonC.text.trim(), category: category));
              },
              child: Text(tr(ctx, 'OK')),
            ),
          ],
        ),
      ),
    );
  }

  Widget _row(String k, String v, {bool bold = false, Color? valueColor}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(children: [
          Expanded(child: Text(k)),
          Text(v,
              style: TextStyle(
                fontWeight: bold ? FontWeight.bold : FontWeight.normal,
                color: valueColor,
              )),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    final title = switch (_phase) {
      _Phase.closing => tr(context, 'Closing session'),
      _Phase.done => tr(context, 'Session closed'),
      _Phase.idle => tr(context, 'End of Day'),
    };
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: switch (_phase) {
          _Phase.closing => _closingView(),
          _Phase.done => _doneView(),
          _Phase.idle => _shift == null ? _closedView() : _openView(_shift!),
        },
      ),
    );
  }

  Widget _closedView() {
    final previous = widget.store.recentClosed();
    return ListView(
      children: [
        const SizedBox(height: 24),
        Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(tr(context, 'No shift is open'), style: const TextStyle(fontSize: 18)),
            const SizedBox(height: 8),
            Text(
              tr(context,
                  'Open a shift first. After sales, End shift → Close session & send to Odoo.'),
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 52,
              child: FilledButton.icon(
                key: const Key('open-shift'),
                icon: const Icon(Icons.play_arrow),
                label: Text(tr(context, 'Open shift')),
                onPressed: () async {
                  final f = await _promptAmount(tr(context, 'Open shift'),
                      label: tr(context, 'Opening float'));
                  if (!mounted) return;
                  if (f != null) {
                    widget.store.openShift(openingFloat: f, cashierId: widget.cashierId);
                    widget.onShiftOpened?.call();
                    // Land on the floor right after open — that is where service starts.
                    if (widget.onNavigateToFloor != null) {
                      widget.onNavigateToFloor!();
                    } else {
                      _refresh();
                    }
                  }
                },
              ),
            ),
          ]),
        ),
        if (previous.isNotEmpty) ...[
          const SizedBox(height: 28),
          Text(tr(context, 'Previous sessions'),
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          ...previous.map(_previousSessionTile),
        ],
      ],
    );
  }

  Widget _previousSessionTile(Shift s) {
    final sum = widget.store.summary(s, cashMethodIds: widget.cashMethodIds);
    final closed = s.closedAt;
    return Card(
      key: Key('previous-session-${s.id}'),
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: const Icon(Icons.receipt_long),
        title: Text(
          closed == null ? s.id : '${tr(context, 'Closed')} ${_stamp(closed)}',
        ),
        subtitle: Text(
          '${tr(context, 'Orders')}: ${sum.salesCount}  ·  '
          '${tr(context, 'Total')}: ${widget.formatAmount(sum.salesTotal)}  ·  '
          '${tr(context, 'Cashier')}: ${s.cashierId}',
        ),
        trailing: widget.onPrintReport == null
            ? null
            : IconButton(
                key: Key('reprint-z-${s.id}'),
                tooltip: tr(context, 'Print Z'),
                icon: const Icon(Icons.print),
                onPressed: () => widget.onPrintReport!(
                    'Z Report', _rows(sum, withVariance: true)),
              ),
      ),
    );
  }

  /// Dishflow-style idle card: session header, totals, payment mix, cash drawer,
  /// unfinished-work banner, then cash movements and close.
  Widget _openView(Shift s) {
    final sum = widget.store.summary(s, cashMethodIds: widget.cashMethodIds);
    final pending = widget.pendingSyncCount?.call() ?? 0;
    final work = widget.openWork?.call();
    final scheme = Theme.of(context).colorScheme;

    return ListView(children: [
      _sessionCard(s, sum, pending: pending, work: work, scheme: scheme),
      const SizedBox(height: 16),
      Wrap(spacing: 8, children: [
        SizedBox(
          height: 52,
          child: OutlinedButton.icon(
            key: const Key('cash-in'),
            icon: const Icon(Icons.add),
            label: Text(tr(context, 'Cash in')),
            onPressed: () async {
              final m = await _promptMovement(tr(context, 'Cash in'));
              if (!mounted) return;
              if (m != null) {
                widget.store.addMovement('in', m.amount, reason: m.reason);
                _refresh();
              }
            },
          ),
        ),
        SizedBox(
          height: 52,
          child: OutlinedButton.icon(
            key: const Key('cash-out'),
            icon: const Icon(Icons.remove),
            label: Text(tr(context, 'Cash out')),
            onPressed: () async {
              final m = await _promptMovement(tr(context, 'Cash out'),
                  categories: widget.expenseCategories);
              if (!mounted) return;
              if (m != null) {
                widget.store.addMovement('out', m.amount,
                    reason: m.reason, category: m.category);
                _refresh();
              }
            },
          ),
        ),
      ]),
      if (s.movements.isNotEmpty) ...[
        const SizedBox(height: 12),
        Text(tr(context, 'Cash movements'), style: const TextStyle(fontWeight: FontWeight.bold)),
        ...s.movements.map((m) {
          final tag = m.category != null ? tr(context, m.category!) : null;
          final note = [
            ?tag,
            if (m.reason.isNotEmpty) m.reason,
          ].join(' - ');
          return _row(
            '${m.type == 'in' ? tr(context, 'In') : tr(context, 'Out')}${note.isEmpty ? '' : ' ($note)'}',
            widget.formatAmount(m.amount),
          );
        }),
      ],
      const SizedBox(height: 16),
      if (widget.onPrintReport != null)
        Wrap(spacing: 8, children: [
          OutlinedButton.icon(
            key: const Key('print-x'),
            icon: const Icon(Icons.print),
            label: Text(tr(context, 'Print X read')),
            onPressed: _printX,
          ),
          OutlinedButton.icon(
            key: const Key('cashier-flash'),
            icon: const Icon(Icons.person_outline),
            label: Text(tr(context, 'Cashier flash')),
            onPressed: _printCashierFlash,
          ),
        ]),
      const SizedBox(height: 12),
      Text(
        tr(context,
            'Full Z count stays on this till; peers close quietly without recounting.'),
        style: TextStyle(color: scheme.onSurfaceVariant),
      ),
      Text(
        tr(context,
            'Each till syncs its own Odoo outbox on close or Sync now.'),
        style: TextStyle(color: scheme.onSurfaceVariant),
      ),
    ]);
  }

  String _pendingSyncBanner(int pending) {
    final name = widget.sessionPartnerName?.call();
    if (name == null || name.isEmpty) {
      return tr(context,
          'There are $pending order(s) waiting to sync — close will push them '
          'to Odoo as one sale order using the branch session customer.');
    }
    return tr(context,
        'There are $pending order(s) waiting to sync — close will push them '
        'to Odoo as one sale order under $name.');
  }

  Widget _sessionCard(
    Shift s,
    ShiftSummary sum, {
    required int pending,
    required OpenWork? work,
    required ColorScheme scheme,
  }) {
    return Card(
      key: const Key('session-close-card'),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: AppColors.error.withValues(alpha: 0.35), width: 1.5),
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: AppColors.error.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(14),
              ),
              child: const Icon(Icons.lock, color: AppColors.error),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(tr(context, 'End of Day'),
                    style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                Text('${tr(context, 'Open since')} ${_stamp(s.openedAt)}',
                    style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
              ]),
            ),
          ]),
          const SizedBox(height: 16),
          Row(children: [
            Expanded(
              child: _statTile(
                label: tr(context, 'Total'),
                value: widget.formatAmount(sum.salesTotal),
                primary: true,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _statTile(
                label: tr(context, 'Orders'),
                value: '${sum.salesCount}',
                primary: false,
              ),
            ),
          ]),
          if (sum.tenders.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(tr(context, 'Payment mix'),
                style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            ...sum.tenders.map((t) => _row(
                  tr(context, t.label),
                  widget.formatAmount(t.amount),
                )),
          ],
          const Divider(height: 24),
          Text(tr(context, 'Cash handling'),
              style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          _row(tr(context, 'Opening float'), widget.formatAmount(sum.openingFloat)),
          _row(tr(context, 'Cash sales'), widget.formatAmount(sum.cashSales)),
          _row(tr(context, 'Cash in'), widget.formatAmount(sum.cashIn)),
          _row(tr(context, 'Cash out'), widget.formatAmount(sum.cashOut)),
          _row(tr(context, 'Expected in drawer'), widget.formatAmount(sum.expectedCash),
              bold: true),
          if (work != null && !work.isEmpty) ...[
            const SizedBox(height: 12),
            _blockerBanner(work),
          ],
          if (pending > 0) ...[
            const SizedBox(height: 12),
            Container(
              key: const Key('unsynced-warning'),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: Colors.red.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.red.withValues(alpha: 0.4)),
              ),
              child: Row(children: [
                const Icon(Icons.warning_amber, color: Colors.red, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _pendingSyncBanner(pending),
                    style: const TextStyle(fontSize: 12, color: Colors.red, height: 1.4),
                  ),
                ),
              ]),
            ),
          ],
          if ((widget.sessionPartnerName?.call() ?? '').isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              key: const Key('session-partner-label'),
              '${tr(context, 'Session invoice customer')}: '
              '${widget.sessionPartnerName!.call()}',
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
          ],
          const SizedBox(height: 16),
          SizedBox(
            height: 56,
            width: double.infinity,
            child: FilledButton.icon(
              key: const Key('close-shift'),
              style: FilledButton.styleFrom(backgroundColor: AppColors.error),
              icon: const Icon(Icons.lock),
              label: Text(pending > 0
                  ? tr(context, 'Close session & send to Odoo')
                  : tr(context, 'Close session')),
              onPressed: _runCloseCeremony,
            ),
          ),
        ]),
      ),
    );
  }

  Widget _statTile({required String label, required String value, required bool primary}) {
    final bg = primary
        ? AppColors.primary.withValues(alpha: 0.1)
        : Theme.of(context).colorScheme.surfaceContainerHighest;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label,
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            )),
        const SizedBox(height: 4),
        Text(value,
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: primary ? AppColors.primary : null,
            )),
      ]),
    );
  }

  Widget _blockerBanner(OpenWork work) => Card(
        key: const Key('close-blocked-why'),
        color: AppColors.error.withValues(alpha: 0.08),
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              const Icon(Icons.block, color: AppColors.error),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  '${tr(context, 'Cannot close: still open on this till')} (${work.count})',
                  style: const TextStyle(fontWeight: FontWeight.bold, color: AppColors.error),
                ),
              ),
            ]),
            const SizedBox(height: 8),
            Text(
              tr(context,
                  '${work.count} unfinished item(s). Resolve each one before retrying.'),
              style: const TextStyle(fontSize: 12, color: AppColors.error),
            ),
            if (widget.onNavigateToFloor != null) ...[
              const SizedBox(height: 8),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: TextButton.icon(
                  key: const Key('go-to-floor'),
                  onPressed: widget.onNavigateToFloor,
                  icon: const Icon(Icons.table_restaurant),
                  label: Text(tr(context, 'Go to floor')),
                ),
              ),
            ],
          ]),
        ),
      );

  Widget _closingView() => Center(
        key: const Key('session-closing'),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const SizedBox(
            width: 48,
            height: 48,
            child: CircularProgressIndicator(strokeWidth: 3),
          ),
          const SizedBox(height: 20),
          Text(tr(context, 'Closing session'),
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Text(
            tr(context, 'Syncing sales to Odoo…'),
            style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
        ]),
      );

  Widget _doneView() {
    final closed = _closed;
    if (closed == null) return const SizedBox.shrink();
    final sum = widget.store.summary(closed, cashMethodIds: widget.cashMethodIds);
    final variance = sum.variance ?? 0;
    return ListView(
      key: const Key('session-done'),
      children: [
        Card(
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(color: Colors.green.shade600.withValues(alpha: 0.4)),
          ),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(children: [
                Icon(Icons.check_circle, color: Colors.green.shade700, size: 40),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(tr(context, 'Session closed'),
                      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                ),
              ]),
              if (_syncMessage != null) ...[
                const SizedBox(height: 12),
                Text(_syncMessage!,
                    key: const Key('close-sync-result-text'),
                    style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
              ],
              if (_odooOrderRef != null) ...[
                const SizedBox(height: 16),
                Container(
                  key: const Key('odoo-order-ref'),
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: Colors.green.shade50,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.green.shade400),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(tr(context, 'Odoo order'),
                          style: TextStyle(
                              fontSize: 12, color: Colors.green.shade800)),
                      const SizedBox(height: 4),
                      SelectableText(
                        _odooOrderRef!,
                        style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.bold,
                          color: Colors.green.shade900,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              const Divider(height: 28),
              Text(tr(context, 'Z report'),
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
              const SizedBox(height: 8),
              _row('${tr(context, 'Sales')} (${sum.salesCount})',
                  widget.formatAmount(sum.salesTotal),
                  bold: true),
              for (final t in sum.tenders)
                _row('  ${tr(context, t.label)}', widget.formatAmount(t.amount)),
              _row(tr(context, 'Cash sales'), widget.formatAmount(sum.cashSales)),
              _row(tr(context, 'Opening float'), widget.formatAmount(sum.openingFloat)),
              _row(tr(context, 'Cash in'), widget.formatAmount(sum.cashIn)),
              _row(tr(context, 'Cash out'), widget.formatAmount(sum.cashOut)),
              _row(tr(context, 'Expected in drawer'), widget.formatAmount(sum.expectedCash)),
              _row(tr(context, 'Counted'), widget.formatAmount(sum.countedCash ?? 0)),
              _row(
                tr(context, 'Variance'),
                widget.formatAmount(variance),
                bold: true,
                valueColor: variance.abs() < 0.01 ? Colors.green.shade700 : Colors.red,
              ),
            ]),
          ),
        ),
        const SizedBox(height: 16),
        Wrap(spacing: 8, runSpacing: 8, children: [
          if (widget.onPrintReport != null)
            OutlinedButton.icon(
              key: const Key('print-z'),
              icon: const Icon(Icons.print),
              label: Text(tr(context, 'Print')),
              onPressed: () =>
                  widget.onPrintReport!('Z Report', _rows(sum, withVariance: true)),
            ),
          FilledButton(
            key: const Key('session-done-ok'),
            onPressed: () => Navigator.of(context).maybePop(),
            child: Text(tr(context, 'Done')),
          ),
        ]),
      ],
    );
  }

  Future<void> _runCloseCeremony() async {
    // Before anything else, including the cash count: a tab still on a table
    // is a reason not to be closing at all, and finding that out after
    // counting the drawer wastes the count.
    if (!await _clearOpenWork()) return;
    if (!mounted) return;
    // Dishflow: consolidated close needs a session customer before the drawer
    // count starts — otherwise the night would book under Walk-in or split.
    if (!await _prepareCloseSync()) return;
    if (!mounted) return;
    final pending = widget.pendingSyncCount?.call() ?? 0;
    final counted = await _promptAmount(
        pending > 0
            ? tr(context, 'Close session & send to Odoo')
            : tr(context, 'Close session'),
        label: tr(context, 'Counted cash'));
    if (counted == null) return;
    if (!mounted) return;
    if (!await _drawerAddsUp(counted)) return;
    if (!mounted) return;
    final confirmed = await _confirmCloseShift(counted);
    if (confirmed != true || !mounted) return;
    // Authorise BEFORE the irreversible close, not after: a failed approval
    // must leave the shift open.
    if (widget.authorizeClose != null && !await widget.authorizeClose!()) return;
    if (!mounted) return;

    final closed = widget.store.closeShift(countedCash: counted);
    _handOverZ(closed);
    setState(() {
      _closed = closed;
      _shift = null;
      _phase = _Phase.closing;
      _syncMessage = null;
    });

    // Dishflow shows a progress state while the batch lands; same here.
    var message = tr(context, 'No orders to sync.');
    if (widget.onCloseSync != null) {
      message = await widget.onCloseSync!();
    }
    if (!mounted) return;
    setState(() {
      _syncMessage = message;
      _odooOrderRef = _parseOdooOrderRef(message);
      _phase = _Phase.done;
    });
  }

  /// Pulls "Odoo order: NAME" out of the sync result for the big label on done.
  static String? _parseOdooOrderRef(String message) {
    final match = RegExp(r'Odoo order:\s*(.+)$', multiLine: true).firstMatch(message);
    final ref = match?.group(1)?.trim();
    return (ref == null || ref.isEmpty) ? null : ref;
  }

  /// Dishflow session-close precondition: partner configured when sales will sync.
  Future<bool> _prepareCloseSync() async {
    final prepare = widget.onPrepareCloseSync;
    if (prepare == null) return true;
    final block = await prepare();
    if (block == null) return true;
    widget.onCloseBlocked?.call('shift.close.blocked.session_partner');
    if (!mounted) return false;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        key: const Key('session-partner-required'),
        title: Text(tr(ctx, 'Cannot close session')),
        content: Text(block),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(tr(ctx, 'OK')),
          ),
        ],
      ),
    );
    return false;
  }

  /// Hand the closed Z to whoever wants a copy of it (the mail queue).
  ///
  /// Wrapped, and never awaited. The shift is already closed by the time this
  /// runs, and nothing about sending a report anywhere may be able to throw in
  /// front of a cashier counting a drawer.
  void _handOverZ(Shift closed) {
    final onClosed = widget.onZClosed;
    if (onClosed == null) return;
    try {
      final sum = widget.store.summary(closed, cashMethodIds: widget.cashMethodIds);
      onClosed(closed, _rows(sum, withVariance: true));
    } catch (_) {
      // Deliberately swallowed: a cash-up does not fail because a report did.
    }
  }

  /// Whether the Z may go ahead over whatever is still open on the till.
  Future<bool> _clearOpenWork() async {
    final work = widget.openWork?.call();
    if (work == null || work.isEmpty) return true;
    widget.onCloseBlocked?.call('shift.close.blocked.open_work');
    await _showOpenWork(work);
    return false;
  }

  /// Everything still open, named, so the cashier knows exactly what to go and
  /// finish. Dishflow-style: sectioned list + optional jump back to the floor.
  Future<void> _showOpenWork(OpenWork work) => showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          key: const Key('open-work'),
          title: Text('${tr(ctx, 'Still open on this till')} (${work.count})'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (work.heldOrders.isNotEmpty) ...[
                  Text(tr(ctx, 'Parked tabs'),
                      style: const TextStyle(fontWeight: FontWeight.bold)),
                  ...work.heldOrders.map(Text.new),
                  const SizedBox(height: 8),
                ],
                if (work.timedLines.isNotEmpty) ...[
                  Text(tr(ctx, 'Courses waiting to fire'),
                      style: const TextStyle(fontWeight: FontWeight.bold)),
                  ...work.timedLines.map(Text.new),
                  const SizedBox(height: 8),
                ],
                Text(
                    tr(ctx,
                        'The shift cannot close until every one of these is settled or discarded.'),
                    style: const TextStyle(fontWeight: FontWeight.bold)),
              ],
            ),
          ),
          actions: [
            if (widget.onNavigateToFloor != null)
              TextButton(
                key: const Key('open-work-floor'),
                onPressed: () {
                  Navigator.pop(ctx);
                  widget.onNavigateToFloor!();
                },
                child: Text(tr(ctx, 'Go to floor')),
              ),
            FilledButton(
                key: const Key('open-work-back'),
                onPressed: () => Navigator.pop(ctx),
                child: Text(tr(ctx, 'Go back'))),
          ],
        ),
      );

  Future<bool> _drawerAddsUp(double counted) async {
    final s = _shift;
    if (s == null) return false;
    final sum = widget.store.summary(s, cashMethodIds: widget.cashMethodIds);
    final variance = counted - sum.expectedCash;
    // Half a cent of slack, so a tolerance of zero means "equal to the cent" rather
    // than "equal to the last binary digit of a double".
    if (variance.abs() <= widget.cashVarianceTolerance + 0.005) return true;
    widget.onCloseBlocked?.call('shift.close.blocked.cash_variance');
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        key: const Key('cash-variance-block'),
        title: Text(tr(ctx, 'The drawer does not add up')),
        content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('${tr(ctx, 'Expected in drawer')}: ${widget.formatAmount(sum.expectedCash)}'),
              Text('${tr(ctx, 'Counted')}: ${widget.formatAmount(counted)}'),
              Text('${tr(ctx, 'Variance')}: ${widget.formatAmount(variance)}',
                  style: const TextStyle(
                      fontWeight: FontWeight.bold, color: AppColors.error)),
              Text(
                  '${tr(ctx, 'Allowed difference')}: ${widget.formatAmount(widget.cashVarianceTolerance)}'),
              const SizedBox(height: 12),
              Text(
                  tr(ctx,
                      'Recount the drawer, or record the difference as a cash in or cash out, then close.'),
                  style: const TextStyle(fontWeight: FontWeight.bold)),
            ]),
        actions: [
          FilledButton(
              key: const Key('cash-variance-back'),
              onPressed: () => Navigator.pop(ctx),
              child: Text(tr(ctx, 'Go back'))),
        ],
      ),
    );
    return false;
  }

  Future<bool?> _confirmCloseShift(double counted) {
    final s = _shift;
    if (s == null) return Future.value(false);
    final sum = widget.store.summary(s, cashMethodIds: widget.cashMethodIds);
    final variance = counted - sum.expectedCash;
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr(ctx, 'Close the session?')),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${tr(ctx, 'Expected in drawer')}: ${widget.formatAmount(sum.expectedCash)}'),
          Text('${tr(ctx, 'Counted')}: ${widget.formatAmount(counted)}'),
          Text('${tr(ctx, 'Variance')}: ${widget.formatAmount(variance)}',
              style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: variance.abs() < 0.01 ? Colors.green.shade700 : Colors.red)),
          const SizedBox(height: 12),
          Text(
              tr(ctx, "This ends the shift and syncs the day's sales. It cannot be undone."),
              style: const TextStyle(fontWeight: FontWeight.bold)),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr(ctx, 'Cancel'))),
          FilledButton(
            key: const Key('confirm-close-shift'),
            style: FilledButton.styleFrom(backgroundColor: AppColors.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr(ctx, 'Close session')),
          ),
        ],
      ),
    );
  }

  List<(String, String)> _rows(ShiftSummary sum, {bool withVariance = false}) => [
        ('Sales (${sum.salesCount})', widget.formatAmount(sum.salesTotal)),
        for (final t in sum.tenders) ('  ${t.label}', widget.formatAmount(t.amount)),
        ('Cash sales', widget.formatAmount(sum.cashSales)),
        ('Opening float', widget.formatAmount(sum.openingFloat)),
        ('Cash in', widget.formatAmount(sum.cashIn)),
        ('Cash out', widget.formatAmount(sum.cashOut)),
        ('Expected in drawer', widget.formatAmount(sum.expectedCash)),
        if (withVariance) ('Counted', widget.formatAmount(sum.countedCash ?? 0)),
        if (withVariance) ('Variance', widget.formatAmount(sum.variance ?? 0)),
      ];

  Future<void> _printX() async {
    final s = _shift;
    if (s == null || widget.onPrintReport == null) return;
    final sum = widget.store.summary(s, cashMethodIds: widget.cashMethodIds);
    await widget.onPrintReport!('X Report', _rows(sum));
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(tr(context, 'X report sent to printer'))));
    }
  }

  List<(String, String)> _cashierRows(ShiftSummary sum) => [
        ('Sales (${sum.salesCount})', widget.formatAmount(sum.salesTotal)),
        for (final t in sum.tenders) ('  ${t.label}', widget.formatAmount(t.amount)),
        ('Cash sales', widget.formatAmount(sum.cashSales)),
      ];

  Future<void> _printCashierFlash() async {
    final s = _shift;
    if (s == null || widget.onPrintReport == null) return;
    final byCashier =
        widget.store.summaryByCashier(s, cashMethodIds: widget.cashMethodIds);
    if (byCashier.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(tr(context, 'No sales in this shift yet'))));
      return;
    }
    final who = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        key: const Key('cashier-flash-pick'),
        title: Text(tr(ctx, 'Cashier flash')),
        children: [
          for (final e in byCashier.entries)
            SimpleDialogOption(
              key: Key('flash-${e.key}'),
              onPressed: () => Navigator.pop(ctx, e.key),
              child: Text('${e.key}   ${widget.formatAmount(e.value.salesTotal)}'),
            ),
        ],
      ),
    );
    if (who == null || !mounted) return;
    await widget.onPrintReport!(
        'Cashier flash - $who', _cashierRows(byCashier[who]!));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(tr(context, 'Cashier flash sent to printer'))));
    }
  }
}
