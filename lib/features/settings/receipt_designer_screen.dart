import 'package:flutter/material.dart';

import '../../core/db/settings_store.dart';

/// Lets a manager pick what shows up on the printed customer receipt: a
/// header line above the shop name, the existing footer, and toggles for the
/// tax id, cashier name, and order type/table.
///
/// This is layout choice, not shop identity ([ShopSettingsScreen] already owns
/// name/tax id text), so it lives as its own screen the receipt builder reads
/// back from at print time via the same [SettingsStore] keys.
class ReceiptDesignerScreen extends StatefulWidget {
  const ReceiptDesignerScreen({super.key, required this.settings, required this.onChanged});

  final SettingsStore settings;

  /// Called after Save so anything caching the receipt layout reloads.
  final VoidCallback onChanged;

  @override
  State<ReceiptDesignerScreen> createState() => _ReceiptDesignerScreenState();
}

/// Raw setting keys, kept local to this screen since [SettingsStore] only
/// exposes typed accessors for the shop-identity fields it already owned.
const _headerKey = 'receipt_header';
const _showCashierKey = 'receipt_show_cashier';
const _showOrderTypeKey = 'receipt_show_ordertype';

class _ReceiptDesignerScreenState extends State<ReceiptDesignerScreen> {
  late final TextEditingController _header;
  late final TextEditingController _footer;
  late bool _showTax;
  late bool _showCashier;
  late bool _showOrderType;

  @override
  void initState() {
    super.initState();
    _header = TextEditingController(text: widget.settings.getString(_headerKey) ?? '');
    _footer = TextEditingController(text: widget.settings.receiptFooter ?? '');
    _showTax = widget.settings.receiptShowTax;
    _showCashier = widget.settings.getBool(_showCashierKey, fallback: true);
    _showOrderType = widget.settings.getBool(_showOrderTypeKey, fallback: true);
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
    widget.onChanged();
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Saved')));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Receipt designer')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            key: const Key('receipt-header'),
            controller: _header,
            decoration: const InputDecoration(
              labelText: 'Header line',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('receipt-footer'),
            controller: _footer,
            minLines: 2,
            maxLines: 5,
            decoration: const InputDecoration(
              labelText: 'Footer',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          SwitchListTile(
            key: const Key('t-tax'),
            title: const Text('Show tax id'),
            value: _showTax,
            onChanged: (v) => setState(() => _showTax = v),
          ),
          SwitchListTile(
            key: const Key('t-cashier'),
            title: const Text('Show cashier'),
            value: _showCashier,
            onChanged: (v) => setState(() => _showCashier = v),
          ),
          SwitchListTile(
            key: const Key('t-ordertype'),
            title: const Text('Show order type & table'),
            value: _showOrderType,
            onChanged: (v) => setState(() => _showOrderType = v),
          ),
          const SizedBox(height: 8),
          // No print preview here: rendering a live receipt needs the printer
          // pipeline this screen intentionally stays decoupled from.
          const Text(
            'A live print preview is not shown here. Changes apply to the next printed receipt.',
            style: TextStyle(color: Colors.grey),
          ),
          const SizedBox(height: 16),
          FilledButton(
            key: const Key('save-receipt'),
            onPressed: _save,
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }
}
