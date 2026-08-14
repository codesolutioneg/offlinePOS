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
  static const _types = [OrderType.dineIn, OrderType.takeaway, OrderType.delivery];

  String _typeLabel(BuildContext context, OrderType t) => switch (t) {
        OrderType.dineIn => tr(context, 'Dine-in'),
        OrderType.takeaway => tr(context, 'Takeaway'),
        OrderType.delivery => tr(context, 'Delivery'),
      };

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
      body: widget.categories.isEmpty
          ? Center(child: Text(tr(context, 'No categories yet')))
          : ListView(
              padding: const EdgeInsets.all(12),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 4, 4, 12),
                  child: Text(
                    tr(context, 'Blank keeps the product tax. Set 0 to remove tax.'),
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
