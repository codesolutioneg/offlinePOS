import 'package:flutter/material.dart';

import '../../app/pos_session.dart';
import '../../domain/catalogue.dart';
import 'modifier_sheet.dart';

/// The selling screen: catalogue on the right, the order on the left.
///
/// Every interaction here is synchronous against local storage. There is no spinner
/// and no await on a tap, because a till that waits on a server is a till that stops
/// when the line does.
class SellScreen extends StatefulWidget {
  const SellScreen({
    super.key,
    required this.session,
    required this.formatAmount,
    this.onPaid,
    this.staleness,
  });

  final PosSession session;
  final String Function(double) formatAmount;
  final void Function(dynamic order)? onPaid;
  final Duration? staleness;

  @override
  State<SellScreen> createState() => _SellScreenState();
}

class _SellScreenState extends State<SellScreen> {
  int? _categoryId;
  String _search = '';

  PosSession get s => widget.session;

  Future<void> _tap(Product product) async {
    final groups = s.catalogue.modifierGroupsFor(product.id);
    if (groups.isEmpty) {
      setState(() => s.addProduct(product));
      return;
    }
    final chosen = await showModalBottomSheet<List<ChosenModifier>>(
      context: context,
      isScrollControlled: true,
      builder: (_) => ModifierSheet(
        product: product,
        groups: groups,
        formatAmount: widget.formatAmount,
      ),
    );
    if (chosen != null) setState(() => s.addProduct(product, chosen: chosen));
  }

  void _pay() {
    if (!s.hasLines) return;
    final order = s.pay();
    setState(() {});
    widget.onPaid?.call(order);
  }

  @override
  Widget build(BuildContext context) {
    final products = s.catalogue.products(categoryId: _categoryId, search: _search);
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            if (widget.staleness != null && widget.staleness!.inHours >= 24)
              _StaleBanner(age: widget.staleness!),
            Expanded(
              child: Row(
                children: [
                  SizedBox(width: 340, child: _orderPanel()),
                  const VerticalDivider(width: 1),
                  Expanded(child: _catalogue(products)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _catalogue(List<Product> products) => Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(8),
            child: TextField(
              key: const Key('search'),
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: 'Search or scan',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              onChanged: (v) => setState(() => _search = v),
            ),
          ),
          SizedBox(height: 44, child: _categoryStrip()),
          Expanded(
            child: products.isEmpty
                ? const Center(child: Text('No products'))
                : GridView.builder(
                    padding: const EdgeInsets.all(8),
                    gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                      maxCrossAxisExtent: 180, childAspectRatio: 1.3,
                      mainAxisSpacing: 8, crossAxisSpacing: 8),
                    itemCount: products.length,
                    itemBuilder: (_, i) => _ProductTile(
                      product: products[i],
                      price: widget.formatAmount(products[i].price),
                      onTap: () => _tap(products[i]),
                    ),
                  ),
          ),
        ],
      );

  Widget _categoryStrip() {
    final cats = s.catalogue.categories();
    return ListView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      children: [
        ChoiceChip(
          label: const Text('All'),
          selected: _categoryId == null,
          onSelected: (_) => setState(() => _categoryId = null),
        ),
        for (final c in cats) ...[
          const SizedBox(width: 6),
          ChoiceChip(
            label: Text(c.name),
            selected: _categoryId == c.id,
            onSelected: (_) => setState(() => _categoryId = c.id),
          ),
        ],
      ],
    );
  }

  Widget _orderPanel() => Column(
        children: [
          Expanded(
            child: !s.hasLines
                ? const Center(child: Text('Start adding products'))
                : ListView(
                    children: [
                      for (final line in s.current.lines)
                        _LineTile(
                          key: Key('line-${line.uuid}'),
                          name: line.name,
                          qty: line.quantity,
                          amount: widget.formatAmount(line.total),
                          modifiers: [
                            for (final m in line.modifiers)
                              '${m.name}${m.quantity > 1 ? ' x${m.quantity.toStringAsFixed(0)}' : ''}'
                                  '${m.unitPrice == 0 ? '' : '  ${widget.formatAmount(m.total * line.quantity)}'}'
                          ],
                          onRemove: () => setState(() => s.removeLine(line.uuid)),
                          onQty: (q) => setState(() => s.setQuantity(line.uuid, q)),
                        ),
                    ],
                  ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                const Text('TOTAL', style: TextStyle(fontWeight: FontWeight.bold)),
                const Spacer(),
                Text(widget.formatAmount(s.total),
                    key: const Key('total'),
                    style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: SizedBox(
              width: double.infinity,
              height: 56,
              child: FilledButton(
                key: const Key('pay'),
                onPressed: s.hasLines ? _pay : null,
                child: const Text('Payment'),
              ),
            ),
          ),
        ],
      );
}

class _StaleBanner extends StatelessWidget {
  const _StaleBanner({required this.age});
  final Duration age;

  @override
  Widget build(BuildContext context) => Container(
        key: const Key('stale-banner'),
        width: double.infinity,
        color: Colors.amber.shade200,
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 12),
        // Say it plainly rather than let a cashier sell from month-old prices
        // believing they are current.
        child: Text('Prices last updated ${age.inDays} day(s) ago',
            textAlign: TextAlign.center),
      );
}

class _ProductTile extends StatelessWidget {
  const _ProductTile({required this.product, required this.price, required this.onTap});
  final Product product;
  final String price;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Card(
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: Key('product-${product.id}'),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(product.name, textAlign: TextAlign.center, maxLines: 2,
                    overflow: TextOverflow.ellipsis),
                const SizedBox(height: 6),
                Text(price, style: const TextStyle(fontWeight: FontWeight.bold)),
              ],
            ),
          ),
        ),
      );
}

class _LineTile extends StatelessWidget {
  const _LineTile({
    super.key,
    required this.name,
    required this.qty,
    required this.amount,
    required this.modifiers,
    required this.onRemove,
    required this.onQty,
  });

  final String name;
  final double qty;
  final String amount;
  final List<String> modifiers;
  final VoidCallback onRemove;
  final void Function(double) onQty;

  @override
  Widget build(BuildContext context) => ListTile(
        dense: true,
        title: Row(children: [
          Expanded(child: Text(name)),
          Text(amount, style: const TextStyle(fontWeight: FontWeight.bold)),
        ]),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final m in modifiers)
              Text('   + $m', style: const TextStyle(fontSize: 12, color: Colors.green)),
            Row(children: [
              IconButton(
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.remove_circle_outline, size: 18),
                  onPressed: () => onQty(qty - 1)),
              Text(qty.toStringAsFixed(qty == qty.roundToDouble() ? 0 : 3)),
              IconButton(
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.add_circle_outline, size: 18),
                  onPressed: () => onQty(qty + 1)),
            ]),
          ],
        ),
        trailing: IconButton(icon: const Icon(Icons.delete_outline), onPressed: onRemove),
      );
}
