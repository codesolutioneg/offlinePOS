import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/i18n/l10n.dart';
import 'site_api.dart';
import 'site_widgets.dart';
import 'voucher_download_stub.dart'
    if (dart.library.html) 'voucher_download_web.dart';
import 'voucher_summary.dart';

/// Voucher numbers and which branch used each one, on the same site as the
/// other reports. Only the owner reaches it.
class VouchersPage extends StatefulWidget {
  const VouchersPage({super.key, required this.api});

  final SiteApi api;

  @override
  State<VouchersPage> createState() => _VouchersPageState();
}

class _VouchersPageState extends State<VouchersPage> {
  SiteVouchers? _data;
  var _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final data = await widget.api.vouchers();
      if (mounted) setState(() => _data = data);
    } catch (e) {
      if (mounted) showSiteError(context, e);
    }
  }

  Future<void> _run(Future<void> Function() body) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await body();
      await _load();
    } catch (e) {
      if (mounted) showSiteError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _addDiscount() async {
    final made = await _askDiscount(context);
    if (made == null || !mounted) return;
    await _run(() => widget.api.addVoucherDiscount(made.name, made.percent));
  }

  Future<void> _removeDiscount(int index) async {
    if (!await confirm(
        context,
        tr(context,
            'Remove this discount type? Number ranges that used it go back to the default discount.'))) {
      return;
    }
    await _run(() => widget.api.removeVoucherDiscount(index));
  }

  Future<void> _addRange() async {
    final span = await _askRange(context, _data?.discounts ?? const []);
    if (span == null || !mounted) return;
    await _run(() => widget.api.addVoucherRange(span.from, span.to, discountId: span.discountId));
  }

  Future<void> _chooseRangeDiscount(int index) async {
    final data = _data;
    if (data == null) return;
    final id = await _askDiscountChoice(context, data);
    if (id == null || !mounted) return;
    await _run(() => widget.api.setVoucherRangeDiscount(index, id.isEmpty ? null : id));
  }

  Future<void> _removeRange(int index) async {
    if (!await confirm(
        context, tr(context, 'Remove these numbers? Codes already used stay in the report.'))) {
      return;
    }
    await _run(() => widget.api.removeVoucherRange(index));
  }

  Future<void> _addBranch() async {
    final name = await askText(context, tr(context, 'New voucher branch'), tr(context, 'Name'));
    if (name == null || name.isEmpty || !mounted) return;
    String? key;
    await _run(() async {
      key = await widget.api.addVoucherBranch(name);
    });
    if (key != null && mounted) {
      await showSecretDialog(
        context,
        tr(context, 'Branch voucher key'),
        tr(context, 'Paste this key once in Settings, Vouchers, on every till of this branch.'),
        key!,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final data = _data;
    return Scaffold(
      appBar: AppBar(title: Text(tr(context, 'Vouchers'))),
      body: data == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
              children: [
                Row(children: [
                  Expanded(
                    child: Text(tr(context, 'Discount types'),
                        style: Theme.of(context).textTheme.titleMedium),
                  ),
                  FilledButton.icon(
                    key: const Key('voucher-add-discount'),
                    onPressed: _busy ? null : _addDiscount,
                    icon: const Icon(Icons.percent),
                    label: Text(tr(context, 'Add a discount type')),
                  ),
                ]),
                const SizedBox(height: 8),
                if (data.discounts.isEmpty)
                  Card(
                    child: ListTile(
                      title: Text(tr(
                        context,
                        'No discount types yet. Numbers without a type use the default discount.',
                      )),
                      subtitle: Text(
                        '${tr(context, 'Default discount')} ${data.percent.toStringAsFixed(0)}%',
                      ),
                    ),
                  )
                else
                  for (var i = 0; i < data.discounts.length; i++)
                    Card(
                      child: ListTile(
                        leading: const Icon(Icons.percent),
                        title: Text(data.discounts[i].name),
                        subtitle: Text('${data.discounts[i].percent.toStringAsFixed(0)}%'),
                        trailing: IconButton(
                          key: Key('voucher-discount-delete-$i'),
                          tooltip: tr(context, 'Delete'),
                          onPressed: _busy ? null : () => _removeDiscount(i),
                          icon: Icon(Icons.delete_outline, color: Colors.red.shade700),
                        ),
                      ),
                    ),
                const SizedBox(height: 16),
                Row(children: [
                  Expanded(
                    child: Text(tr(context, 'Voucher numbers'),
                        style: Theme.of(context).textTheme.titleMedium),
                  ),
                  FilledButton.icon(
                    key: const Key('voucher-add-range'),
                    onPressed: _busy ? null : _addRange,
                    icon: const Icon(Icons.add),
                    label: Text(tr(context, 'Add numbers')),
                  ),
                ]),
                const SizedBox(height: 8),
                if (data.ranges.isEmpty)
                  Card(
                    child: ListTile(
                      title: Text(tr(context, 'No numbers yet')),
                    ),
                  )
                else
                  for (var i = 0; i < data.ranges.length; i++)
                    Card(
                      child: ListTile(
                        leading: const Icon(Icons.confirmation_number_outlined),
                        title: Text(
                          '${tr(context, 'From')} ${data.ranges[i].from}  ${tr(context, 'To')} ${data.ranges[i].to}',
                        ),
                        subtitle: Text(_rangeDiscountLabel(context, data, data.ranges[i])),
                        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                          IconButton(
                            key: Key('voucher-range-discount-$i'),
                            tooltip: tr(context, 'Discount type'),
                            onPressed: _busy ? null : () => _chooseRangeDiscount(i),
                            icon: const Icon(Icons.percent),
                          ),
                          IconButton(
                            key: Key('voucher-range-delete-$i'),
                            tooltip: tr(context, 'Delete'),
                            onPressed: _busy ? null : () => _removeRange(i),
                            icon: Icon(Icons.delete_outline, color: Colors.red.shade700),
                          ),
                        ]),
                      ),
                    ),
                const SizedBox(height: 24),
                Row(children: [
                  Expanded(
                    child: Text(tr(context, 'Branches'),
                        style: Theme.of(context).textTheme.titleMedium),
                  ),
                  FilledButton.icon(
                    key: const Key('voucher-add-branch'),
                    onPressed: _busy ? null : _addBranch,
                    icon: const Icon(Icons.add_business),
                    label: Text(tr(context, 'New branch')),
                  ),
                ]),
                const SizedBox(height: 8),
                for (final branch in data.branches)
                  Card(
                    child: ListTile(
                      leading: Icon(
                        Icons.storefront,
                        color: branch.connected ? Colors.green.shade700 : null,
                      ),
                      title: Text(branch.name),
                      subtitle: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            branch.key,
                            textDirection: TextDirection.ltr,
                            style: const TextStyle(fontFamily: 'monospace'),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            tr(
                              context,
                              branch.connected ? 'Linked to POS' : 'Not linked to POS',
                            ),
                            style: TextStyle(
                              color: branch.connected
                                  ? Colors.green.shade700
                                  : Colors.orange.shade800,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                      isThreeLine: true,
                      trailing: IconButton(
                        tooltip: tr(context, 'Copy'),
                        onPressed: () => Clipboard.setData(ClipboardData(text: branch.key)),
                        icon: const Icon(Icons.copy),
                      ),
                    ),
                  ),
                const SizedBox(height: 24),
                Row(children: [
                  Expanded(
                    child: Text(tr(context, 'Report'),
                        style: Theme.of(context).textTheme.titleMedium),
                  ),
                  FilledButton.icon(
                    key: const Key('voucher-download'),
                    onPressed: () => _downloadReport(context, data),
                    icon: const Icon(Icons.download),
                    label: Text(tr(context, 'Download report')),
                  ),
                ]),
                const SizedBox(height: 8),
                _totals(context, voucherTotals(data)),
                const SizedBox(height: 8),
                for (final count in voucherRangeCounts(data))
                  Card(
                    child: ListTile(
                      title: Text(
                        '${tr(context, 'From')} ${count.from}  ${tr(context, 'To')} ${count.to}',
                      ),
                      subtitle: Text(
                        '${tr(context, 'Used count')} ${count.used}'
                        '  ·  ${tr(context, 'Vouchers left')} ${count.remaining}'
                        '  ·  ${tr(context, 'Voucher value')} ${siteMoney(count.value)}',
                      ),
                    ),
                  ),
                const SizedBox(height: 8),
                if (data.rows.isEmpty)
                  Card(child: ListTile(title: Text(tr(context, 'No voucher has been used yet'))))
                else
                  for (final row in data.rows) _useCard(context, row),
              ],
            ),
    );
  }
}

Widget _totals(BuildContext context, VoucherTotals totals) {
  Widget tile(String label, String value) {
    return Expanded(
      child: Card(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 8),
          child: Column(children: [
            Text(
              value,
              textDirection: TextDirection.ltr,
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 4),
            Text(tr(context, label), textAlign: TextAlign.center),
          ]),
        ),
      ),
    );
  }

  return Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Row(children: [
        tile('Voucher value', siteMoney(totals.value)),
        tile('Used count', '${totals.used}'),
        tile('Vouchers left', '${totals.remaining}'),
      ]),
      if (totals.waiting > 0)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text('${tr(context, 'Waiting')}: ${totals.waiting}'),
        ),
    ],
  );
}

void _downloadReport(BuildContext context, SiteVouchers data) {
  final totals = voucherTotals(data);
  String cell(String value) {
    if (value.contains(',') || value.contains('"') || value.contains('\n')) {
      return '"${value.replaceAll('"', '""')}"';
    }
    return value;
  }

  final lines = <String>[
    '${tr(context, 'Voucher value')},${totals.value.toStringAsFixed(2)}',
    '${tr(context, 'Used count')},${totals.used}',
    '${tr(context, 'Waiting')},${totals.waiting}',
    '${tr(context, 'Vouchers left')},${totals.remaining}',
    '${tr(context, 'Total')},${totals.total}',
    '',
    [
      tr(context, 'Voucher number'),
      tr(context, 'Customer number'),
      tr(context, 'Branch'),
      tr(context, 'Order'),
      tr(context, 'Cashier'),
      tr(context, 'Status'),
      tr(context, 'Discount'),
      tr(context, 'Time'),
    ].join(','),
    for (final row in data.rows)
      [
        row.serial > 0 ? '${row.serial}' : row.code,
        cell(row.customerName),
        cell(row.branchName),
        cell(row.orderNo ?? ''),
        cell(row.cashier ?? ''),
        tr(context, row.status == 'used'
            ? 'Used'
            : row.status == 'issued'
                ? 'Claimed'
                : 'Waiting'),
        row.discountAmount?.toStringAsFixed(2) ?? '',
        siteWhen(context, row.usedAt ?? row.heldAt),
      ].join(','),
  ];
  downloadReport('vouchers.csv', lines.join('\n'));
}

Widget _useCard(BuildContext context, SiteVoucherUse row) {
  final number = row.serial > 0 ? '${row.serial}' : row.code;
  final when = siteWhen(context, row.usedAt ?? row.heldAt);
  final lines = <(String, String)>[
    ('Customer number', row.customerName),
    ('Branch', row.branchName),
    if ((row.orderNo ?? '').isNotEmpty) ('Order', row.orderNo!),
    if (row.cashier != null && row.cashier!.isNotEmpty) ('Cashier', row.cashier!),
    if (row.discountAmount != null) ('Discount', siteMoney(row.discountAmount!)),
    if (when.isNotEmpty) ('Time', when),
  ];
  return Card(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(children: [
            Icon(row.status == 'used'
                ? Icons.check_circle_outline
                : row.status == 'issued'
                    ? Icons.confirmation_number_outlined
                    : Icons.hourglass_empty),
            const SizedBox(width: 8),
            Text(
              tr(context, row.status == 'used'
                  ? 'Used'
                  : row.status == 'issued'
                      ? 'Claimed'
                      : 'Waiting'),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const Spacer(),
            Text(
              number,
              textDirection: TextDirection.ltr,
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ]),
          const SizedBox(height: 8),
          for (final line in lines)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(children: [
                Text(tr(context, line.$1), style: TextStyle(color: Colors.grey.shade700)),
                const Spacer(),
                Text(line.$2, textDirection: TextDirection.ltr),
              ]),
            ),
        ],
      ),
    ),
  );
}

String _rangeDiscountLabel(BuildContext context, SiteVouchers data, SiteVoucherRange range) {
  final id = range.discountId;
  if (id != null) {
    for (final discount in data.discounts) {
      if (discount.id == id) {
        return '${discount.name} ${discount.percent.toStringAsFixed(0)}%';
      }
    }
  }
  return '${tr(context, 'Default discount')} ${range.percent.toStringAsFixed(0)}%';
}

Future<({String name, double percent})?> _askDiscount(BuildContext context) {
  final name = TextEditingController();
  final percent = TextEditingController();
  return showDialog<({String name, double percent})>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(tr(ctx, 'Add a discount type')),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(
          key: const Key('voucher-discount-name'),
          controller: name,
          autofocus: true,
          decoration: InputDecoration(labelText: tr(ctx, 'Name')),
        ),
        const SizedBox(height: 8),
        TextField(
          key: const Key('voucher-discount-percent'),
          controller: percent,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(labelText: tr(ctx, 'Percent')),
        ),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr(ctx, 'Cancel'))),
        FilledButton(
          key: const Key('voucher-discount-save'),
          onPressed: () {
            final label = name.text.trim();
            final value = double.tryParse(percent.text.trim().replaceAll(',', '.'));
            if (label.isEmpty || value == null || value <= 0 || value > 100) return;
            Navigator.pop(ctx, (name: label, percent: value));
          },
          child: Text(tr(ctx, 'Add')),
        ),
      ],
    ),
  );
}

/// Empty string means the default percent. Null means the dialog was cancelled.
Future<String?> _askDiscountChoice(BuildContext context, SiteVouchers data) {
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(tr(ctx, 'Choose a discount type')),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            title: Text('${tr(ctx, 'Default discount')} ${data.percent.toStringAsFixed(0)}%'),
            onTap: () => Navigator.pop(ctx, ''),
          ),
          for (final discount in data.discounts)
            ListTile(
              title: Text('${discount.name} ${discount.percent.toStringAsFixed(0)}%'),
              onTap: () => Navigator.pop(ctx, discount.id),
            ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr(ctx, 'Cancel'))),
      ],
    ),
  );
}

Future<({int from, int to, String? discountId})?> _askRange(
  BuildContext context,
  List<SiteVoucherDiscount> discounts,
) {
  final from = TextEditingController();
  final to = TextEditingController();
  var discountId = discounts.isEmpty ? null : discounts.first.id;
  return showDialog<({int from, int to, String? discountId})>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setLocal) => AlertDialog(
        title: Text(tr(ctx, 'Add numbers')),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
            key: const Key('voucher-from'),
            controller: from,
            autofocus: true,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(labelText: tr(ctx, 'From')),
          ),
          const SizedBox(height: 8),
          TextField(
            key: const Key('voucher-to'),
            controller: to,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(labelText: tr(ctx, 'To')),
          ),
          if (discounts.isNotEmpty) ...[
            const SizedBox(height: 8),
            DropdownButtonFormField<String?>(
              key: const Key('voucher-range-type'),
              initialValue: discountId,
              decoration: InputDecoration(labelText: tr(ctx, 'Discount type')),
              items: [
                for (final discount in discounts)
                  DropdownMenuItem(
                    value: discount.id,
                    child: Text('${discount.name} ${discount.percent.toStringAsFixed(0)}%'),
                  ),
              ],
              onChanged: (value) => setLocal(() => discountId = value),
            ),
          ],
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr(ctx, 'Cancel'))),
          FilledButton(
            key: const Key('voucher-range-save'),
            onPressed: () {
              final a = int.tryParse(from.text.trim());
              final b = int.tryParse(to.text.trim());
              if (a == null || b == null) return;
              Navigator.pop(ctx, (from: a, to: b, discountId: discountId));
            },
            child: Text(tr(ctx, 'Add')),
          ),
        ],
      ),
    ),
  );
}
