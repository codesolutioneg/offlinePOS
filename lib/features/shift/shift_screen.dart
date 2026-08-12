import 'package:flutter/material.dart';

import '../../core/db/shift_store.dart';
import '../../core/i18n/l10n.dart';
import '../../domain/shift.dart';

/// Open a shift with a float, record cash in/out, and close with the X/Z count.
class ShiftScreen extends StatefulWidget {
  const ShiftScreen({
    super.key,
    required this.store,
    required this.cashierId,
    required this.formatAmount,
    this.cashMethodIds = const {},
    this.onCloseSync,
    this.onPrintReport,
    this.expenseCategories = const ['Transport', 'Food', 'Supplies', 'Maintenance', 'Other'],
  });

  final ShiftStore store;
  final String cashierId;
  final String Function(double) formatAmount;

  /// The payment methods that land in the drawer, so the X/Z drawer total counts
  /// cash and leaves card and other tenders out.
  final Set<int> cashMethodIds;

  /// Pushes the shift's orders to Odoo as one batch when the shift closes, and
  /// returns a message describing the outcome. Null on a build with no server.
  final Future<String> Function()? onCloseSync;

  /// Prints a shift report (X or Z) to the receipt printer. Null hides the print
  /// action. Rows are (label, value) pairs.
  final Future<void> Function(String title, List<(String, String)> rows)? onPrintReport;

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

  Future<double?> _promptAmount(String title, {String label = 'Amount'}) {
    final c = TextEditingController();
    return showDialog<double>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: c,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(labelText: label, border: const OutlineInputBorder()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr(ctx, 'Cancel'))),
          FilledButton(
              onPressed: () {
                // A float or count is never negative; a bad entry cancels rather
                // than poisoning the drawer maths.
                final v = double.tryParse(c.text.trim());
                Navigator.pop(ctx, (v != null && v >= 0) ? v : null);
              },
              child: Text(tr(ctx, 'OK'))),
        ],
      ),
    );
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
          FilledButton.icon(
            key: const Key('open-shift'),
            icon: const Icon(Icons.play_arrow),
            label: Text(tr(context, 'Open shift')),
            onPressed: () async {
              final f = await _promptAmount(tr(context, 'Open shift'), label: tr(context, 'Opening float'));
              if (!mounted) return;
              if (f != null) {
                widget.store.openShift(openingFloat: f, cashierId: widget.cashierId);
                _refresh();
              }
            },
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
        OutlinedButton.icon(
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
        OutlinedButton.icon(
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
      ]),
      const SizedBox(height: 16),
      if (widget.onPrintReport != null)
        OutlinedButton.icon(
          key: const Key('print-x'),
          icon: const Icon(Icons.print),
          label: Text(tr(context, 'Print X read')),
          onPressed: _printX,
        ),
      const SizedBox(height: 8),
      FilledButton.icon(
        key: const Key('close-shift'),
        style: FilledButton.styleFrom(backgroundColor: Colors.red.shade700),
        icon: const Icon(Icons.stop),
        label: Text(tr(context, 'Close shift (Z)')),
        onPressed: () async {
          final counted = await _promptAmount(tr(context, 'Close shift'), label: tr(context, 'Counted cash'));
          if (counted == null) return;
          final closed = widget.store.closeShift(countedCash: counted);
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
    ]);
  }

  /// The report rows for an X (interim) or Z (close) reading.
  List<(String, String)> _rows(dynamic sum, {bool withVariance = false}) => [
        ('Sales (${sum.salesCount})', widget.formatAmount(sum.salesTotal)),
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

  void _showZ(Shift closed) {
    final sum = widget.store.summary(closed, cashMethodIds: widget.cashMethodIds);
    final variance = sum.variance ?? 0;
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr(ctx, 'Z report')),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${tr(ctx, 'Sales')}: ${sum.salesCount}   ${widget.formatAmount(sum.salesTotal)}'),
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
