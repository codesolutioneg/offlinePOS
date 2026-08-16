import 'package:flutter/material.dart';

import '../../core/db/settings_store.dart';
import '../../core/i18n/l10n.dart';
import '../../domain/catalogue.dart';
import '../../domain/order.dart';

/// Tax rules per category, set independently for dine-in, takeaway and delivery, so
/// a shop can (for example) charge 14% on food eaten in and 0% on the same food
/// taken away. A blank field means "no override": lines in that category keep the
/// product's own tax rate. Prices stay tax-inclusive, so this changes the tax shown
/// and reported, not what the customer pays.
///
/// The service charge lives here too, because it is the other money rule that varies
/// by order type. Unlike tax it does change what the customer pays, so it is stamped
/// onto each bill as it opens: editing it never re-prices a table already eating.
class TaxSettingsScreen extends StatefulWidget {
  const TaxSettingsScreen({
    super.key,
    required this.settings,
    required this.categories,
    required this.onChanged,
  });

  final SettingsStore settings;
  final List<Category> categories;
  final VoidCallback onChanged;

  @override
  State<TaxSettingsScreen> createState() => _TaxSettingsScreenState();
}

class _TaxSettingsScreenState extends State<TaxSettingsScreen> {
  static const _types = [
    OrderType.dineIn,
    OrderType.takeaway,
    OrderType.toGo,
    OrderType.delivery,
  ];

  String _typeLabel(BuildContext context, OrderType t) => switch (t) {
        OrderType.dineIn => tr(context, 'Dine-in'),
        OrderType.takeaway => tr(context, 'Takeaway'),
        OrderType.toGo => tr(context, 'To go'),
        OrderType.delivery => tr(context, 'Delivery'),
      };

  /// The shop's service percentage. Blank reads as off, the same as zero, so clearing
  /// the field cannot leave the last percentage quietly charging.
  void _setServicePercent(String raw) {
    final text = raw.trim();
    final percent = text.isEmpty ? 0.0 : double.tryParse(text);
    if (percent == null) return; // ignore an unparseable entry
    widget.settings.serviceChargePercent = percent;
    widget.onChanged();
    setState(() {});
  }

  void _setServiceType(OrderType type, bool enabled) {
    widget.settings.setServiceChargeOrderType(type, enabled);
    widget.onChanged();
    setState(() {});
  }

  /// A percentage without a trailing zero: 12.5 stays 12.5, 12.0 shows as 12.
  static String _pct(double p) =>
      p == p.roundToDouble() ? p.toStringAsFixed(0) : p.toStringAsFixed(1);

  Widget _serviceChargeCard(BuildContext context) {
    final percent = widget.settings.serviceChargePercent;
    final charged = widget.settings.serviceChargeOrderTypes;
    return Card(
      key: const Key('service-charge-card'),
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(tr(context, 'Service charge'),
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            const SizedBox(height: 4),
            Text(
              tr(context, 'Added to a bill when it opens. Zero turns it off.'),
              style: const TextStyle(color: Colors.black54),
            ),
            const SizedBox(height: 8),
            TextFormField(
              key: const Key('service-charge-percent'),
              initialValue: percent <= 0 ? '' : _pct(percent),
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(
                labelText: tr(context, 'Service charge'),
                suffixText: '%',
                border: const OutlineInputBorder(),
                isDense: true,
              ),
              onChanged: _setServicePercent,
            ),
            const SizedBox(height: 4),
            Text(tr(context, 'Charged on')),
            for (final type in _types)
              CheckboxListTile(
                key: Key('service-type-${type.name}'),
                dense: true,
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                title: Text(_typeLabel(context, type)),
                value: charged.contains(type),
                onChanged: (v) => _setServiceType(type, v ?? false),
              ),
          ],
        ),
      ),
    );
  }

  void _set(int categoryId, OrderType type, String raw) {
    final text = raw.trim();
    // Blank clears the override; anything else is parsed as a percent.
    final rate = text.isEmpty ? null : double.tryParse(text);
    if (text.isNotEmpty && rate == null) return; // ignore an unparseable entry
    widget.settings.setCategoryTaxRate(categoryId, type, rate);
    widget.onChanged();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(tr(context, 'Tax rules'))),
      // The service charge is not a per-category rule, so a shop with no categories
      // yet loses the tax matrix here, not the whole screen.
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          _serviceChargeCard(context),
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 4, 4, 12),
            child: Text(
              widget.categories.isEmpty
                  ? tr(context, 'No categories yet')
                  : tr(context, 'Blank keeps the product tax. Set 0 to remove tax.'),
              style: const TextStyle(color: Colors.black54),
            ),
          ),
          for (final c in widget.categories)
            Card(
              key: Key('tax-cat-${c.id}'),
              margin: const EdgeInsets.only(bottom: 10),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(c.name,
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        for (final type in _types) ...[
                          Expanded(
                            child: TextFormField(
                              key: Key('tax-${c.id}-${type.name}'),
                              initialValue:
                                  widget.settings.categoryTaxRate(c.id, type)?.toString() ?? '',
                              keyboardType: const TextInputType.numberWithOptions(decimal: true),
                              decoration: InputDecoration(
                                labelText: _typeLabel(context, type),
                                suffixText: '%',
                                border: const OutlineInputBorder(),
                                isDense: true,
                              ),
                              onChanged: (v) => _set(c.id, type, v),
                            ),
                          ),
                          if (type != _types.last) const SizedBox(width: 8),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
