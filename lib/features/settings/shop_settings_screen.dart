import 'package:flutter/material.dart';

import '../../core/db/settings_store.dart';
import '../../core/i18n/l10n.dart';
import '../../domain/order.dart' show OrderType, OrderTypeLabel;

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
  late bool _askGuests;
  late bool _askCashierOnOpen;
  late int _cutoverHour;
  late Set<OrderType> _offered;
  late bool _sectionsSide;
  late final TextEditingController _cashVariance;

  @override
  void initState() {
    super.initState();
    _shopName = TextEditingController(text: widget.settings.shopName ?? '');
    _taxId = TextEditingController(text: widget.settings.taxId ?? '');
    _receiptFooter = TextEditingController(text: widget.settings.receiptFooter ?? '');
    _showTax = widget.settings.receiptShowTax;
    _askGuests = widget.settings.askGuestCount;
    _askCashierOnOpen = widget.settings.askCashierOnOpen;
    _cutoverHour = widget.settings.businessDayCutoverHour;
    _offered = widget.settings.shopOrderTypes;
    _sectionsSide = widget.settings.floorSectionsSide;
    _cashVariance = TextEditingController(
        text: widget.settings.cashVarianceTolerance.toStringAsFixed(2));
  }

  /// Offer or withdraw one kind of sale shop-wide. The last one standing cannot be
  /// withdrawn: a till that offers nothing sells nothing.
  void _toggleOffered(OrderType t, bool on) {
    if (!on && _offered.length <= 1) return;
    setState(() {
      final next = _offered.toSet();
      on ? next.add(t) : next.remove(t);
      _offered = next;
    });
  }

  @override
  void dispose() {
    _shopName.dispose();
    _taxId.dispose();
    _receiptFooter.dispose();
    _cashVariance.dispose();
    super.dispose();
  }

  void _save() {
    widget.settings.shopName = _shopName.text.trim();
    widget.settings.taxId = _taxId.text.trim();
    widget.settings.receiptFooter = _receiptFooter.text.trim();
    widget.settings.receiptShowTax = _showTax;
    widget.settings.askGuestCount = _askGuests;
    widget.settings.askCashierOnOpen = _askCashierOnOpen;
    widget.settings.businessDayCutoverHour = _cutoverHour;
    widget.settings.shopOrderTypes = _offered;
    widget.settings.floorSectionsSide = _sectionsSide;
    // Unreadable or blank reads as zero, which is the strict default: the drawer
    // has to match to the cent.
    widget.settings.cashVarianceTolerance =
        double.tryParse(_cashVariance.text.trim()) ?? 0;
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
          SwitchListTile(
            key: const Key('ask-guest-count'),
            title: Text(tr(context, 'Ask for the guest count')),
            subtitle: Text(tr(context, 'When a table is seated from the floor')),
            value: _askGuests,
            onChanged: (v) => setState(() => _askGuests = v),
          ),
          SwitchListTile(
            key: const Key('ask-cashier-on-open'),
            title: Text(tr(context, 'Ask who is opening the table')),
            subtitle: Text(tr(context, 'On a shared till, assigns the table to them')),
            value: _askCashierOnOpen,
            onChanged: (v) => setState(() => _askCashierOnOpen = v),
          ),
          const SizedBox(height: 12),
          // What this shop sells at all, above whatever each role may ring: a shop
          // that does not deliver has nobody who takes a delivery.
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text(tr(context, 'Order types this shop offers')),
            subtitle: Text(tr(context,
                'A type that is off is offered to nobody, whatever their role allows')),
          ),
          Wrap(
            spacing: 8,
            children: [
              for (final t in OrderType.values)
                FilterChip(
                  key: Key('shop-type-${t.name.toLowerCase()}'),
                  label: Text(tr(context, t.label)),
                  selected: _offered.contains(t),
                  onSelected: (v) => _toggleOffered(t, v),
                ),
            ],
          ),
          const SizedBox(height: 12),
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text(tr(context, 'Table sections')),
          ),
          Wrap(
            spacing: 8,
            children: [
              ChoiceChip(
                key: const Key('sections-side'),
                label: Text(tr(context, 'Beside the plan')),
                selected: _sectionsSide,
                onSelected: (_) => setState(() => _sectionsSide = true),
              ),
              ChoiceChip(
                key: const Key('sections-top'),
                label: Text(tr(context, 'Above the plan')),
                selected: !_sectionsSide,
                onSelected: (_) => setState(() => _sectionsSide = false),
              ),
            ],
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<int>(
            key: const Key('business-day-cutover'),
            initialValue: _cutoverHour,
            decoration: InputDecoration(
              labelText: tr(context, 'Business day starts at'),
              helperText: tr(context,
                  'Sales before this hour count as the previous trading day'),
              helperMaxLines: 2,
              border: const OutlineInputBorder(),
            ),
            items: [
              for (var h = 0; h < 24; h++)
                DropdownMenuItem(
                  value: h,
                  child: Text('${h.toString().padLeft(2, '0')}:00'),
                ),
            ],
            onChanged: (v) => setState(() => _cutoverHour = v ?? _cutoverHour),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('cash-variance-tolerance'),
            controller: _cashVariance,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              labelText: tr(context, 'Allowed difference'),
              helperText: tr(context,
                  'How far the counted drawer may sit from the expected drawer and still close the shift'),
              helperMaxLines: 2,
              border: const OutlineInputBorder(),
            ),
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
