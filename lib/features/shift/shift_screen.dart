import 'package:flutter/material.dart';

import '../../core/db/shift_store.dart';
import '../../domain/shift.dart';

/// Open a shift with a float, record cash in/out, and close with the X/Z count.
class ShiftScreen extends StatefulWidget {
  const ShiftScreen({
    super.key,
    required this.store,
    required this.cashierId,
    required this.formatAmount,
    this.cashMethodIds = const {},
  });

  final ShiftStore store;
  final String cashierId;
  final String Function(double) formatAmount;

  /// The payment methods that land in the drawer, so the X/Z drawer total counts
  /// cash and leaves card and other tenders out.
  final Set<int> cashMethodIds;

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
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, double.tryParse(c.text.trim())),
              child: const Text('OK')),
        ],
      ),
    );
  }

  /// An amount plus a short reason, so a paid-in/out is auditable rather than an
  /// unexplained swing in the drawer. Returns null if cancelled or the amount is
  /// not a number.
  Future<({double amount, String reason})?> _promptMovement(String title) {
    final amountC = TextEditingController();
    final reasonC = TextEditingController();
    return showDialog<({double amount, String reason})>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
            controller: amountC,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: 'Amount', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: reasonC,
            decoration: const InputDecoration(
                labelText: 'Reason (optional)', border: OutlineInputBorder()),
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              final a = double.tryParse(amountC.text.trim());
              if (a == null) {
                Navigator.pop(ctx);
                return;
              }
              Navigator.pop(ctx, (amount: a, reason: reasonC.text.trim()));
            },
            child: const Text('OK'),
          ),
        ],
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
      appBar: AppBar(title: const Text('Shift')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: s == null ? _closedView() : _openView(s),
      ),
    );
  }

  Widget _closedView() => Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('No shift is open', style: TextStyle(fontSize: 18)),
          const SizedBox(height: 12),
          FilledButton.icon(
            key: const Key('open-shift'),
            icon: const Icon(Icons.play_arrow),
            label: const Text('Open shift'),
            onPressed: () async {
              final f = await _promptAmount('Open shift', label: 'Opening float');
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
      Text('Open since ${s.openedAt.toLocal()}',
          style: const TextStyle(color: Colors.black54)),
      const Divider(),
      _row('Opening float', widget.formatAmount(sum.openingFloat)),
      _row('Sales (${sum.salesCount})', widget.formatAmount(sum.salesTotal)),
      _row('Cash sales', widget.formatAmount(sum.cashSales)),
      _row('Cash in', widget.formatAmount(sum.cashIn)),
      _row('Cash out', widget.formatAmount(sum.cashOut)),
      const Divider(),
      _row('Expected in drawer', widget.formatAmount(sum.expectedCash), bold: true),
      if (s.movements.isNotEmpty) ...[
        const Divider(),
        const Text('Cash movements', style: TextStyle(fontWeight: FontWeight.bold)),
        ...s.movements.map((m) => _row(
              '${m.type == 'in' ? 'In' : 'Out'}${m.reason.isEmpty ? '' : ' (${m.reason})'}',
              widget.formatAmount(m.amount),
            )),
      ],
      const SizedBox(height: 16),
      Wrap(spacing: 8, children: [
        OutlinedButton.icon(
          key: const Key('cash-in'),
          icon: const Icon(Icons.add),
          label: const Text('Cash in'),
          onPressed: () async {
            final m = await _promptMovement('Cash in');
            if (m != null) {
              widget.store.addMovement('in', m.amount, reason: m.reason);
              _refresh();
            }
          },
        ),
        OutlinedButton.icon(
          key: const Key('cash-out'),
          icon: const Icon(Icons.remove),
          label: const Text('Cash out'),
          onPressed: () async {
            final m = await _promptMovement('Cash out');
            if (m != null) {
              widget.store.addMovement('out', m.amount, reason: m.reason);
              _refresh();
            }
          },
        ),
      ]),
      const SizedBox(height: 16),
      FilledButton.icon(
        key: const Key('close-shift'),
        style: FilledButton.styleFrom(backgroundColor: Colors.red.shade700),
        icon: const Icon(Icons.stop),
        label: const Text('Close shift (Z)'),
        onPressed: () async {
          final counted = await _promptAmount('Close shift', label: 'Counted cash');
          if (counted != null) {
            final closed = widget.store.closeShift(countedCash: counted);
            if (mounted) _showZ(closed);
            _refresh();
          }
        },
      ),
    ]);
  }

  void _showZ(Shift closed) {
    final sum = widget.store.summary(closed, cashMethodIds: widget.cashMethodIds);
    final variance = sum.variance ?? 0;
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Z report'),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Sales: ${sum.salesCount}   ${widget.formatAmount(sum.salesTotal)}'),
          Text('Cash sales: ${widget.formatAmount(sum.cashSales)}'),
          Text('Opening float: ${widget.formatAmount(sum.openingFloat)}'),
          Text('Cash in: ${widget.formatAmount(sum.cashIn)}    Cash out: ${widget.formatAmount(sum.cashOut)}'),
          Text('Expected: ${widget.formatAmount(sum.expectedCash)}'),
          Text('Counted: ${widget.formatAmount(sum.countedCash ?? 0)}'),
          Text('Variance: ${widget.formatAmount(variance)}',
              style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: variance.abs() < 0.01 ? Colors.green.shade700 : Colors.red)),
        ]),
        actions: [FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('Done'))],
      ),
    );
  }
}
