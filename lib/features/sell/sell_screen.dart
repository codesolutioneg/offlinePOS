import 'package:flutter/material.dart';

import '../../app/pos_session.dart';
import '../../domain/catalogue.dart';
import '../../domain/order.dart';
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
    this.onChanged,
    this.onSignOut,
    this.staleness,
    this.catalogueChanged,
    this.syncNow,
  });

  final PosSession session;
  final String Function(double) formatAmount;
  final void Function(dynamic order)? onPaid;

  /// Fired whenever the open order gains or loses lines, so anything that needs to
  /// know a customer is mid-order does not have to poll for it.
  final VoidCallback? onChanged;

  /// Ends the shift. Absent, the screen shows no control for it.
  final VoidCallback? onSignOut;

  final Duration? staleness;

  /// Ticks when a background sync refreshes the catalogue, so the grid reloads
  /// itself instead of the cashier leaving and re-entering the screen.
  final Listenable? catalogueChanged;

  /// Kicks a sync right after a sale so the order reaches Odoo promptly instead
  /// of waiting for the next timer tick.
  final Future<void> Function()? syncNow;

  @override
  State<SellScreen> createState() => _SellScreenState();
}

class _SellScreenState extends State<SellScreen> {
  int? _categoryId;
  String _search = '';

  PosSession get s => widget.session;

  @override
  void initState() {
    super.initState();
    widget.catalogueChanged?.addListener(_onCatalogueChanged);
  }

  @override
  void dispose() {
    widget.catalogueChanged?.removeListener(_onCatalogueChanged);
    super.dispose();
  }

  // A fresh catalogue landed from the server: rebuild so the grid re-queries it.
  void _onCatalogueChanged() {
    if (mounted) setState(() {});
  }

  /// Redraws and tells the owner the open order changed. Every mutation goes
  /// through here so the two can never drift apart.
  void _changed(VoidCallback mutate) {
    setState(mutate);
    widget.onChanged?.call();
  }

  Future<void> _tap(Product product) async {
    final groups = s.catalogue.modifierGroupsFor(product.id);
    if (groups.isEmpty) {
      _changed(() => s.addProduct(product));
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
    if (chosen != null) _changed(() => s.addProduct(product, chosen: chosen));
  }

  Future<void> _openCustomer() async {
    final ctrl = TextEditingController();
    final result = await showDialog<Object?>(
      context: context,
      builder: (ctx) {
        var results = s.catalogue.customers(limit: 30);
        return StatefulBuilder(
          builder: (ctx, setSt) => AlertDialog(
            title: const Text('Customer'),
            content: SizedBox(
              width: 360,
              height: 420,
              child: Column(children: [
                TextField(
                  controller: ctrl,
                  autofocus: true,
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search),
                    hintText: 'Search name or phone',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  onChanged: (v) =>
                      setSt(() => results = s.catalogue.customers(search: v, limit: 30)),
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: results.isEmpty
                      ? const Center(child: Text('No customers'))
                      : ListView(children: [
                          for (final c in results)
                            ListTile(
                              dense: true,
                              title: Text(c.name),
                              subtitle: c.phone != null ? Text(c.phone!) : null,
                              onTap: () => Navigator.pop(ctx, c),
                            ),
                        ]),
                ),
              ]),
            ),
            actions: [
              TextButton(
                key: const Key('customer-clear'),
                onPressed: () => Navigator.pop(ctx, 'clear'),
                child: const Text('Walk-in'),
              ),
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            ],
          ),
        );
      },
    );
    if (result is Customer) {
      _changed(() => s.setCustomer(result));
    } else if (result == 'clear') {
      _changed(() => s.setCustomer(null));
    }
  }

  Future<void> _openDiscount() async {
    final ctrl = TextEditingController(
        text: s.current.discountPercent > 0
            ? s.current.discountPercent.toStringAsFixed(0)
            : '');
    final pct = await showDialog<double>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Order discount'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
            controller: ctrl,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(
                labelText: 'Discount', suffixText: '%', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 12),
          Wrap(spacing: 8, children: [
            for (final q in const [0, 5, 10, 15, 20])
              ActionChip(label: Text('$q%'), onPressed: () => Navigator.pop(ctx, q.toDouble())),
          ]),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            key: const Key('apply-discount'),
            onPressed: () => Navigator.pop(ctx, double.tryParse(ctrl.text.trim()) ?? 0),
            child: const Text('Apply'),
          ),
        ],
      ),
    );
    if (pct != null) _changed(() => s.setDiscount(pct));
  }

  void _pay() {
    if (!s.hasLines) return;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => _PaymentSheet(
        total: s.total,
        format: widget.formatAmount,
        methods: s.catalogue.paymentMethods(),
        onConfirm: (payments, label) {
          Navigator.pop(ctx);
          _complete(payments, label);
        },
      ),
    );
  }

  void _complete(List<OrderPayment> payments, String label) {
    final order = s.pay(payments: payments);
    setState(() {});
    widget.onPaid?.call(order);
    // Push it now rather than waiting for the timer, so it lands in Odoo promptly.
    widget.syncNow?.call();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      key: const Key('sale-complete'),
      content: Text('Sale complete: ${widget.formatAmount(order.total)} ($label). '
          'Syncing to Odoo.'),
      duration: const Duration(seconds: 3),
    ));
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
          if (widget.onSignOut != null)
            Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: const EdgeInsets.only(left: 8, top: 8),
                child: TextButton.icon(
                  key: const Key('sign-out'),
                  // Disabled mid-order: handing the till over with a customer's
                  // half-rung sale on screen loses whose sale it was.
                  onPressed: s.hasLines ? null : widget.onSignOut,
                  icon: const Icon(Icons.logout),
                  label: const Text('End shift'),
                ),
              ),
            ),
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
          Material(
            color: Colors.grey.shade100,
            child: ListTile(
              dense: true,
              leading: const Icon(Icons.person_outline),
              title: Text(s.current.customerName ?? 'Walk-in customer'),
              trailing: TextButton(
                key: const Key('customer'),
                onPressed: _openCustomer,
                child: Text(s.current.partnerId == null ? 'Add' : 'Change'),
              ),
            ),
          ),
          const Divider(height: 1),
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
                          onRemove: () => _changed(() => s.removeLine(line.uuid)),
                          onQty: (q) => _changed(() => s.setQuantity(line.uuid, q)),
                        ),
                    ],
                  ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              children: [
                if (s.current.discountPercent > 0) ...[
                  Row(children: [
                    const Text('Subtotal', style: TextStyle(color: Colors.black54)),
                    const Spacer(),
                    Text(widget.formatAmount(s.current.subtotal),
                        style: const TextStyle(color: Colors.black54)),
                  ]),
                  const SizedBox(height: 4),
                  Row(children: [
                    Text('Discount ${s.current.discountPercent.toStringAsFixed(0)}%',
                        key: const Key('discount-line'),
                        style: TextStyle(color: Colors.green.shade700)),
                    const Spacer(),
                    Text('-${widget.formatAmount(s.current.subtotal - s.total)}',
                        style: TextStyle(color: Colors.green.shade700)),
                  ]),
                  const SizedBox(height: 6),
                ],
                Row(children: [
                  const Text('TOTAL', style: TextStyle(fontWeight: FontWeight.bold)),
                  const Spacer(),
                  Text(widget.formatAmount(s.total),
                      key: const Key('total'),
                      style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
                ]),
                if (s.hasLines)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      key: const Key('discount'),
                      onPressed: _openDiscount,
                      icon: const Icon(Icons.percent, size: 16),
                      label: Text(s.current.discountPercent > 0
                          ? 'Edit discount'
                          : 'Add discount'),
                    ),
                  ),
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

/// The tender step: choose how the sale is paid, enter cash received to see the
/// change, and confirm. A real payment moment with feedback, not a silent clear.
class _PaymentSheet extends StatefulWidget {
  const _PaymentSheet({
    required this.total,
    required this.format,
    required this.methods,
    required this.onConfirm,
  });

  final double total;
  final String Function(double) format;
  final List<PaymentMethod> methods;
  final void Function(List<OrderPayment> payments, String label) onConfirm;

  @override
  State<_PaymentSheet> createState() => _PaymentSheetState();
}

class _PaymentSheetState extends State<_PaymentSheet> {
  PaymentMethod? _method;
  late final TextEditingController _received =
      TextEditingController(text: widget.total.toStringAsFixed(2));

  @override
  void initState() {
    super.initState();
    if (widget.methods.isNotEmpty) _method = widget.methods.first;
  }

  @override
  void dispose() {
    _received.dispose();
    super.dispose();
  }

  bool get _isCash => _method?.isCash ?? true;
  double get _receivedAmount => double.tryParse(_received.text.trim()) ?? 0;
  double get _change => (_isCash ? _receivedAmount : widget.total) - widget.total;
  bool get _covered => _isCash ? _receivedAmount >= widget.total - 0.001 : true;

  void _confirm() {
    final label = _method?.name ?? 'Cash';
    final payments = _method != null
        ? [OrderPayment(methodId: _method!.id, amount: widget.total)]
        : <OrderPayment>[];
    widget.onConfirm(payments, label);
  }

  List<double> _quickAmounts() {
    final t = widget.total;
    final set = <double>{t};
    for (final r in const [5, 10, 20, 50, 100, 200, 500]) {
      final up = (t / r).ceil() * r.toDouble();
      if (up > t) set.add(up);
    }
    final list = set.toList()..sort();
    return list.take(4).toList();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
          20, 4, 20, 20 + MediaQuery.of(context).viewInsets.bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('Payment',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('Total due'),
              Text(widget.format(widget.total),
                  key: const Key('pay-total'),
                  style: const TextStyle(fontSize: 26, fontWeight: FontWeight.bold)),
            ],
          ),
          const SizedBox(height: 14),
          if (widget.methods.isNotEmpty)
            Wrap(
              spacing: 8,
              children: [
                for (final m in widget.methods)
                  ChoiceChip(
                    key: Key('method-${m.id}'),
                    label: Text(m.name),
                    selected: _method?.id == m.id,
                    onSelected: (_) => setState(() => _method = m),
                  ),
              ],
            )
          else
            const Text('Cash', style: TextStyle(color: Colors.black54)),
          if (_isCash) ...[
            const SizedBox(height: 16),
            TextField(
              key: const Key('received'),
              controller: _received,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                labelText: 'Amount received',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                for (final a in _quickAmounts())
                  ActionChip(
                    label: Text(widget.format(a)),
                    onPressed: () =>
                        setState(() => _received.text = a.toStringAsFixed(2)),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('Change'),
                Text(_change >= 0 ? widget.format(_change) : '-',
                    key: const Key('change'),
                    style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        color: _change >= 0
                            ? Colors.green.shade700
                            : Colors.red)),
              ],
            ),
          ],
          const SizedBox(height: 18),
          SizedBox(
            height: 52,
            child: FilledButton(
              key: const Key('confirm-payment'),
              onPressed: _covered ? _confirm : null,
              child: Text('Charge ${widget.format(widget.total)}'),
            ),
          ),
          const SizedBox(height: 4),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
  }
}
