import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/i18n/l10n.dart';
import '../core/theme/app_colors.dart';
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
          'Remove this discount type? Number ranges that used it go back to the default discount.'),
    )) {
      return;
    }
    await _run(() => widget.api.removeVoucherDiscount(index));
  }

  Future<void> _addRange() async {
    final span = await _askRange(context, _data?.discounts ?? const []);
    if (span == null || !mounted) return;
    await _run(() =>
        widget.api.addVoucherRange(span.from, span.to, discountId: span.discountId));
  }

  Future<void> _chooseRangeDiscount(int index) async {
    final data = _data;
    if (data == null) return;
    final id = await _askDiscountChoice(context, data);
    if (id == null || !mounted) return;
    await _run(
        () => widget.api.setVoucherRangeDiscount(index, id.isEmpty ? null : id));
  }

  Future<void> _removeRange(int index) async {
    if (!await confirm(context,
        tr(context, 'Remove these numbers? Codes already used stay in the report.'))) {
      return;
    }
    await _run(() => widget.api.removeVoucherRange(index));
  }

  Future<void> _addBranch() async {
    final name =
        await askText(context, tr(context, 'New voucher branch'), tr(context, 'Name'));
    if (name == null || name.isEmpty || !mounted) return;
    String? key;
    await _run(() async {
      key = await widget.api.addVoucherBranch(name);
    });
    if (key != null && mounted) {
      await showSecretDialog(
        context,
        tr(context, 'Branch voucher key'),
        tr(context,
            'Paste this key once in Settings, Vouchers, on every till of this branch.'),
        key!,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final data = _data;
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
          tr(context, 'Vouchers'),
          style: const TextStyle(fontWeight: FontWeight.w800, letterSpacing: -0.2),
        ),
        actions: [
          IconButton(
            tooltip: tr(context, 'Refresh'),
            onPressed: _busy ? null : _load,
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
        child: data == null
            ? const Center(child: CircularProgressIndicator())
            : Align(
                alignment: Alignment.topCenter,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 920),
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(20, 20, 20, 40),
                    children: [
                      _section(
                        title: tr(context, 'Discount types'),
                        actionKey: const Key('voucher-add-discount'),
                        actionLabel: tr(context, 'Add a discount type'),
                        actionIcon: Icons.percent_rounded,
                        onAction: _busy ? null : _addDiscount,
                        child: data.discounts.isEmpty
                            ? _hintCard(
                                tr(context,
                                    'No discount types yet. Numbers without a type use the default discount.'),
                                '${tr(context, 'Default discount')} ${data.percent.toStringAsFixed(0)}%',
                              )
                            : Column(
                                children: [
                                  for (var i = 0; i < data.discounts.length; i++)
                                    _listTile(
                                      icon: Icons.percent_rounded,
                                      title: data.discounts[i].name,
                                      subtitle:
                                          '${data.discounts[i].percent.toStringAsFixed(0)}%',
                                      trailing: IconButton(
                                        key: Key('voucher-discount-delete-$i'),
                                        tooltip: tr(context, 'Delete'),
                                        onPressed:
                                            _busy ? null : () => _removeDiscount(i),
                                        icon: const Icon(
                                          Icons.delete_outline_rounded,
                                          color: AppColors.error,
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                      ),
                      _section(
                        title: tr(context, 'Voucher numbers'),
                        actionKey: const Key('voucher-add-range'),
                        actionLabel: tr(context, 'Add numbers'),
                        actionIcon: Icons.add_rounded,
                        onAction: _busy ? null : _addRange,
                        child: data.ranges.isEmpty
                            ? _hintCard(tr(context, 'No numbers yet'), null)
                            : Column(
                                children: [
                                  for (var i = 0; i < data.ranges.length; i++)
                                    _listTile(
                                      icon: Icons.confirmation_number_outlined,
                                      title:
                                          '${tr(context, 'From')} ${data.ranges[i].from}  ${tr(context, 'To')} ${data.ranges[i].to}',
                                      subtitle: _rangeDiscountLabel(
                                          context, data, data.ranges[i]),
                                      trailing: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          IconButton(
                                            key: Key('voucher-range-discount-$i'),
                                            tooltip: tr(context, 'Discount type'),
                                            onPressed: _busy
                                                ? null
                                                : () => _chooseRangeDiscount(i),
                                            icon: const Icon(Icons.percent_rounded),
                                          ),
                                          IconButton(
                                            key: Key('voucher-range-delete-$i'),
                                            tooltip: tr(context, 'Delete'),
                                            onPressed: _busy
                                                ? null
                                                : () => _removeRange(i),
                                            icon: const Icon(
                                              Icons.delete_outline_rounded,
                                              color: AppColors.error,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                ],
                              ),
                      ),
                      _section(
                        title: tr(context, 'Branches'),
                        actionKey: const Key('voucher-add-branch'),
                        actionLabel: tr(context, 'New branch'),
                        actionIcon: Icons.add_business_rounded,
                        onAction: _busy ? null : _addBranch,
                        child: Column(
                          children: [
                            for (final branch in data.branches)
                              _listTile(
                                icon: Icons.storefront_rounded,
                                iconColor: branch.connected
                                    ? AppColors.success
                                    : AppColors.textMutedLight,
                                title: branch.name,
                                subtitleWidget: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      branch.key,
                                      textDirection: TextDirection.ltr,
                                      style: const TextStyle(
                                        fontFamily: 'monospace',
                                        fontSize: 12,
                                        color: AppColors.textSecondaryLight,
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      tr(
                                        context,
                                        branch.connected
                                            ? 'Linked to POS'
                                            : 'Not linked to POS',
                                      ),
                                      style: TextStyle(
                                        color: branch.connected
                                            ? AppColors.success
                                            : AppColors.warning,
                                        fontWeight: FontWeight.w700,
                                        fontSize: 12,
                                      ),
                                    ),
                                  ],
                                ),
                                trailing: IconButton(
                                  tooltip: tr(context, 'Copy'),
                                  onPressed: () => Clipboard.setData(
                                      ClipboardData(text: branch.key)),
                                  icon: const Icon(Icons.copy_rounded),
                                ),
                              ),
                          ],
                        ),
                      ),
                      _section(
                        title: tr(context, 'Report'),
                        actionKey: const Key('voucher-download'),
                        actionLabel: tr(context, 'Download report'),
                        actionIcon: Icons.download_rounded,
                        onAction: () => _downloadReport(context, data),
                        child: Column(
                          children: [
                            _totals(context, voucherTotals(data)),
                            const SizedBox(height: 10),
                            for (final count in voucherRangeCounts(data))
                              _listTile(
                                icon: Icons.analytics_outlined,
                                title:
                                    '${tr(context, 'From')} ${count.from}  ${tr(context, 'To')} ${count.to}',
                                subtitle:
                                    '${tr(context, 'Used count')} ${count.used}'
                                    '  ·  ${tr(context, 'Vouchers left')} ${count.remaining}'
                                    '  ·  ${tr(context, 'Voucher value')} ${siteMoney(count.value)}',
                              ),
                            if (data.rows.isEmpty)
                              _hintCard(
                                  tr(context, 'No voucher has been used yet'), null)
                            else
                              for (final row in data.rows) _useCard(context, row),
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

  Widget _section({
    required String title,
    required Key actionKey,
    required String actionLabel,
    required IconData actionIcon,
    required VoidCallback? onAction,
    required Widget child,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFE2E8F0)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x0A0F172A),
            blurRadius: 18,
            offset: Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 16,
                    color: AppColors.brandNavy,
                  ),
                ),
              ),
              FilledButton.icon(
                key: actionKey,
                onPressed: onAction,
                icon: Icon(actionIcon, size: 16),
                label: Text(actionLabel),
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.brandNavy,
                  foregroundColor: Colors.white,
                  elevation: 0,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }

  Widget _hintCard(String title, String? subtitle) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontWeight: FontWeight.w600,
              color: AppColors.textSecondaryLight,
            ),
          ),
          if (subtitle != null) ...[
            const SizedBox(height: 4),
            Text(
              subtitle,
              style: const TextStyle(
                fontWeight: FontWeight.w700,
                color: AppColors.brandNavy,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _listTile({
    required IconData icon,
    required String title,
    String? subtitle,
    Widget? subtitleWidget,
    Widget? trailing,
    Color? iconColor,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: (iconColor ?? AppColors.primary).withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, size: 18, color: iconColor ?? AppColors.primary),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    color: AppColors.brandNavy,
                  ),
                ),
                if (subtitleWidget != null) ...[
                  const SizedBox(height: 2),
                  subtitleWidget,
                ] else if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: const TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textSecondaryLight,
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (trailing != null) trailing,
        ],
      ),
    );
  }
}

Widget _totals(BuildContext context, VoucherTotals totals) {
  Widget tile(String label, String value, Color color) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 10),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withValues(alpha: 0.2)),
        ),
        child: Column(
          children: [
            Text(
              value,
              textDirection: TextDirection.ltr,
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w800,
                color: color,
                letterSpacing: -0.4,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              tr(context, label),
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
  }

  return Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Row(
        children: [
          tile('Voucher value', siteMoney(totals.value), AppColors.brandNavy),
          const SizedBox(width: 8),
          tile('Used count', '${totals.used}', AppColors.primary),
          const SizedBox(width: 8),
          tile('Vouchers left', '${totals.remaining}', AppColors.success),
        ],
      ),
      if (totals.waiting > 0)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            '${tr(context, 'Waiting')}: ${totals.waiting}',
            style: const TextStyle(
              fontWeight: FontWeight.w700,
              color: AppColors.warning,
            ),
          ),
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
        tr(
          context,
          row.status == 'used'
              ? 'Used'
              : row.status == 'issued'
                  ? 'Claimed'
                  : 'Waiting',
        ),
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
  final statusColor = row.status == 'used'
      ? AppColors.success
      : row.status == 'issued'
          ? AppColors.primary
          : AppColors.warning;
  return Container(
    margin: const EdgeInsets.only(bottom: 8),
    padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
    decoration: BoxDecoration(
      color: const Color(0xFFF8FAFC),
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: const Color(0xFFE2E8F0)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Icon(
              row.status == 'used'
                  ? Icons.check_circle_outline
                  : row.status == 'issued'
                      ? Icons.confirmation_number_outlined
                      : Icons.hourglass_empty,
              color: statusColor,
            ),
            const SizedBox(width: 8),
            Text(
              tr(
                context,
                row.status == 'used'
                    ? 'Used'
                    : row.status == 'issued'
                        ? 'Claimed'
                        : 'Waiting',
              ),
              style: TextStyle(
                fontWeight: FontWeight.w800,
                color: statusColor,
              ),
            ),
            const Spacer(),
            Text(
              number,
              textDirection: TextDirection.ltr,
              style: const TextStyle(
                fontWeight: FontWeight.w800,
                color: AppColors.brandNavy,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        for (final line in lines)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(
              children: [
                Text(
                  tr(context, line.$1),
                  style: const TextStyle(
                    color: AppColors.textSecondaryLight,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                Text(line.$2, textDirection: TextDirection.ltr),
              ],
            ),
          ),
      ],
    ),
  );
}

String _rangeDiscountLabel(
    BuildContext context, SiteVouchers data, SiteVoucherRange range) {
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
        TextButton(
            onPressed: () => Navigator.pop(ctx), child: Text(tr(ctx, 'Cancel'))),
        FilledButton(
          key: const Key('voucher-discount-save'),
          style: FilledButton.styleFrom(backgroundColor: AppColors.brandNavy),
          onPressed: () {
            final label = name.text.trim();
            final value =
                double.tryParse(percent.text.trim().replaceAll(',', '.'));
            if (label.isEmpty || value == null || value <= 0 || value > 100) {
              return;
            }
            Navigator.pop(ctx, (name: label, percent: value));
          },
          child: Text(tr(ctx, 'Add')),
        ),
      ],
    ),
  );
}

Future<String?> _askDiscountChoice(BuildContext context, SiteVouchers data) {
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(tr(ctx, 'Choose a discount type')),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            title: Text(
                '${tr(ctx, 'Default discount')} ${data.percent.toStringAsFixed(0)}%'),
            onTap: () => Navigator.pop(ctx, ''),
          ),
          for (final discount in data.discounts)
            ListTile(
              title:
                  Text('${discount.name} ${discount.percent.toStringAsFixed(0)}%'),
              onTap: () => Navigator.pop(ctx, discount.id),
            ),
        ],
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx), child: Text(tr(ctx, 'Cancel'))),
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
              decoration:
                  InputDecoration(labelText: tr(ctx, 'Discount type')),
              items: [
                for (final discount in discounts)
                  DropdownMenuItem(
                    value: discount.id,
                    child: Text(
                        '${discount.name} ${discount.percent.toStringAsFixed(0)}%'),
                  ),
              ],
              onChanged: (value) => setLocal(() => discountId = value),
            ),
          ],
        ]),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(tr(ctx, 'Cancel'))),
          FilledButton(
            key: const Key('voucher-range-save'),
            style:
                FilledButton.styleFrom(backgroundColor: AppColors.brandNavy),
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
