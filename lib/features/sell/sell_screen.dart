import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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
    this.drawer,
    this.onHold,
    this.onOpenOrders,
    this.onLineVoided,
    this.online,
    this.pendingToSync,
    this.categoryColors = const {},
    this.quickComments = const ['No onions', 'Extra spicy', 'Well done', 'Allergy'],
    this.discountReasons = const [],
    this.authorize,
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


  /// The navigation drawer (open orders, history, reports, staff, settings). Owned
  /// by the app shell so this screen stays about selling.
  final Widget? drawer;

  /// Parks the current order on its table/tab and fires the kitchen ticket. The app
  /// shell owns it because holding is what sends food to the kitchen.
  final VoidCallback? onHold;

  /// Opens the parked-orders list to recall a table.
  final VoidCallback? onOpenOrders;

  /// A line was voided with a reason, so the shell can print a kitchen cancel slip
  /// if the line had already been fired.
  final void Function(OrderLine line, String reason)? onLineVoided;

  /// Whether the server is reachable, for the status badge. Orders sell and queue
  /// the same either way; this only tells the cashier what will happen at close.
  final ValueListenable<bool>? online;

  /// How many sales are held on the till waiting for the shift-close batch.
  final int Function()? pendingToSync;

  /// Category id to colour (ARGB), so the product grid is colour-coded per category
  /// the way Dishflow does. Empty leaves tiles plain.
  final Map<int, int> categoryColors;

  /// Manager-curated quick picks for line notes and discount reasons.
  final List<String> quickComments;
  final List<String> discountReasons;

  /// Gate for privileged actions (discount, void): returns true if approved. When
  /// null, actions are not gated.
  final Future<bool> Function()? authorize;

  @override
  State<SellScreen> createState() => _SellScreenState();
}

class _SellScreenState extends State<SellScreen> {
  int? _categoryId;
  String _search = '';

  // A hardware barcode scanner behaves as a keyboard that types the code fast and
  // ends with Enter. We buffer keystrokes and, when they arrive faster than a human
  // could type and finish with Enter, treat them as a scan and add the product.
  final FocusNode _scanFocus = FocusNode();
  String _scanBuffer = '';
  DateTime _lastScanKey = DateTime.fromMillisecondsSinceEpoch(0);

  PosSession get s => widget.session;

  @override
  void initState() {
    super.initState();
    widget.catalogueChanged?.addListener(_onCatalogueChanged);
  }

  @override
  void dispose() {
    widget.catalogueChanged?.removeListener(_onCatalogueChanged);
    _scanFocus.dispose();
    super.dispose();
  }

  void _onScanKey(KeyEvent e) {
    if (e is! KeyDownEvent) return;
    final now = DateTime.now();
    // A gap longer than a scanner burst means this is human typing, not a scan.
    if (now.difference(_lastScanKey).inMilliseconds > 150) _scanBuffer = '';
    _lastScanKey = now;
    if (e.logicalKey == LogicalKeyboardKey.enter ||
        e.logicalKey == LogicalKeyboardKey.numpadEnter) {
      _finishScan();
      return;
    }
    final ch = e.character;
    if (ch != null && ch.length == 1 && ch.trim().isNotEmpty) _scanBuffer += ch;
  }

  void _finishScan() {
    final code = _scanBuffer.trim();
    _scanBuffer = '';
    // Too short to be a real barcode: ignore, so a stray Enter does nothing.
    if (code.length < 3) return;
    final product = s.catalogue.byBarcode(code);
    if (product == null) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('No product for barcode $code')));
      return;
    }
    _changed(() => s.addProduct(product));
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        key: const Key('scanned'),
        content: Text('Added ${product.name}'),
        duration: const Duration(milliseconds: 900)));
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
    // A weighed item is priced per unit of weight, so ask for the weight instead
    // of adding a single unit; the entered weight becomes the line quantity.
    if (product.soldByWeight) {
      final weight = await _askWeight(product);
      if (weight == null || weight <= 0) return;
      _changed(() => s.addProduct(product, qty: weight));
      return;
    }
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

  Future<double?> _askWeight(Product product) {
    final ctrl = TextEditingController();
    return showDialog<double>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Weight for ${product.name}'),
        content: TextField(
          key: const Key('weight-field'),
          controller: ctrl,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(
              labelText: 'Weight',
              suffixText: 'x ${widget.formatAmount(product.price)}',
              border: const OutlineInputBorder()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            key: const Key('weight-ok'),
            onPressed: () => Navigator.pop(ctx, double.tryParse(ctrl.text.trim())),
            child: const Text('Add'),
          ),
        ],
      ),
    );
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
    // A discount gives away money, so it needs manager approval.
    if (widget.authorize != null && !await widget.authorize!()) return;
    if (!mounted) return;
    final ctrl = TextEditingController(
        text: s.current.discountPercent > 0
            ? s.current.discountPercent.toStringAsFixed(0)
            : '');
    final reasonCtrl = TextEditingController(text: s.current.discountReason ?? '');
    final result = await showDialog<Map<String, dynamic>>(
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
          const SizedBox(height: 8),
          Wrap(spacing: 8, children: [
            for (final q in const [0, 5, 10, 15, 20])
              ActionChip(label: Text('$q%'), onPressed: () => ctrl.text = '$q'),
          ]),
          const SizedBox(height: 8),
          // A discount without a reason is what a manager cannot audit later, so the
          // reason is captured here rather than reconstructed from memory.
          TextField(
            controller: reasonCtrl,
            decoration: const InputDecoration(
                labelText: 'Reason (optional)', border: OutlineInputBorder(), isDense: true),
          ),
          if (widget.discountReasons.isNotEmpty) ...[
            const SizedBox(height: 8),
            Wrap(spacing: 8, children: [
              for (final r in widget.discountReasons)
                ActionChip(label: Text(r), onPressed: () => reasonCtrl.text = r),
            ]),
          ],
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            key: const Key('apply-discount'),
            onPressed: () => Navigator.pop(ctx, {
              'pct': double.tryParse(ctrl.text.trim()) ?? 0,
              'reason': reasonCtrl.text.trim(),
            }),
            child: const Text('Apply'),
          ),
        ],
      ),
    );
    if (result != null) {
      final reason = (result['reason'] as String).isEmpty ? null : result['reason'] as String;
      _changed(() => s.setDiscount(result['pct'] as double, reason: reason));
    }
  }

  // ── per-line actions: note, discount, void with reason ───────────

  Future<void> _lineActions(OrderLine line) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            key: const Key('line-note'),
            leading: const Icon(Icons.sticky_note_2_outlined),
            title: const Text('Note for kitchen'),
            subtitle: line.note != null ? Text(line.note!) : null,
            onTap: () => Navigator.pop(ctx, 'note'),
          ),
          ListTile(
            key: const Key('line-discount'),
            leading: const Icon(Icons.percent),
            title: const Text('Line discount'),
            subtitle: line.discountPercent > 0
                ? Text('${line.discountPercent.toStringAsFixed(0)}%')
                : null,
            onTap: () => Navigator.pop(ctx, 'discount'),
          ),
          ListTile(
            key: const Key('line-void'),
            leading: const Icon(Icons.remove_circle_outline, color: Colors.red),
            title: const Text('Void this line'),
            onTap: () => Navigator.pop(ctx, 'void'),
          ),
        ]),
      ),
    );
    if (action == 'note') await _lineNote(line);
    if (action == 'discount') await _lineDiscount(line);
    if (action == 'void') await _voidLine(line);
  }

  Future<void> _lineNote(OrderLine line) async {
    final ctrl = TextEditingController(text: line.note ?? '');
    final note = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(line.name),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
            controller: ctrl,
            autofocus: true,
            decoration: const InputDecoration(
                labelText: 'Kitchen note', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 8),
          Wrap(spacing: 8, children: [
            for (final q in widget.quickComments)
              ActionChip(label: Text(q), onPressed: () => ctrl.text = q),
          ]),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
              child: const Text('Save')),
        ],
      ),
    );
    if (note != null) _changed(() => s.setLineNote(line.uuid, note));
  }

  Future<void> _lineDiscount(OrderLine line) async {
    final ctrl = TextEditingController(
        text: line.discountPercent > 0 ? line.discountPercent.toStringAsFixed(0) : '');
    final pct = await showDialog<double>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Discount ${line.name}'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(
              labelText: 'Line discount', suffixText: '%', border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
              key: const Key('apply-line-discount'),
              onPressed: () => Navigator.pop(ctx, double.tryParse(ctrl.text.trim()) ?? 0),
              child: const Text('Apply')),
        ],
      ),
    );
    if (pct != null) _changed(() => s.setLineDiscount(line.uuid, pct));
  }

  Future<void> _voidLine(OrderLine line) async {
    // Voiding a line is a privileged action, so it needs manager approval first.
    if (widget.authorize != null && !await widget.authorize!()) return;
    if (!mounted) return;
    final reason = await _askReason('Void ${line.name}');
    if (reason == null) return;
    _changed(() {
      s.voidLine(line.uuid, reason);
    });
    // If it had been fired to the kitchen, the shell prints a cancel slip so the
    // line stops cooking. jouma's deleted-line audit, on paper.
    if (line.printedToKitchen) widget.onLineVoided?.call(line, reason);
  }

  /// A required reason, with quick picks. Returns null on cancel.
  Future<String?> _askReason(String title) {
    final ctrl = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSt) => AlertDialog(
          title: Text(title),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(
              key: const Key('void-reason'),
              controller: ctrl,
              autofocus: true,
              decoration: const InputDecoration(
                  labelText: 'Reason', border: OutlineInputBorder()),
              onChanged: (_) => setSt(() {}),
            ),
            const SizedBox(height: 8),
            Wrap(spacing: 8, children: [
              for (final r in const ['Customer changed', 'Wrong item', 'Out of stock', 'Kitchen error'])
                ActionChip(label: Text(r), onPressed: () => setSt(() => ctrl.text = r)),
            ]),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            FilledButton(
              key: const Key('confirm-reason'),
              onPressed: ctrl.text.trim().isEmpty ? null : () => Navigator.pop(ctx, ctrl.text.trim()),
              child: const Text('Confirm'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _orderNote() async {
    final ctrl = TextEditingController(text: s.current.note ?? '');
    final note = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Order note'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(
              labelText: 'Note for the whole order', border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
              child: const Text('Save')),
        ],
      ),
    );
    if (note != null) _changed(() => s.setNote(note));
  }

  Future<void> _setGuests() async {
    final ctrl = TextEditingController(
        text: s.current.guestCount != null ? '${s.current.guestCount}' : '');
    final n = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Guests'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
              labelText: 'Number of guests', border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, int.tryParse(ctrl.text.trim())),
              child: const Text('Set')),
        ],
      ),
    );
    if (n != null) _changed(() => s.setGuestCount(n));
  }

  Future<void> _setTable() async {
    final ctrl = TextEditingController(text: s.current.tableLabel ?? '');
    final label = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Table / tab'),
        content: TextField(
          key: const Key('table-field'),
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(
              labelText: 'Table number or name', border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
              child: const Text('Set')),
        ],
      ),
    );
    if (label != null) _changed(() => s.setTable(label));
  }

  Future<void> _deliveryDetails() async {
    final name = TextEditingController(text: s.current.customerName ?? '');
    final phone = TextEditingController(text: s.current.customerPhone ?? '');
    final addr = TextEditingController(text: s.current.customerAddress ?? '');
    final cost = TextEditingController(
        text: s.current.deliveryCost > 0 ? s.current.deliveryCost.toStringAsFixed(2) : '');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delivery details'),
        content: SizedBox(
          width: 360,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(
                key: const Key('delivery-name'),
                controller: name,
                decoration: const InputDecoration(labelText: 'Customer name', border: OutlineInputBorder(), isDense: true)),
            const SizedBox(height: 8),
            TextField(
                key: const Key('delivery-phone'),
                controller: phone,
                keyboardType: TextInputType.phone,
                decoration: const InputDecoration(labelText: 'Phone', border: OutlineInputBorder(), isDense: true)),
            const SizedBox(height: 8),
            TextField(
                key: const Key('delivery-address'),
                controller: addr,
                maxLines: 2,
                decoration: const InputDecoration(labelText: 'Address', border: OutlineInputBorder(), isDense: true)),
            const SizedBox(height: 8),
            TextField(
                key: const Key('delivery-cost'),
                controller: cost,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: 'Delivery charge', border: OutlineInputBorder(), isDense: true)),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save')),
        ],
      ),
    );
    if (ok == true) {
      _changed(() {
        s.setDeliveryCustomer(
            name: name.text, phone: phone.text, address: addr.text);
        s.setDeliveryCost(double.tryParse(cost.text.trim()) ?? 0);
      });
    }
  }

  void _hold() {
    if (!s.hasLines) return;
    widget.onHold?.call();
    setState(() {});
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        key: Key('held'),
        content: Text('Order parked. Recall it from Open orders.'),
        duration: Duration(seconds: 2),
      ));
    }
  }

  void _newOrder() {
    _changed(() => s.newOrder());
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
        onConfirm: (payments, label, tip) {
          Navigator.pop(ctx);
          _complete(payments, label, tip);
        },
      ),
    );
  }

  void _complete(List<OrderPayment> payments, String label, double tip) {
    if (tip > 0) s.setTip(tip);
    final order = s.pay(payments: payments);
    setState(() {});
    widget.onPaid?.call(order);
    if (!mounted) return;
    // The sale is saved on this till now; it is sent to Odoo with the rest of the
    // shift's orders at close, so the message does not promise an instant sync.
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      key: const Key('sale-complete'),
      content: Text('Sale complete: ${widget.formatAmount(order.total)} ($label). '
          'Saved on this till.'),
      duration: const Duration(seconds: 3),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final products = s.catalogue.products(categoryId: _categoryId, search: _search);
    final o = s.current;
    final title = o.tableLabel != null
        ? '${o.type.label} - ${o.tableLabel}'
        : o.type.label;
    return Scaffold(
      drawer: widget.drawer,
      appBar: AppBar(
        title: Text(title, key: const Key('order-context')),
        actions: [
          _statusChip(),
          if (widget.onOpenOrders != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Badge(
                isLabelVisible: s.heldCount > 0,
                label: Text('${s.heldCount}'),
                child: IconButton(
                  key: const Key('open-orders'),
                  tooltip: 'Open orders',
                  icon: const Icon(Icons.table_restaurant),
                  onPressed: widget.onOpenOrders,
                ),
              ),
            ),
          IconButton(
            key: const Key('new-order'),
            tooltip: 'New order',
            icon: const Icon(Icons.note_add_outlined),
            onPressed: s.hasLines ? _newOrder : null,
          ),
        ],
      ),
      body: KeyboardListener(
        focusNode: _scanFocus,
        autofocus: true,
        onKeyEvent: _onScanKey,
        child: SafeArea(
        child: Column(
          children: [
            if (widget.staleness != null && widget.staleness!.inHours >= 24)
              _StaleBanner(age: widget.staleness!),
            Expanded(
              child: Row(
                children: [
                  SizedBox(width: 360, child: _orderPanel()),
                  const VerticalDivider(width: 1),
                  Expanded(child: _catalogue(products)),
                ],
              ),
            ),
          ],
        ),
        ),
      ),
    );
  }

  /// Online/offline badge plus how many sales are waiting for the close-of-shift
  /// batch. This is the honest status a cashier needs: selling works either way,
  /// but this says whether the orders have left the till yet.
  Widget _statusChip() {
    final online = widget.online;
    Widget badge(bool isOnline) {
      final pending = widget.pendingToSync?.call() ?? 0;
      final color = isOnline ? Colors.green : Colors.grey;
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(
          key: const Key('online-status'),
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(isOnline ? Icons.cloud_done : Icons.cloud_off, size: 18, color: color),
            const SizedBox(width: 4),
            Text(isOnline ? 'Online' : 'Offline', style: TextStyle(color: color, fontSize: 13)),
            if (pending > 0)
              Padding(
                padding: const EdgeInsets.only(left: 6),
                child: Chip(
                  key: const Key('pending-count'),
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  label: Text('$pending to sync', style: const TextStyle(fontSize: 11)),
                ),
              ),
          ],
        ),
      );
    }

    if (online == null) return badge(false);
    return ValueListenableBuilder<bool>(
      valueListenable: online,
      builder: (context, isOnline, child) => badge(isOnline),
    );
  }

  /// The configured colour for a product's category, or null to leave the tile
  /// plain. Colour-coding the grid is how a cashier finds a category fast.
  Color? _colorFor(int? categoryId) {
    if (categoryId == null) return null;
    final argb = widget.categoryColors[categoryId];
    return argb == null ? null : Color(argb);
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
                      color: _colorFor(products[i].categoryId),
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
          _orderTypeStrip(),
          _contextBar(),
          const Divider(height: 1),
          Expanded(
            child: !s.hasLines
                ? const Center(child: Text('Start adding products'))
                : ListView(
                    children: [
                      for (final line in s.current.lines)
                        _LineTile(
                          key: Key('line-${line.uuid}'),
                          line: line,
                          amount: widget.formatAmount(line.total),
                          format: widget.formatAmount,
                          onRemove: () => _changed(() => s.removeLine(line.uuid)),
                          onQty: (q) => _changed(() => s.setQuantity(line.uuid, q)),
                          onTapLine: () => _lineActions(line),
                        ),
                    ],
                  ),
          ),
          const Divider(height: 1),
          _totals(),
          _actions(),
        ],
      );

  /// Where the sale is served. Changing it reshapes what the context bar asks for
  /// (a table for dine-in, an address and charge for delivery).
  Widget _orderTypeStrip() => Material(
        color: Colors.grey.shade100,
        child: SizedBox(
          height: 48,
          // Scrolls rather than overflows: three chips do not fit a narrow till
          // panel, and a clipped selector is worse than a scrollable one.
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            children: [
              for (final t in OrderType.values) ...[
                ChoiceChip(
                  key: Key('order-type-${t.name.toLowerCase()}'),
                  label: Text(t.label),
                  selected: s.current.type == t,
                  onSelected: (_) => _changed(() => s.setOrderType(t)),
                ),
                const SizedBox(width: 6),
              ],
            ],
          ),
        ),
      );

  /// Customer, table, guests, note: the details the order type calls for.
  Widget _contextBar() {
    final o = s.current;
    return Column(children: [
      ListTile(
        dense: true,
        leading: const Icon(Icons.person_outline),
        title: Text(o.customerName ?? 'Walk-in customer'),
        subtitle: o.customerPhone != null ? Text(o.customerPhone!) : null,
        trailing: TextButton(
          key: const Key('customer'),
          onPressed: o.type == OrderType.delivery ? _deliveryDetails : _openCustomer,
          child: Text(o.customerName == null ? 'Add' : 'Change'),
        ),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Wrap(spacing: 8, runSpacing: 4, children: [
          if (o.type == OrderType.dineIn) ...[
            ActionChip(
              key: const Key('table'),
              avatar: const Icon(Icons.table_bar, size: 16),
              label: Text(o.tableLabel == null ? 'Table' : 'Table ${o.tableLabel}'),
              onPressed: _setTable,
            ),
            ActionChip(
              key: const Key('guests'),
              avatar: const Icon(Icons.groups, size: 16),
              label: Text(o.guestCount == null ? 'Guests' : '${o.guestCount} guests'),
              onPressed: _setGuests,
            ),
          ],
          if (o.type == OrderType.delivery)
            ActionChip(
              key: const Key('delivery'),
              avatar: const Icon(Icons.delivery_dining, size: 16),
              label: Text(o.deliveryCost > 0
                  ? 'Delivery ${widget.formatAmount(o.deliveryCost)}'
                  : 'Delivery details'),
              onPressed: _deliveryDetails,
            ),
          ActionChip(
            key: const Key('order-note'),
            avatar: const Icon(Icons.notes, size: 16),
            label: Text(o.note == null ? 'Note' : 'Note added'),
            onPressed: _orderNote,
          ),
        ]),
      ),
    ]);
  }

  Widget _totals() => Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            if (s.current.discountPercent > 0 ||
                s.current.deliveryCost > 0) ...[
              _totalRow('Subtotal', widget.formatAmount(s.current.subtotal), muted: true),
              if (s.current.discountPercent > 0)
                _totalRow(
                    'Discount ${s.current.discountPercent.toStringAsFixed(0)}%',
                    '-${widget.formatAmount(s.current.subtotal * s.current.discountPercent / 100)}',
                    key: const Key('discount-line'), green: true),
              if (s.current.deliveryCost > 0)
                _totalRow('Delivery', widget.formatAmount(s.current.deliveryCost), muted: true),
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
                  label: Text(s.current.discountPercent > 0 ? 'Edit discount' : 'Add discount'),
                ),
              ),
          ],
        ),
      );

  Widget _totalRow(String label, String amount,
      {Key? key, bool muted = false, bool green = false}) {
    final style = TextStyle(
        color: green ? Colors.green.shade700 : (muted ? Colors.black54 : null));
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(children: [
        Text(label, key: key, style: style),
        const Spacer(),
        Text(amount, style: style),
      ]),
    );
  }

  Widget _actions() => Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        child: Row(children: [
          Expanded(
            child: OutlinedButton.icon(
              key: const Key('hold'),
              onPressed: s.hasLines ? _hold : null,
              icon: const Icon(Icons.pause_circle_outline),
              label: const Text('Hold'),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 2,
            child: SizedBox(
              height: 56,
              child: FilledButton(
                key: const Key('pay'),
                onPressed: s.hasLines ? _pay : null,
                child: const Text('Payment'),
              ),
            ),
          ),
        ]),
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
  const _ProductTile({
    required this.product,
    required this.price,
    required this.onTap,
    this.color,
  });
  final Product product;
  final String price;
  final VoidCallback onTap;
  final Color? color;

  @override
  Widget build(BuildContext context) => Card(
        clipBehavior: Clip.antiAlias,
        // A tinted fill plus a coloured top stripe, so the category reads at a
        // glance without hurting the legibility of the name and price.
        color: color?.withValues(alpha: 0.12),
        child: InkWell(
          key: Key('product-${product.id}'),
          onTap: onTap,
          child: Container(
            decoration: color == null
                ? null
                : BoxDecoration(
                    border: Border(top: BorderSide(color: color!, width: 4))),
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
    required this.line,
    required this.amount,
    required this.format,
    required this.onRemove,
    required this.onQty,
    required this.onTapLine,
  });

  final OrderLine line;
  final String amount;
  final String Function(double) format;
  final VoidCallback onRemove;
  final void Function(double) onQty;
  final VoidCallback onTapLine;

  @override
  Widget build(BuildContext context) => ListTile(
        dense: true,
        onTap: onTapLine,
        title: Row(children: [
          Expanded(child: Text(line.name)),
          Text(amount, style: const TextStyle(fontWeight: FontWeight.bold)),
        ]),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final m in line.modifiers)
              Text(
                  '   + ${m.name}${m.quantity > 1 ? ' x${m.quantity.toStringAsFixed(0)}' : ''}'
                  '${m.unitPrice == 0 ? '' : '  ${format(m.total * line.quantity)}'}',
                  style: const TextStyle(fontSize: 12, color: Colors.green)),
            if (line.discountPercent > 0)
              Text('   -${line.discountPercent.toStringAsFixed(0)}% discount',
                  style: TextStyle(fontSize: 12, color: Colors.orange.shade800)),
            if (line.note != null)
              Text('   ${line.note}',
                  style: const TextStyle(fontSize: 12, fontStyle: FontStyle.italic)),
            Row(children: [
              IconButton(
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.remove_circle_outline, size: 18),
                  onPressed: () => onQty(line.quantity - 1)),
              Text(line.quantity
                  .toStringAsFixed(line.quantity == line.quantity.roundToDouble() ? 0 : 3)),
              IconButton(
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.add_circle_outline, size: 18),
                  onPressed: () => onQty(line.quantity + 1)),
            ]),
          ],
        ),
        trailing: IconButton(icon: const Icon(Icons.delete_outline), onPressed: onRemove),
      );
}

/// The tender step: choose how the sale is paid, split it across methods if needed,
/// add a tip, enter cash received to see the change, and confirm. A real payment
/// moment with feedback, not a silent clear.
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
  final void Function(List<OrderPayment> payments, String label, double tip) onConfirm;

  @override
  State<_PaymentSheet> createState() => _PaymentSheetState();
}

class _PaymentSheetState extends State<_PaymentSheet> {
  PaymentMethod? _method;
  final List<OrderPayment> _tenders = [];
  bool _split = false;
  late final TextEditingController _received =
      TextEditingController(text: widget.total.toStringAsFixed(2));
  final TextEditingController _tip = TextEditingController();

  @override
  void initState() {
    super.initState();
    if (widget.methods.isNotEmpty) _method = widget.methods.first;
  }

  @override
  void dispose() {
    _received.dispose();
    _tip.dispose();
    super.dispose();
  }

  double get _tipAmount => double.tryParse(_tip.text.trim()) ?? 0;
  double get _grand => widget.total + _tipAmount;
  bool get _isCash => _method?.isCash ?? true;
  double get _receivedAmount => double.tryParse(_received.text.trim()) ?? 0;
  double get _paidSoFar => _tenders.fold(0.0, (s, t) => s + t.amount);
  double get _remaining => _grand - _paidSoFar;

  double get _change => _split
      ? (_paidSoFar - _grand)
      : ((_isCash ? _receivedAmount : _grand) - _grand);

  bool get _covered => _split
      ? _paidSoFar >= _grand - 0.001
      : (_isCash ? _receivedAmount >= _grand - 0.001 : true);

  void _addTender() {
    if (_method == null) return;
    final amt = _remaining > 0 ? _remaining : 0.0;
    setState(() => _tenders.add(
        OrderPayment(methodId: _method!.id, amount: amt, label: _method!.name)));
  }

  void _confirm() {
    final label = _split
        ? 'Split'
        : (_method?.name ?? 'Cash');
    final List<OrderPayment> payments;
    if (_split) {
      payments = List.of(_tenders);
    } else if (_method != null) {
      // A cash overpayment records the full tendered amount so the receipt can show
      // the change; a card is charged exactly the grand total.
      final amt = _isCash ? _receivedAmount : _grand;
      payments = [OrderPayment(methodId: _method!.id, amount: amt, label: _method!.name)];
    } else {
      payments = <OrderPayment>[];
    }
    widget.onConfirm(payments, label, _tipAmount);
  }

  List<double> _quickAmounts() {
    final t = _grand;
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
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(children: [
              const Text('Payment',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              const Spacer(),
              // Split lets one bill be paid part cash, part card, which a single
              // shared-total field cannot express.
              FilterChip(
                key: const Key('split-toggle'),
                label: const Text('Split'),
                selected: _split,
                onSelected: (v) => setState(() {
                  _split = v;
                  _tenders.clear();
                }),
              ),
            ]),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('Total due'),
                Text(widget.format(_grand),
                    key: const Key('pay-total'),
                    style: const TextStyle(fontSize: 26, fontWeight: FontWeight.bold)),
              ],
            ),
            const SizedBox(height: 8),
            TextField(
              key: const Key('tip'),
              controller: _tip,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                labelText: 'Tip (optional)', border: OutlineInputBorder(), isDense: true),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 12),
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
            if (_split) ...[
              const SizedBox(height: 12),
              for (final t in _tenders)
                ListTile(
                  dense: true,
                  title: Text(t.label ?? 'Payment'),
                  trailing: Text(widget.format(t.amount)),
                ),
              Row(children: [
                Expanded(
                  child: Text('Remaining ${widget.format(_remaining < 0 ? 0 : _remaining)}',
                      key: const Key('remaining')),
                ),
                TextButton.icon(
                  key: const Key('add-tender'),
                  onPressed: _remaining > 0.001 ? _addTender : null,
                  icon: const Icon(Icons.add),
                  label: Text('Add ${_method?.name ?? 'tender'}'),
                ),
              ]),
            ] else if (_isCash) ...[
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
            ],
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
                        color: _change >= 0 ? Colors.green.shade700 : Colors.red)),
              ],
            ),
            const SizedBox(height: 18),
            SizedBox(
              height: 52,
              child: FilledButton(
                key: const Key('confirm-payment'),
                onPressed: _covered ? _confirm : null,
                child: Text('Charge ${widget.format(_grand)}'),
              ),
            ),
            const SizedBox(height: 4),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
          ],
        ),
      ),
    );
  }
}
