import 'package:flutter/material.dart';

import '../../core/db/settings_store.dart';
import '../../core/i18n/l10n.dart';

/// Lets a manager pick what shows up on the printed customer receipt: a
/// header line above the shop name, the existing footer, and toggles for the
/// tax id, cashier name, and order type/table.
///
/// This is layout choice, not shop identity ([ShopSettingsScreen] already owns
/// name/tax id text), so it lives as its own screen the receipt builder reads
/// back from at print time via the same [SettingsStore] keys.
class ReceiptDesignerScreen extends StatefulWidget {
  const ReceiptDesignerScreen({super.key, required this.settings, required this.onChanged, this.onTestPrint});

  final SettingsStore settings;

  /// Called after Save so anything caching the receipt layout reloads.
  final VoidCallback onChanged;

  /// Prints a sample receipt with the current settings, so a manager can see the
  /// layout on paper. Null hides the test-print button.
  final Future<void> Function()? onTestPrint;

  @override
  State<ReceiptDesignerScreen> createState() => _ReceiptDesignerScreenState();
}

/// Raw setting keys, kept local to this screen since [SettingsStore] only
/// exposes typed accessors for the shop-identity fields it already owned.
const _headerKey = 'receipt_header';
const _showCashierKey = 'receipt_show_cashier';
const _showOrderTypeKey = 'receipt_show_ordertype';

/// The separator characters the receipt builder knows how to draw.
const _dividerStyles = ['line', 'equals', 'dots', 'stars'];

class _ReceiptDesignerScreenState extends State<ReceiptDesignerScreen> {
  late final TextEditingController _header;
  late final TextEditingController _footer;
  late bool _showTax;
  late bool _showCashier;
  late bool _showOrderType;
  late bool _showDateTime;
  late bool _showNumber;
  late bool _showTable;
  late bool _showPayment;
  late bool _showItemPrice;
  late String _dividerStyle;
  late int _columns;

  @override
  void initState() {
    super.initState();
    _header = TextEditingController(text: widget.settings.getString(_headerKey) ?? '');
    _footer = TextEditingController(text: widget.settings.receiptFooter ?? '');
    _showTax = widget.settings.receiptShowTax;
    _showCashier = widget.settings.getBool(_showCashierKey, fallback: true);
    _showOrderType = widget.settings.getBool(_showOrderTypeKey, fallback: true);
    _showDateTime = widget.settings.receiptShowDateTime;
    _showNumber = widget.settings.receiptShowNumber;
    _showTable = widget.settings.receiptShowTable;
    _showPayment = widget.settings.receiptShowPayment;
    _showItemPrice = widget.settings.receiptShowItemPrice;
    // Clamped to the offered choices: the segmented control below asserts on a
    // selection it has no segment for.
    final style = widget.settings.receiptDividerStyle;
    _dividerStyle = _dividerStyles.contains(style) ? style : 'line';
    // The same paper width the printers screen sets, so the two never disagree.
    _columns = widget.settings.receiptColumns == 32 ? 32 : 42;
  }

  @override
  void dispose() {
    _header.dispose();
    _footer.dispose();
    super.dispose();
  }

  void _save() {
    widget.settings.setString(_headerKey, _header.text.trim());
    widget.settings.receiptFooter = _footer.text.trim();
    widget.settings.receiptShowTax = _showTax;
    widget.settings.setBool(_showCashierKey, _showCashier);
    widget.settings.setBool(_showOrderTypeKey, _showOrderType);
    widget.settings.receiptShowDateTime = _showDateTime;
    widget.settings.receiptShowNumber = _showNumber;
    widget.settings.receiptShowTable = _showTable;
    widget.settings.receiptShowPayment = _showPayment;
    widget.settings.receiptShowItemPrice = _showItemPrice;
    widget.settings.receiptDividerStyle = _dividerStyle;
    widget.settings.receiptColumns = _columns;
    widget.onChanged();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr(context, 'Saved'))));
  }

  Widget _sectionHeader(String title) => Padding(
        padding: const EdgeInsets.only(top: 4, bottom: 4),
        child: Text(title,
            style: Theme.of(context)
                .textTheme
                .titleMedium
                ?.copyWith(fontWeight: FontWeight.bold)),
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(tr(context, 'Receipt designer'))),
      body: Column(children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              TextField(
                key: const Key('receipt-header'),
                controller: _header,
                decoration: InputDecoration(
                  labelText: tr(context, 'Header line'),
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                key: const Key('receipt-footer'),
                controller: _footer,
                minLines: 2,
                maxLines: 5,
                decoration: InputDecoration(
                  labelText: tr(context, 'Footer'),
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              _sectionHeader(tr(context, 'What prints')),
              SwitchListTile(
                key: const Key('t-tax'),
                title: Text(tr(context, 'Show tax id')),
                value: _showTax,
                onChanged: (v) => setState(() => _showTax = v),
              ),
              SwitchListTile(
                key: const Key('t-cashier'),
                title: Text(tr(context, 'Show cashier')),
                value: _showCashier,
                onChanged: (v) => setState(() => _showCashier = v),
              ),
              SwitchListTile(
                key: const Key('t-ordertype'),
                title: Text(tr(context, 'Show order type & table')),
                value: _showOrderType,
                onChanged: (v) => setState(() => _showOrderType = v),
              ),
              SwitchListTile(
                key: const Key('t-datetime'),
                title: Text(tr(context, 'Show date & time')),
                subtitle: Text(tr(context, 'Time of sale, near the top')),
                value: _showDateTime,
                onChanged: (v) => setState(() => _showDateTime = v),
              ),
              SwitchListTile(
                key: const Key('t-number'),
                title: Text(tr(context, 'Show order number')),
                subtitle: Text(tr(context, 'The order reference, e.g. #A1B2C3')),
                value: _showNumber,
                onChanged: (v) => setState(() => _showNumber = v),
              ),
              SwitchListTile(
                key: const Key('t-table'),
                title: Text(tr(context, 'Show table & guests')),
                subtitle: Text(tr(context, 'Dine-in orders only')),
                value: _showTable,
                onChanged: (v) => setState(() => _showTable = v),
              ),
              SwitchListTile(
                key: const Key('t-payment'),
                title: Text(tr(context, 'Show payment method')),
                subtitle: Text(tr(context, 'One line per tender')),
                value: _showPayment,
                onChanged: (v) => setState(() => _showPayment = v),
              ),
              SwitchListTile(
                key: const Key('t-itemprice'),
                title: Text(tr(context, 'Show item price')),
                subtitle: Text(tr(context, 'Off leaves names and quantities only')),
                value: _showItemPrice,
                onChanged: (v) => setState(() => _showItemPrice = v),
              ),
              const SizedBox(height: 12),
              _sectionHeader(tr(context, 'Paper & dividers')),
              Row(children: [
                Text(tr(context, 'Paper width'), style: const TextStyle(fontWeight: FontWeight.w600)),
                const Spacer(),
                SegmentedButton<int>(
                  segments: [
                    ButtonSegment(value: 42, label: Text('80 mm', key: const Key('t-papersize-80'))),
                    ButtonSegment(value: 32, label: Text('58 mm', key: const Key('t-papersize-58'))),
                  ],
                  selected: {_columns},
                  onSelectionChanged: (s) => setState(() => _columns = s.first),
                ),
              ]),
              const SizedBox(height: 12),
              Row(children: [
                Text(tr(context, 'Divider style'), style: const TextStyle(fontWeight: FontWeight.w600)),
                const Spacer(),
                SegmentedButton<String>(
                  segments: [
                    ButtonSegment(value: 'line', label: Text('-----', key: const Key('t-divider-line'))),
                    ButtonSegment(value: 'equals', label: Text('=====', key: const Key('t-divider-equals'))),
                    ButtonSegment(value: 'dots', label: Text('.....', key: const Key('t-divider-dots'))),
                    ButtonSegment(value: 'stars', label: Text('*****', key: const Key('t-divider-stars'))),
                  ],
                  selected: {_dividerStyle},
                  onSelectionChanged: (s) => setState(() => _dividerStyle = s.first),
                ),
              ]),
              const SizedBox(height: 8),
              // No print preview here: rendering a live receipt needs the printer
              // pipeline this screen intentionally stays decoupled from.
              Text(
                tr(context, 'A live print preview is not shown here. Changes apply to the next printed receipt.'),
                style: const TextStyle(color: Colors.grey),
              ),
            ],
          ),
        ),
        // Save sits outside the scrolling list so it stays reachable however many
        // options the list grows to.
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            FilledButton(
              key: const Key('save-receipt'),
              onPressed: _save,
              child: Text(tr(context, 'Save')),
            ),
            if (widget.onTestPrint != null) ...[
              const SizedBox(height: 8),
              OutlinedButton.icon(
                key: const Key('test-print'),
                icon: const Icon(Icons.print),
                // Save first so the printed sample reflects the current settings.
                onPressed: () async {
                  _save();
                  await widget.onTestPrint!();
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text(tr(context, 'Test receipt sent to printer'))));
                  }
                },
                label: Text(tr(context, 'Print test receipt')),
              ),
            ],
          ]),
        ),
      ]),
    );
  }
}
