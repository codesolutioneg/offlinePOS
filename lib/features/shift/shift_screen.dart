import 'package:flutter/material.dart';

import '../../core/db/shift_store.dart';
import '../../core/i18n/l10n.dart';
import '../../core/theme/app_colors.dart';
import '../../core/widgets/numeric_keypad.dart';
import '../../domain/shift.dart';

/// Open a shift with a float, record cash in/out, and close with the X/Z count.
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
  });

  /// Called right after a shift is opened, so the host can ask who is working this
  /// session and clock them in. Null skips the prompt.
  final VoidCallback? onShiftOpened;

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

class _ShiftScreenState extends State<ShiftScreen> {
  Shift? _shift;

  @override
  void initState() {
    super.initState();
    _shift = widget.store.currentOpenShift();
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

  /// An amount plus a short reason, so a paid-in/out is auditable rather than an
  /// unexplained swing in the drawer. Returns null if cancelled or the amount is
  /// not a number.
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
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration:
                  InputDecoration(labelText: tr(ctx, 'Amount'), border: const OutlineInputBorder()),
            ),
            const SizedBox(height: 8),
            if (categories.isNotEmpty)
              DropdownButtonFormField<String>(
                key: const Key('expense-category'),
                initialValue: category,
                decoration: InputDecoration(
                    labelText: tr(ctx, 'Category'), border: const OutlineInputBorder()),
                items: [
                  for (final c in categories)
                    DropdownMenuItem(value: c, child: Text(tr(ctx, c))),
                ],
                onChanged: (v) => setLocal(() => category = v),
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

  Widget _row(String k, String v, {bool bold = false}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(children: [
          Text(k),
          const Spacer(),
          Text(v, style: TextStyle(fontWeight: bold ? FontWeight.bold : FontWeight.normal)),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    final s = _shift;
    return Scaffold(
      appBar: AppBar(title: Text(tr(context, 'Shift'))),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: s == null ? _closedView() : _openView(s),
      ),
    );
  }

  Widget _closedView() => Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(tr(context, 'No shift is open'), style: const TextStyle(fontSize: 18)),
          const SizedBox(height: 12),
          SizedBox(
            height: 52,
            child: FilledButton.icon(
              key: const Key('open-shift'),
              icon: const Icon(Icons.play_arrow),
              label: Text(tr(context, 'Open shift')),
              onPressed: () async {
                final f = await _promptAmount(tr(context, 'Open shift'), label: tr(context, 'Opening float'));
                if (!mounted) return;
                if (f != null) {
                  widget.store.openShift(openingFloat: f, cashierId: widget.cashierId);
                  _refresh();
                  widget.onShiftOpened?.call();
                }
              },
            ),
          ),
        ]),
      );

  Widget _openView(Shift s) {
    final sum = widget.store.summary(s, cashMethodIds: widget.cashMethodIds);
    return ListView(children: [
      Text('${tr(context, 'Open since')} ${_stamp(s.openedAt)}',
          style: const TextStyle(color: Colors.black54)),
      const Divider(),
      _row(tr(context, 'Opening float'), widget.formatAmount(sum.openingFloat)),
      _row('${tr(context, 'Sales')} (${sum.salesCount})', widget.formatAmount(sum.salesTotal)),
      _row(tr(context, 'Cash sales'), widget.formatAmount(sum.cashSales)),
      _row(tr(context, 'Cash in'), widget.formatAmount(sum.cashIn)),
      _row(tr(context, 'Cash out'), widget.formatAmount(sum.cashOut)),
      const Divider(),
      _row(tr(context, 'Expected in drawer'), widget.formatAmount(sum.expectedCash), bold: true),
      if (sum.tenders.isNotEmpty) ...[
        const Divider(),
        Text(tr(context, 'Payment mix'), style: const TextStyle(fontWeight: FontWeight.bold)),
        // Tender names come from the catalogue, so only the untendered cash row has
        // a translation to find.
        ...sum.tenders.map((t) => _row(tr(context, t.label), widget.formatAmount(t.amount))),
      ],
      if (s.movements.isNotEmpty) ...[
        const Divider(),
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
      const SizedBox(height: 8),
      _whyBlocked(),
      SizedBox(
        height: 60,
        child: FilledButton.icon(
          key: const Key('close-shift'),
          style: FilledButton.styleFrom(backgroundColor: AppColors.error),
          icon: const Icon(Icons.stop),
          label: Text(tr(context, 'Close shift (Z)')),
          onPressed: () async {
            // Before anything else, including the cash count: a tab still on a table
            // is a reason not to be closing at all, and finding that out after
            // counting the drawer wastes the count.
            if (!await _clearOpenWork()) return;
            if (!mounted) return;
            final counted = await _promptAmount(tr(context, 'Close shift'), label: tr(context, 'Counted cash'));
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
            if (mounted) _showZ(closed);
            _refresh();
            // Push the day's orders to Odoo now, as one batch. The message tells the
            // cashier whether it landed or is safely held for later.
            if (widget.onCloseSync != null) {
              final message = await widget.onCloseSync!();
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                  key: const Key('close-sync-result'),
                  content: Text(message),
                  duration: const Duration(seconds: 5),
                ));
              }
            }
          },
        ),
      ),
    ]);
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
  ///
  /// Nothing open, or nothing being checked, and this is a no-op. Otherwise the list
  /// is shown in full and the close does not happen. There is no override: a parked
  /// tab is a bill nobody has taken money for, so closing the day over it produces a
  /// Z that is wrong on the paper and wrong in Odoo, and no approval fixes that.
  /// Settling or discarding the tab is the only way past.
  Future<bool> _clearOpenWork() async {
    final work = widget.openWork?.call();
    if (work == null || work.isEmpty) return true;
    widget.onCloseBlocked?.call('shift.close.blocked.open_work');
    await _showOpenWork(work);
    return false;
  }

  /// Everything still open, named, so the cashier knows exactly what to go and
  /// finish. Informational: the only way out of it is back to the floor.
  Future<void> _showOpenWork(OpenWork work) => showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          key: const Key('open-work'),
          // The count leads the title: whatever else is skimmed, how many things
          // are in the way is the number that matters.
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
            FilledButton(
                key: const Key('open-work-back'),
                onPressed: () => Navigator.pop(ctx),
                child: Text(tr(ctx, 'Go back'))),
          ],
        ),
      );

  /// Whether the counted drawer is close enough to the expected drawer to close on.
  ///
  /// "Close enough" is an exact match to the cent unless the shop has set an
  /// allowance. Over it, the Z does not happen: the numbers are shown side by side
  /// so the cashier can recount, or book the difference as a cash in / cash out and
  /// have the drawer add up honestly.
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

  /// The reason the close button is going to refuse, on the screen beside it rather
  /// than only in the dialog it opens. A cash variance is not knowable until the
  /// drawer has been counted, so this names the work still open and the allowance
  /// the count will be held to.
  Widget _whyBlocked() {
    final work = widget.openWork?.call();
    if (work == null || work.isEmpty) return const SizedBox.shrink();
    return Card(
      key: const Key('close-blocked-why'),
      color: AppColors.error.withValues(alpha: 0.08),
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(children: [
          Icon(Icons.block, color: AppColors.error),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              '${tr(context, 'Cannot close: still open on this till')} (${work.count})',
              style: TextStyle(fontWeight: FontWeight.bold, color: AppColors.error),
            ),
          ),
        ]),
      ),
    );
  }

  /// A last check before a Z closes the shift and pushes the day's sales: it shows
  /// the drawer numbers that are about to be locked in, so a mistap is caught
  /// before the shift (and the day's till) is gone for good.
  Future<bool?> _confirmCloseShift(double counted) {
    final s = _shift;
    if (s == null) return Future.value(false);
    final sum = widget.store.summary(s, cashMethodIds: widget.cashMethodIds);
    final variance = counted - sum.expectedCash;
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr(ctx, 'Close the shift?')),
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
            child: Text(tr(ctx, 'Close shift')),
          ),
        ],
      ),
    );
  }

  /// The report rows for an X (interim) or Z (close) reading. The tender rows sit
  /// indented under the sales figure they break down, because a receipt is too
  /// narrow for a headed section of its own.
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

  /// Print an interim X reading without closing the shift.
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

  /// One cashier's takings inside the shift. The drawer lines are left off on
  /// purpose: the float and the paid-ins belong to the shift, not to a person, and
  /// printing them against a name would invite a count nobody can reconcile.
  List<(String, String)> _cashierRows(ShiftSummary sum) => [
        ('Sales (${sum.salesCount})', widget.formatAmount(sum.salesTotal)),
        for (final t in sum.tenders) ('  ${t.label}', widget.formatAmount(t.amount)),
        ('Cash sales', widget.formatAmount(sum.cashSales)),
      ];

  /// Print what one cashier took during this shift, so a till shared by two people
  /// over a service can be settled per person without closing it twice.
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

  void _showZ(Shift closed) {
    final sum = widget.store.summary(closed, cashMethodIds: widget.cashMethodIds);
    final variance = sum.variance ?? 0;
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr(ctx, 'Z report')),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${tr(ctx, 'Sales')}: ${sum.salesCount}   ${widget.formatAmount(sum.salesTotal)}'),
          // Indented under the sales total they break down, in the same order as the
          // printed ticket, so the paper and the screen read the same.
          for (final t in sum.tenders)
            Text('  ${tr(ctx, t.label)}: ${widget.formatAmount(t.amount)}'),
          Text('${tr(ctx, 'Cash sales')}: ${widget.formatAmount(sum.cashSales)}'),
          Text('${tr(ctx, 'Opening float')}: ${widget.formatAmount(sum.openingFloat)}'),
          Text('${tr(ctx, 'Cash in')}: ${widget.formatAmount(sum.cashIn)}    ${tr(ctx, 'Cash out')}: ${widget.formatAmount(sum.cashOut)}'),
          Text('${tr(ctx, 'Expected')}: ${widget.formatAmount(sum.expectedCash)}'),
          Text('${tr(ctx, 'Counted')}: ${widget.formatAmount(sum.countedCash ?? 0)}'),
          Text('${tr(ctx, 'Variance')}: ${widget.formatAmount(variance)}',
              style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: variance.abs() < 0.01 ? Colors.green.shade700 : Colors.red)),
        ]),
        actions: [
          if (widget.onPrintReport != null)
            TextButton.icon(
              key: const Key('print-z'),
              icon: const Icon(Icons.print),
              label: Text(tr(ctx, 'Print')),
              onPressed: () => widget.onPrintReport!('Z Report', _rows(sum, withVariance: true)),
            ),
          FilledButton(onPressed: () => Navigator.pop(ctx), child: Text(tr(ctx, 'Done'))),
        ],
      ),
    );
  }
}
