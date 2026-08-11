import 'package:flutter/material.dart';

import '../../core/db/settings_store.dart';
import '../../core/i18n/l10n.dart';

/// Lets a manager edit the shop identity that prints on the receipt, on the
/// device, without a rebuild.
///
/// A rebrand, a tax id correction, or a footer change (a new promo line, a
/// return policy) should not require shipping a new build to every till. This
/// screen writes straight into [SettingsStore], which the receipt renderer
/// already reads from live.
class ShopSettingsScreen extends StatefulWidget {
  const ShopSettingsScreen({super.key, required this.settings, required this.onChanged});

  final SettingsStore settings;

  /// Called after Save so the app can refresh the receipt with the new copy.
  final VoidCallback onChanged;

  @override
  State<ShopSettingsScreen> createState() => _ShopSettingsScreenState();
}

class _ShopSettingsScreenState extends State<ShopSettingsScreen> {
  late final TextEditingController _shopName;
  late final TextEditingController _taxId;
  late final TextEditingController _receiptFooter;
  late bool _showTax;

  @override
  void initState() {
    super.initState();
    _shopName = TextEditingController(text: widget.settings.shopName ?? '');
    _taxId = TextEditingController(text: widget.settings.taxId ?? '');
    _receiptFooter = TextEditingController(text: widget.settings.receiptFooter ?? '');
    _showTax = widget.settings.receiptShowTax;
  }

  @override
  void dispose() {
    _shopName.dispose();
    _taxId.dispose();
    _receiptFooter.dispose();
    super.dispose();
  }

  void _save() {
    widget.settings.shopName = _shopName.text.trim();
    widget.settings.taxId = _taxId.text.trim();
    widget.settings.receiptFooter = _receiptFooter.text.trim();
    widget.settings.receiptShowTax = _showTax;
    widget.onChanged();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr(context, 'Saved'))));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(tr(context, 'Shop & receipt'))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            key: const Key('shop-name'),
            controller: _shopName,
            decoration: InputDecoration(
              labelText: tr(context, 'Shop name'),
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('tax-id'),
            controller: _taxId,
            decoration: InputDecoration(
              labelText: tr(context, 'Tax id'),
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('receipt-footer'),
            controller: _receiptFooter,
            minLines: 2,
            maxLines: 5,
            decoration: InputDecoration(
              labelText: tr(context, 'Receipt footer'),
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          SwitchListTile(
            key: const Key('show-tax'),
            title: Text(tr(context, 'Show tax on receipt')),
            value: _showTax,
            onChanged: (v) => setState(() => _showTax = v),
          ),
          const SizedBox(height: 16),
          FilledButton(
            key: const Key('save-shop'),
            onPressed: _save,
            child: Text(tr(context, 'Save')),
          ),
        ],
      ),
    );
  }
}
