import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/pos_session.dart';
import '../../core/i18n/l10n.dart';
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
    this.onSendToKitchen,
    this.onOpenOrders,
    this.onLineVoided,
    this.online,
    this.pendingToSync,
    this.categoryColors = const {},
    this.quickComments = const ['No onions', 'Extra spicy', 'Well done', 'Allergy'],
    this.discountReasons = const [],
    this.discountPercents = const [5, 10, 15, 20],
    this.maxDiscountPercent = 0,
    this.authorize,
    this.unavailableProducts = const {},
    this.onToggleAvailable,
    this.favourites = const {},
    this.onToggleFavourite,
    this.gridColumns = 0,
    this.extraCustomers,
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

  /// Fires the kitchen ticket for the current order but leaves it on the counter,
  /// so a table's food can be sent without parking the order.
  final VoidCallback? onSendToKitchen;

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

  /// Configurable discount preset percentages and an optional cap (0 = none).
  final List<double> discountPercents;
  final double maxDiscountPercent;

  /// Gate for privileged actions (discount, void): returns true if approved. When
  /// null, actions are not gated.
  final Future<bool> Function()? authorize;

  /// Products marked sold-out; their tiles are greyed and cannot be added.
  final Set<int> unavailableProducts;

  /// Toggle a product's availability (86 / un-86). Manager-gated by the caller.
  final void Function(int productId, bool available)? onToggleAvailable;

  /// Products pinned as favourites, shown under a Favourites filter chip.
  final Set<int> favourites;

  /// Toggle a product favourite. Manager-gated by the caller.
  final void Function(int productId, bool favourite)? onToggleFavourite;

  /// Fixed tiles-per-row for the product grid; 0 fits by width.
  final int gridColumns;

  /// Local (till-created) customers matching a query, merged into the picker so a
  /// customer added on the device is reusable.
  final List<Customer> Function(String query)? extraCustomers;

  @override
  State<SellScreen> createState() => _SellScreenState();
}

class _SellScreenState extends State<SellScreen> {
  int? _categoryId;
  bool _favesOnly = false;
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
          SnackBar(content: Text('${tr(context, 'No product for barcode')} $code')));
      return;
    }
    _changed(() => s.addProduct(product));
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        key: const Key('scanned'),
        content: Text('${tr(context, 'Added')} ${product.name}'),
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

  /// Block adding a sold-out item; otherwise ring it as normal.
  void _tapProduct(Product product) {
    if (widget.unavailableProducts.contains(product.id)) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${product.name}: ${tr(context, 'sold out')}')));
      return;
    }
    _tap(product);
  }

  /// Long-press menu: 86 the item or pin it as a favourite. Both manager-gated.
  Future<void> _productMenu(Product product) async {
    final soldOut = widget.unavailableProducts.contains(product.id);
    final fave = widget.favourites.contains(product.id);
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(title: Text(product.name, style: const TextStyle(fontWeight: FontWeight.bold))),
          if (widget.onToggleAvailable != null)
            ListTile(
              key: const Key('menu-86'),
              leading: Icon(soldOut ? Icons.check_circle_outline : Icons.block),
              title: Text(tr(ctx, soldOut ? 'Mark available' : 'Mark sold out')),
              onTap: () => Navigator.pop(ctx, 'avail'),
            ),
          if (widget.onToggleFavourite != null)
            ListTile(
              key: const Key('menu-fave'),
              leading: Icon(fave ? Icons.star : Icons.star_border),
              title: Text(tr(ctx, fave ? 'Remove favourite' : 'Add favourite')),
              onTap: () => Navigator.pop(ctx, 'fave'),
            ),
        ]),
      ),
    );
    if (action == null) return;
    if (widget.authorize != null && !await widget.authorize!()) return;
    if (action == 'avail') {
      widget.onToggleAvailable?.call(product.id, soldOut);
    } else if (action == 'fave') {
      widget.onToggleFavourite?.call(product.id, !fave);
    }
    if (mounted) _changed(() {});
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
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSt) {
          final valid = (double.tryParse(ctrl.text.trim()) ?? 0) > 0;
          return AlertDialog(
            title: Text('${tr(ctx, 'Weight for')} ${product.name}'),
            content: TextField(
              key: const Key('weight-field'),
              controller: ctrl,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(
                  labelText: tr(ctx, 'Weight'),
                  suffixText: 'x ${widget.formatAmount(product.price)}',
                  border: const OutlineInputBorder()),
              onChanged: (_) => setSt(() {}),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr(ctx, 'Cancel'))),
              FilledButton(
                key: const Key('weight-ok'),
                // Disabled until a positive weight is entered, so pressing Add can
                // never silently do nothing.
                onPressed: valid ? () => Navigator.pop(ctx, double.parse(ctrl.text.trim())) : null,
                child: Text(tr(ctx, 'Add')),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _openCustomer() async {
    final ctrl = TextEditingController();
    final result = await showDialog<Object?>(
      context: context,
      builder: (ctx) {
        // Merge the read-only Odoo partners with the till's own local customers,
        // so a customer added on the device is pickable here too.
        List<Customer> lookup(String v) => [
              ...?widget.extraCustomers?.call(v),
              ...s.catalogue.customers(search: v, limit: 30),
            ];
        var results = lookup('');
        return StatefulBuilder(
          builder: (ctx, setSt) => AlertDialog(
            title: Text(tr(ctx, 'Customer')),
            content: SizedBox(
              width: 360,
              height: 420,
              child: Column(children: [
                TextField(
                  controller: ctrl,
                  autofocus: true,
                  decoration: InputDecoration(
                    prefixIcon: const Icon(Icons.search),
                    hintText: tr(ctx, 'Search name or phone'),
                    border: const OutlineInputBorder(),
                    isDense: true,
                  ),
                  onChanged: (v) => setSt(() => results = lookup(v)),
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: results.isEmpty
                      ? Center(child: Text(tr(ctx, 'No customers')))
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
                child: Text(tr(ctx, 'Walk-in')),
              ),
              TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr(ctx, 'Cancel'))),
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
        title: Text(tr(ctx, 'Order discount')),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
            controller: ctrl,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
                labelText: tr(ctx, 'Discount'), suffixText: '%', border: const OutlineInputBorder()),
          ),
          const SizedBox(height: 8),
          // Quick-pick chips from the manager-configured presets, plus a 0 to clear.
          Wrap(spacing: 8, children: [
            ActionChip(label: Text(tr(ctx, 'None')), onPressed: () => ctrl.text = '0'),
            for (final q in widget.discountPercents)
              ActionChip(
                label: Text('${q.toStringAsFixed(q == q.roundToDouble() ? 0 : 1)}%'),
                onPressed: () =>
                    ctrl.text = q.toStringAsFixed(q == q.roundToDouble() ? 0 : 1),
              ),
          ]),
          if (widget.maxDiscountPercent > 0)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                  '${tr(ctx, 'Max')} ${widget.maxDiscountPercent.toStringAsFixed(0)}%',
                  style: const TextStyle(color: Colors.black54, fontSize: 12)),
            ),
          const SizedBox(height: 8),
          // A discount without a reason is what a manager cannot audit later, so the
          // reason is captured here rather than reconstructed from memory.
          TextField(
            controller: reasonCtrl,
            decoration: InputDecoration(
                labelText: tr(ctx, 'Reason (optional)'), border: const OutlineInputBorder(), isDense: true),
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
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr(ctx, 'Cancel'))),
          FilledButton(
            key: const Key('apply-discount'),
            onPressed: () => Navigator.pop(ctx, {
              'pct': double.tryParse(ctrl.text.trim()) ?? 0,
              'reason': reasonCtrl.text.trim(),
            }),
            child: Text(tr(ctx, 'Apply')),
          ),
        ],
      ),
    );
    if (result != null) {
      var pct = result['pct'] as double;
      // Enforce the configured cap so a mis-typed 100% off cannot go through.
      if (widget.maxDiscountPercent > 0 && pct > widget.maxDiscountPercent) {
        pct = widget.maxDiscountPercent;
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text(
                  '${tr(context, 'Capped at')} ${widget.maxDiscountPercent.toStringAsFixed(0)}%')));
        }
      }
      final reason = (result['reason'] as String).isEmpty ? null : result['reason'] as String;
      _changed(() => s.setDiscount(pct, reason: reason));
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
            title: Text(tr(ctx, 'Note for kitchen')),
            subtitle: line.note != null ? Text(line.note!) : null,
            onTap: () => Navigator.pop(ctx, 'note'),
          ),
          ListTile(
            key: const Key('line-discount'),
            leading: const Icon(Icons.percent),
            title: Text(tr(ctx, 'Line discount')),
            subtitle: line.discountPercent > 0
                ? Text('${line.discountPercent.toStringAsFixed(0)}%')
                : null,
            onTap: () => Navigator.pop(ctx, 'discount'),
          ),
          ListTile(
            key: const Key('line-void'),
            leading: const Icon(Icons.remove_circle_outline, color: Colors.red),
            title: Text(tr(ctx, 'Void this line')),
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
            decoration: InputDecoration(
                labelText: tr(ctx, 'Kitchen note'), border: const OutlineInputBorder()),
          ),
          const SizedBox(height: 8),
          Wrap(spacing: 8, children: [
            for (final q in widget.quickComments)
              ActionChip(label: Text(q), onPressed: () => ctrl.text = q),
          ]),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr(ctx, 'Cancel'))),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
              child: Text(tr(ctx, 'Save'))),
        ],
      ),
    );
    if (note != null) _changed(() => s.setLineNote(line.uuid, note));
  }

  Future<void> _lineDiscount(OrderLine line) async {
    // A line discount gives away money exactly like an order discount, so it gets
    // the same manager gate and the same cap and presets.
    if (widget.authorize != null && !await widget.authorize!()) return;
    if (!mounted) return;
    final ctrl = TextEditingController(
        text: line.discountPercent > 0 ? line.discountPercent.toStringAsFixed(0) : '');
    final pct = await showDialog<double>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('${tr(ctx, 'Discount')} ${line.name}'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
            controller: ctrl,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
                labelText: tr(ctx, 'Line discount'), suffixText: '%', border: const OutlineInputBorder()),
          ),
          const SizedBox(height: 8),
          Wrap(spacing: 8, children: [
            ActionChip(label: Text(tr(ctx, 'None')), onPressed: () => ctrl.text = '0'),
            for (final q in widget.discountPercents)
              ActionChip(
                label: Text('${q.toStringAsFixed(q == q.roundToDouble() ? 0 : 1)}%'),
                onPressed: () => ctrl.text = q.toStringAsFixed(q == q.roundToDouble() ? 0 : 1),
              ),
          ]),
          if (widget.maxDiscountPercent > 0)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text('${tr(ctx, 'Max')} ${widget.maxDiscountPercent.toStringAsFixed(0)}%',
                  style: const TextStyle(color: Colors.black54, fontSize: 12)),
            ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr(ctx, 'Cancel'))),
          FilledButton(
              key: const Key('apply-line-discount'),
              onPressed: () => Navigator.pop(ctx, double.tryParse(ctrl.text.trim()) ?? 0),
              child: Text(tr(ctx, 'Apply'))),
        ],
      ),
    );
    if (pct == null) return;
    var applied = pct;
    if (widget.maxDiscountPercent > 0 && applied > widget.maxDiscountPercent) {
      applied = widget.maxDiscountPercent;
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(
                '${tr(context, 'Capped at')} ${widget.maxDiscountPercent.toStringAsFixed(0)}%')));
      }
    }
    _changed(() => s.setLineDiscount(line.uuid, applied));
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
              decoration: InputDecoration(
                  labelText: tr(ctx, 'Reason'), border: const OutlineInputBorder()),
              onChanged: (_) => setSt(() {}),
            ),
            const SizedBox(height: 8),
            Wrap(spacing: 8, children: [
              for (final r in const ['Customer changed', 'Wrong item', 'Out of stock', 'Kitchen error'])
                ActionChip(label: Text(tr(ctx, r)), onPressed: () => setSt(() => ctrl.text = r)),
            ]),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr(ctx, 'Cancel'))),
            FilledButton(
              key: const Key('confirm-reason'),
              onPressed: ctrl.text.trim().isEmpty ? null : () => Navigator.pop(ctx, ctrl.text.trim()),
              child: Text(tr(ctx, 'Confirm')),
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
        title: Text(tr(ctx, 'Order note')),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: InputDecoration(
              labelText: tr(ctx, 'Note for the whole order'), border: const OutlineInputBorder()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr(ctx, 'Cancel'))),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
              child: Text(tr(ctx, 'Save'))),
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
        title: Text(tr(ctx, 'Guests')),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(
              labelText: tr(ctx, 'Number of guests'), border: const OutlineInputBorder()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr(ctx, 'Cancel'))),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, int.tryParse(ctrl.text.trim())),
              child: Text(tr(ctx, 'Set'))),
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
        title: Text(tr(ctx, 'Table / tab')),
        content: TextField(
          key: const Key('table-field'),
          controller: ctrl,
          autofocus: true,
          decoration: InputDecoration(
              labelText: tr(ctx, 'Table number or name'), border: const OutlineInputBorder()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr(ctx, 'Cancel'))),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
              child: Text(tr(ctx, 'Set'))),
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
        title: Text(tr(ctx, 'Delivery details')),
        content: SizedBox(
          width: 360,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(
                key: const Key('delivery-name'),
                controller: name,
                decoration: InputDecoration(labelText: tr(ctx, 'Customer name'), border: const OutlineInputBorder(), isDense: true)),
            const SizedBox(height: 8),
            TextField(
                key: const Key('delivery-phone'),
                controller: phone,
                keyboardType: TextInputType.phone,
                decoration: InputDecoration(labelText: tr(ctx, 'Phone'), border: const OutlineInputBorder(), isDense: true)),
            const SizedBox(height: 8),
            TextField(
                key: const Key('delivery-address'),
                controller: addr,
                maxLines: 2,
                decoration: InputDecoration(labelText: tr(ctx, 'Address'), border: const OutlineInputBorder(), isDense: true)),
            const SizedBox(height: 8),
            TextField(
                key: const Key('delivery-cost'),
                controller: cost,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(labelText: tr(ctx, 'Delivery charge'), border: const OutlineInputBorder(), isDense: true)),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr(ctx, 'Cancel'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr(ctx, 'Save'))),
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
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        key: const Key('held'),
        content: Text(tr(context, 'Order parked. Recall it from Open orders.')),
        duration: const Duration(seconds: 2),
      ));
    }
  }

  void _newOrder() {
    _changed(() => s.newOrder());
  }

  void _sendToKitchen() {
    if (!s.hasLines) return;
    widget.onSendToKitchen?.call();
    setState(() {});
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        key: const Key('sent-kitchen'),
        content: Text(tr(context, 'Sent to kitchen.')),
        duration: const Duration(seconds: 2),
      ));
    }
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
    var products = s.catalogue.products(categoryId: _categoryId, search: _search);
    if (_favesOnly) {
      products = products.where((p) => widget.favourites.contains(p.id)).toList();
    }
    final o = s.current;
    final title = o.tableLabel != null
        ? '${tr(context, o.type.label)} - ${o.tableLabel}'
        : tr(context, o.type.label);
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
                  tooltip: tr(context, 'Open orders'),
                  icon: const Icon(Icons.table_restaurant),
                  onPressed: widget.onOpenOrders,
                ),
              ),
            ),
          IconButton(
            key: const Key('new-order'),
            tooltip: tr(context, 'New order'),
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
            Text(isOnline ? tr(context, 'Online') : tr(context, 'Offline'),
                style: TextStyle(color: color, fontSize: 13)),
            if (pending > 0)
              Padding(
                padding: const EdgeInsets.only(left: 6),
                child: Chip(
                  key: const Key('pending-count'),
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  label: Text('$pending ${tr(context, 'to sync')}', style: const TextStyle(fontSize: 11)),
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
                  label: Text(tr(context, 'End shift')),
                ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.all(8),
            child: TextField(
              key: const Key('search'),
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search),
                hintText: tr(context, 'Search or scan'),
                border: const OutlineInputBorder(),
                isDense: true,
              ),
              onChanged: (v) => setState(() => _search = v),
            ),
          ),
          SizedBox(height: 44, child: _categoryStrip()),
          Expanded(
            child: products.isEmpty
                ? Center(child: Text(tr(context, 'No products')))
                : GridView.builder(
                    padding: const EdgeInsets.all(8),
                    // A fixed column count when the manager set a grid density,
                    // otherwise fit tiles by width.
                    gridDelegate: widget.gridColumns > 0
                        ? SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: widget.gridColumns,
                            childAspectRatio: 1.3,
                            mainAxisSpacing: 8,
                            crossAxisSpacing: 8)
                        : const SliverGridDelegateWithMaxCrossAxisExtent(
                            maxCrossAxisExtent: 168,
                            childAspectRatio: 1.05,
                            mainAxisSpacing: 10,
                            crossAxisSpacing: 10),
                    itemCount: products.length,
                    itemBuilder: (_, i) => _ProductTile(
                      product: products[i],
                      price: widget.formatAmount(products[i].price),
                      color: _colorFor(products[i].categoryId),
                      unavailable: widget.unavailableProducts.contains(products[i].id),
                      favourite: widget.favourites.contains(products[i].id),
                      onTap: () => _tapProduct(products[i]),
                      onLongPress: (widget.onToggleAvailable == null && widget.onToggleFavourite == null)
                          ? null
                          : () => _productMenu(products[i]),
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
        if (widget.favourites.isNotEmpty) ...[
          ChoiceChip(
            key: const Key('cat-favourites'),
            avatar: const Icon(Icons.star, size: 16),
            label: Text(tr(context, 'Favourites')),
            selected: _favesOnly,
            onSelected: (_) => setState(() => _favesOnly = !_favesOnly),
          ),
          const SizedBox(width: 6),
        ],
        ChoiceChip(
          label: Text(tr(context, 'All')),
          selected: _categoryId == null && !_favesOnly,
          onSelected: (_) => setState(() {
            _categoryId = null;
            _favesOnly = false;
          }),
        ),
        for (final c in cats) ...[
          const SizedBox(width: 6),
          ChoiceChip(
            label: Text(c.name),
            selected: _categoryId == c.id && !_favesOnly,
            onSelected: (_) => setState(() {
              _categoryId = c.id;
              _favesOnly = false;
            }),
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
                ? Center(child: Text(tr(context, 'Start adding products')))
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
                  label: Text(tr(context, t.label)),
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
        title: Text(o.customerName ?? tr(context, 'Walk-in customer')),
        subtitle: o.customerPhone != null ? Text(o.customerPhone!) : null,
        trailing: TextButton(
          key: const Key('customer'),
          onPressed: o.type == OrderType.delivery ? _deliveryDetails : _openCustomer,
          child: Text(o.customerName == null ? tr(context, 'Add') : tr(context, 'Change')),
        ),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Wrap(spacing: 8, runSpacing: 4, children: [
          if (o.type == OrderType.dineIn) ...[
            ActionChip(
              key: const Key('table'),
              avatar: const Icon(Icons.table_bar, size: 16),
              label: Text(o.tableLabel == null
                  ? tr(context, 'Table')
                  : '${tr(context, 'Table')} ${o.tableLabel}'),
              onPressed: _setTable,
            ),
            ActionChip(
              key: const Key('guests'),
              avatar: const Icon(Icons.groups, size: 16),
              label: Text(o.guestCount == null
                  ? tr(context, 'Guests')
                  : '${o.guestCount} ${tr(context, 'guests')}'),
              onPressed: _setGuests,
            ),
          ],
          if (o.type == OrderType.delivery)
            ActionChip(
              key: const Key('delivery'),
              avatar: const Icon(Icons.delivery_dining, size: 16),
              label: Text(o.deliveryCost > 0
                  ? '${tr(context, 'Delivery')} ${widget.formatAmount(o.deliveryCost)}'
                  : tr(context, 'Delivery details')),
              onPressed: _deliveryDetails,
            ),
          ActionChip(
            key: const Key('order-note'),
            avatar: const Icon(Icons.notes, size: 16),
            label: Text(o.note == null ? tr(context, 'Note') : tr(context, 'Note added')),
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
            // Tax is included in the prices, so it is shown as an "incl." line
            // rather than added on; the total is unchanged.
            if (s.current.taxTotal > 0.001)
              _totalRow('Tax (incl.)', widget.formatAmount(s.current.taxTotal),
                  key: const Key('tax-line'), muted: true),
            Row(children: [
              Text(tr(context, 'TOTAL'), style: const TextStyle(fontWeight: FontWeight.bold)),
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
                      ? tr(context, 'Edit discount')
                      : tr(context, 'Add discount')),
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
        Text(tr(context, label), key: key, style: style),
        const Spacer(),
        Text(amount, style: style),
      ]),
    );
  }

  Widget _actions() => Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        child: Column(children: [
          Row(children: [
            Expanded(
              child: SizedBox(
                height: 52,
                child: OutlinedButton(
                  key: const Key('send-kitchen'),
                  onPressed: (s.hasLines && widget.onSendToKitchen != null)
                      ? _sendToKitchen
                      : null,
                  child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                    const Icon(Icons.soup_kitchen, size: 20),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(tr(context, 'Send to kitchen'),
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                    ),
                  ]),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: SizedBox(
                height: 52,
                child: OutlinedButton(
                  key: const Key('hold'),
                  onPressed: s.hasLines ? _hold : null,
                  child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                    const Icon(Icons.pause_circle_outline, size: 20),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(tr(context, 'Hold'),
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                    ),
                  ]),
                ),
              ),
            ),
          ]),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            height: 68,
            child: FilledButton.icon(
              key: const Key('pay'),
              style: FilledButton.styleFrom(
                textStyle: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
              ),
              onPressed: s.hasLines ? _pay : null,
              icon: const Icon(Icons.payments, size: 26),
              label: Text('${tr(context, 'Pay')}  ${widget.formatAmount(s.total)}'),
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
    this.unavailable = false,
    this.favourite = false,
    this.onLongPress,
  });
  final Product product;
  final String price;
  final VoidCallback onTap;
  final Color? color;
  final bool unavailable;
  final bool favourite;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final tile = Card(
      clipBehavior: Clip.antiAlias,
      // A tinted fill plus a coloured top stripe, so the category reads at a
      // glance without hurting the legibility of the name and price.
      color: unavailable ? Colors.grey.shade300 : color?.withValues(alpha: 0.12),
      child: InkWell(
        key: Key('product-${product.id}'),
        onTap: onTap,
        // Long-press opens the 86 / favourite menu (manager-gated).
        onLongPress: onLongPress,
        child: Stack(
          children: [
            Container(
              decoration: (color == null || unavailable)
                  ? null
                  : BoxDecoration(border: Border(top: BorderSide(color: color!, width: 4))),
              padding: const EdgeInsets.all(10),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(product.name,
                      textAlign: TextAlign.center,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: unavailable
                          ? const TextStyle(
                              color: Colors.black45,
                              fontSize: 15,
                              height: 1.15,
                              decoration: TextDecoration.lineThrough)
                          : const TextStyle(fontSize: 15, height: 1.15, fontWeight: FontWeight.w500)),
                  const SizedBox(height: 8),
                  if (unavailable)
                    Text(tr(context, 'Sold out'),
                        key: Key('soldout-${product.id}'),
                        style: TextStyle(color: Colors.red.shade700, fontWeight: FontWeight.bold, fontSize: 13))
                  else
                    Text(price, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 17)),
                ],
              ),
            ),
            if (favourite)
              const Positioned(
                top: 2,
                right: 2,
                child: Icon(Icons.star, size: 14, color: Colors.amber),
              ),
          ],
        ),
      ),
    );
    return tile;
  }
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
        onTap: onTapLine,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        title: Row(children: [
          Expanded(
              child: Text(line.name, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500))),
          Text(amount, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
        ]),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final m in line.modifiers)
              Text(
                  '   + ${m.name}${m.quantity > 1 ? ' x${m.quantity.toStringAsFixed(0)}' : ''}'
                  '${m.unitPrice == 0 ? '' : '  ${format(m.total * line.quantity)}'}',
                  style: const TextStyle(fontSize: 13, color: Colors.green)),
            if (line.discountPercent > 0)
              Text('   -${line.discountPercent.toStringAsFixed(0)}% ${tr(context, 'discount')}',
                  style: TextStyle(fontSize: 13, color: Colors.orange.shade800)),
            if (line.note != null)
              Text('   ${line.note}',
                  style: const TextStyle(fontSize: 13, fontStyle: FontStyle.italic)),
            Row(children: [
              IconButton(
                  icon: const Icon(Icons.remove_circle_outline, size: 28),
                  onPressed: () => onQty(line.quantity - 1)),
              Container(
                constraints: const BoxConstraints(minWidth: 32),
                alignment: Alignment.center,
                child: Text(
                    line.quantity
                        .toStringAsFixed(line.quantity == line.quantity.roundToDouble() ? 0 : 3),
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              ),
              IconButton(
                  icon: const Icon(Icons.add_circle_outline, size: 28),
                  onPressed: () => onQty(line.quantity + 1)),
            ]),
          ],
        ),
        trailing: IconButton(
            icon: const Icon(Icons.delete_outline, size: 26), onPressed: onRemove),
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
  // The amount for the next split tender; defaults to the whole remaining balance
  // so "part cash, rest card" is two taps, but any partial value can be entered.
  final TextEditingController _tenderAmount = TextEditingController();

  @override
  void initState() {
    super.initState();
    if (_methods.isNotEmpty) _method = _methods.first;
  }

  @override
  void dispose() {
    _received.dispose();
    _tip.dispose();
    _tenderAmount.dispose();
    super.dispose();
  }

  /// Payment methods with duplicate names collapsed, so a shop that has two "Cash"
  /// entries in Odoo does not show two identical Cash buttons at the till.
  List<PaymentMethod> get _methods {
    final seen = <String>{};
    return [
      for (final m in widget.methods)
        if (seen.add(m.name.trim().toLowerCase())) m,
    ];
  }

  // Whether the cashier has typed their own "amount received"; until they do, it
  // tracks the grand total so adding a tip does not leave Charge greyed out.
  bool _receivedEdited = false;

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
    if (_method == null || _remaining <= 0.001) return;
    // Use the typed amount, capped at the remaining balance; an empty field means
    // "the whole rest", so the common case stays one tap.
    final typed = double.tryParse(_tenderAmount.text.trim());
    final amt = (typed == null || typed <= 0)
        ? _remaining
        : (typed > _remaining ? _remaining : typed);
    setState(() {
      _tenders.add(OrderPayment(methodId: _method!.id, amount: amt, label: _method!.name));
      _tenderAmount.clear();
    });
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
              Text(tr(context, 'Payment'),
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              const Spacer(),
              // Split lets one bill be paid part cash, part card, which a single
              // shared-total field cannot express.
              FilterChip(
                key: const Key('split-toggle'),
                label: Text(tr(context, 'Split')),
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
                Text(tr(context, 'Total due')),
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
              decoration: InputDecoration(
                labelText: tr(context, 'Tip (optional)'), border: const OutlineInputBorder(), isDense: true),
              onChanged: (_) => setState(() {
                // Keep the cash received in step with the tip so Charge stays
                // enabled, unless the cashier has already set a received amount.
                if (!_receivedEdited && _isCash && !_split) {
                  _received.text = _grand.toStringAsFixed(2);
                }
              }),
            ),
            const SizedBox(height: 12),
            if (_methods.isNotEmpty)
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  for (final m in _methods)
                    ChoiceChip(
                      key: Key('method-${m.id}'),
                      labelPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      labelStyle: const TextStyle(fontSize: 16),
                      label: Text(m.name),
                      selected: _method?.id == m.id,
                      onSelected: (_) => setState(() => _method = m),
                    ),
                ],
              )
            else
              Text(tr(context, 'Cash'), style: const TextStyle(color: Colors.black54)),
            if (_split) ...[
              const SizedBox(height: 12),
              for (final t in _tenders)
                ListTile(
                  dense: true,
                  title: Text(t.label ?? tr(context, 'Payment')),
                  trailing: Text(widget.format(t.amount)),
                ),
              Text(
                  '${tr(context, 'Remaining')} ${widget.format(_remaining < 0 ? 0 : _remaining)}',
                  key: const Key('remaining'),
                  style: const TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 6),
              Row(children: [
                Expanded(
                  child: TextField(
                    key: const Key('tender-amount'),
                    controller: _tenderAmount,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: InputDecoration(
                      labelText: '${tr(context, 'Amount')} (${_method?.name ?? ''})',
                      hintText: tr(context, 'Rest of balance'),
                      border: const OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton.tonalIcon(
                  key: const Key('add-tender'),
                  onPressed: _remaining > 0.001 ? _addTender : null,
                  icon: const Icon(Icons.add),
                  label: Text(tr(context, 'Add')),
                ),
              ]),
            ] else if (_isCash) ...[
              const SizedBox(height: 16),
              TextField(
                key: const Key('received'),
                controller: _received,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(
                  labelText: tr(context, 'Amount received'),
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
                onChanged: (_) => setState(() => _receivedEdited = true),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  for (final a in _quickAmounts())
                    ActionChip(
                      labelPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      labelStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
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
                Text(tr(context, 'Change')),
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
              height: 64,
              child: FilledButton.icon(
                key: const Key('confirm-payment'),
                style: FilledButton.styleFrom(
                    textStyle: const TextStyle(fontSize: 19, fontWeight: FontWeight.bold)),
                onPressed: _covered ? _confirm : null,
                icon: const Icon(Icons.check_circle, size: 24),
                label: Text('${tr(context, 'Charge')} ${widget.format(_grand)}'),
              ),
            ),
            const SizedBox(height: 4),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(tr(context, 'Cancel')),
            ),
          ],
        ),
      ),
    );
  }
}
