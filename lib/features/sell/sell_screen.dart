import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/pos_session.dart';
import '../../core/auth/permissions.dart';
import '../../core/i18n/l10n.dart';
import '../../core/printing/kitchen_ticket.dart' show KitchenFireResult;
import '../../core/theme/app_colors.dart';
import '../../core/widgets/feedback.dart';
import '../../core/widgets/numeric_keypad.dart';
import '../../domain/catalogue.dart';
import '../../domain/order.dart';
import '../customers/customer_management_screen.dart' show CustomerFormDialog, CustomerFormResult;
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
    this.spooledJobs,
    this.categoryColors = const {},
    this.quickComments = const ['No onions', 'Extra spicy', 'Well done', 'Allergy'],
    this.discountReasons = const [],
    this.discountPercents = const [5, 10, 15, 20],
    this.maxDiscountPercent = 0,
    this.allowAmountDiscount = false,
    this.authorize,
    this.unavailableProducts = const {},
    this.onToggleAvailable,
    this.favourites = const {},
    this.onToggleFavourite,
    this.gridColumns = 0,
    this.extraCustomers,
    this.onAddCustomer,
    this.tables,
    this.heldOrders,
    this.onPickTable,
    this.onNewOrder,
    this.onResendToKitchen,
    this.onPrintBill,
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
  /// so a table's food can be sent without parking the order. Answers with what
  /// became of the ticket, so the cashier is told the truth about it.
  final Future<KitchenFireResult> Function()? onSendToKitchen;

  /// Re-fires every line to the kitchen, even those already sent, for when a ticket
  /// was lost or the kitchen asks for it again. Surfaced on a long-press of Send.
  final Future<KitchenFireResult> Function()? onResendToKitchen;

  /// Prints the check for the open order before it is paid, so a waiter can take the
  /// bill to the table. Paper only: the order is not changed and nothing is settled.
  /// Absent hides the action.
  final void Function(Order order)? onPrintBill;

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

  /// How many print jobs (receipts and kitchen tickets) are held because a printer
  /// would not take them. Shown beside the online badge, since a held ticket is
  /// food that is not being cooked yet.
  final int Function()? spooledJobs;

  /// Category id to colour (ARGB), so the product grid is colour-coded per category
  /// the way Dishflow does. Empty leaves tiles plain.
  final Map<int, int> categoryColors;

  /// Manager-curated quick picks for line notes and discount reasons.
  final List<String> quickComments;
  final List<String> discountReasons;

  /// Configurable discount preset percentages and an optional cap (0 = none).
  final List<double> discountPercents;
  final double maxDiscountPercent;

  /// Whether the discount dialogs offer a money amount beside the percentage. The
  /// amount is converted to the equivalent percentage before it is applied, so the
  /// order, the receipt and every report stay percent-based.
  final bool allowAmountDiscount;

  /// Gate for privileged actions: called with the specific [Permission] the action
  /// needs and returns true if the cashier's role allows it or a manager approves.
  /// When null, actions are not gated.
  final Future<bool> Function(Permission)? authorize;

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

  /// Save a customer captured mid-order and return them, so the picker can attach
  /// someone the till has never seen without leaving the sale. Null hides the
  /// "Add new" action.
  final Customer Function({required String name, String? phone, String? address})?
      onAddCustomer;

  /// The floor's table labels, offered as quick picks when moving items to another
  /// table. Null falls back to free text.
  final List<String> Function()? tables;

  /// The other open (held) orders, for merging another table into this one. Null
  /// disables merge.
  final List<Order> Function()? heldOrders;

  /// Choose a table on the drawn floor plan (with section tabs and occupancy),
  /// returning the chosen name or null if cancelled. When null the screen falls
  /// back to its own flat-grid table sheet. [exclude] hides one table (the source
  /// when moving a bill to another table).
  final Future<String?> Function({String? exclude})? onPickTable;

  /// Show the home floor plan to start the next order (tap a table, or the
  /// takeaway/delivery buttons). Wired by the shell, which owns the floor screen.
  final VoidCallback? onNewOrder;

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

  // Keeps the course-fire countdown badges ticking down while the cart is open.
  Timer? _fireTick;

  @override
  void initState() {
    super.initState();
    widget.catalogueChanged?.addListener(_onCatalogueChanged);
    _fireTick = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted && s.current.lines.any((l) => l.isTimed)) setState(() {});
    });
  }

  @override
  void dispose() {
    widget.catalogueChanged?.removeListener(_onCatalogueChanged);
    _fireTick?.cancel();
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
      showToast(context, '${tr(context, 'No product for barcode')} $code',
          kind: ToastKind.error);
      return;
    }
    _changed(() => s.addProduct(product));
    showToast(context, '${tr(context, 'Added')} ${product.name}',
        kind: ToastKind.success,
        key: const Key('scanned'),
        duration: const Duration(milliseconds: 900));
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
      showToast(context, '${product.name}: ${tr(context, 'sold out')}',
          kind: ToastKind.error);
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
    if (widget.authorize != null && !await widget.authorize!(Permission.priceOverride)) return;
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
    // Every group answers itself from its defaults: ring it straight through. A
    // sheet whose only possible answer is the one already filled in costs the
    // cashier a tap per item and buys nothing.
    if (groups.every((g) => g.resolvesItself)) {
      _changed(() => s.addProduct(product,
          chosen: [
            for (final g in groups)
              for (final m in g.defaults) ChosenModifier(m),
          ]));
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

  Future<double?> _askWeight(Product product) => promptNumber(
        context,
        title: '${tr(context, 'Weight for')} ${product.name}',
        decimal: true,
        confirmLabel: tr(context, 'Add'),
      );

  /// Search the existing customers (Odoo partners + till-local) and return the one
  /// picked, so a sale is attached to a known customer rather than re-typed and
  /// duplicated.
  ///
  /// Returns the [Customer] chosen, the string 'clear' when the cashier says the
  /// sale is a walk-in, or null when the picker was dismissed. Walk-in has to be
  /// distinguishable from cancel: one means "this customer is nobody", the other
  /// means "leave the customer alone".
  Future<Object?> _pickExistingCustomer() async {
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
              if (widget.onAddCustomer != null)
                TextButton(
                  key: const Key('customer-add-new'),
                  onPressed: () async {
                    final created = await _addCustomer();
                    if (created != null && ctx.mounted) Navigator.pop(ctx, created);
                  },
                  child: Text(tr(ctx, 'Add new')),
                ),
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
    return result;
  }

  /// Capture a customer the till has never seen, on the same form the customers
  /// screen uses, and keep them: a regular typed into an order once should be
  /// pickable on the next one. Null if the form was cancelled.
  Future<Customer?> _addCustomer() async {
    final add = widget.onAddCustomer;
    if (add == null) return null;
    final form = await showDialog<CustomerFormResult>(
      context: context,
      builder: (_) => const CustomerFormDialog(),
    );
    if (form == null) return null;
    return add(name: form.name, phone: form.phone, address: form.address);
  }

  /// Attach a customer to the open order, whatever its type: a takeaway regular and
  /// a dine-in table booking are as much a named customer as a delivery is. Walk-in
  /// clears whoever was on it.
  Future<void> _chooseCustomer() async {
    final picked = await _pickExistingCustomer();
    if (picked == null) return;
    _changed(() => s.setCustomer(picked is Customer ? picked : null));
  }

  /// What the cashier typed, as a percentage. In amount mode the money is converted
  /// against [base] (the bill's subtotal, or a line's gross), so only ever a
  /// percentage leaves this screen.
  double _typedPercent(String text, {required bool byAmount, required double base}) {
    final typed = double.tryParse(text.trim()) ?? 0;
    return byAmount ? discountPercentForAmount(typed, base) : typed;
  }

  Future<void> _openDiscount() async {
    // A discount gives away money, so it needs the discount permission.
    if (widget.authorize != null && !await widget.authorize!(Permission.applyDiscount)) return;
    if (!mounted) return;
    final ctrl = TextEditingController(
        text: s.current.discountPercent > 0
            ? s.current.discountPercent.toStringAsFixed(0)
            : '');
    final reasonCtrl = TextEditingController(text: s.current.discountReason ?? '');
    // Percent unless the shop allows money off and the cashier asks for it. The
    // amount becomes its equivalent percentage on apply, so nothing downstream has
    // to learn a second kind of discount.
    var byAmount = false;
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSt) => AlertDialog(
        title: Text(tr(ctx, 'Order discount')),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          if (widget.allowAmountDiscount) ...[
            Wrap(spacing: 8, children: [
              ChoiceChip(
                key: const Key('discount-mode-percent'),
                label: const Text('%'),
                selected: !byAmount,
                onSelected: (_) => setSt(() {
                  byAmount = false;
                  ctrl.clear();
                }),
              ),
              ChoiceChip(
                key: const Key('discount-mode-amount'),
                label: Text(tr(ctx, 'Amount')),
                selected: byAmount,
                onSelected: (_) => setSt(() {
                  byAmount = true;
                  ctrl.clear();
                }),
              ),
            ]),
            const SizedBox(height: 8),
          ],
          TextField(
            key: const Key('discount-value'),
            controller: ctrl,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
                labelText: tr(ctx, byAmount ? 'Amount off' : 'Discount'),
                suffixText: byAmount ? null : '%',
                border: const OutlineInputBorder()),
          ),
          const SizedBox(height: 8),
          // Quick-pick chips from the manager-configured presets, plus a 0 to clear.
          // Percentages only: a preset is a percentage, and offering it while the
          // field is money would read as an amount.
          if (!byAmount)
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
              'pct': _typedPercent(ctrl.text, byAmount: byAmount, base: s.current.subtotal),
              'reason': reasonCtrl.text.trim(),
            }),
            child: Text(tr(ctx, 'Apply')),
          ),
        ],
        ),
      ),
    );
    if (result != null) {
      var pct = result['pct'] as double;
      // Enforce the configured cap so a mis-typed 100% off cannot go through.
      if (widget.maxDiscountPercent > 0 && pct > widget.maxDiscountPercent) {
        pct = widget.maxDiscountPercent;
        if (mounted) {
          showToast(
              context,
              '${tr(context, 'Capped at')} ${widget.maxDiscountPercent.toStringAsFixed(0)}%',
              kind: ToastKind.info);
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
          if (s.current.type == OrderType.dineIn)
            ListTile(
              key: const Key('line-seat'),
              leading: const Icon(Icons.person_pin_circle_outlined),
              title: Text(tr(ctx, 'Assign to guest')),
              subtitle: line.seat != null
                  ? Text('${tr(ctx, 'Guest')} ${line.seat}')
                  : null,
              onTap: () => Navigator.pop(ctx, 'seat'),
            ),
          if (line.quantity > 1 && line.quantity == line.quantity.roundToDouble())
            ListTile(
              key: const Key('line-split-units'),
              leading: const Icon(Icons.splitscreen_outlined),
              title: Text(tr(ctx, 'Split into single items')),
              subtitle: Text(tr(ctx, 'So you can change one on its own')),
              onTap: () => Navigator.pop(ctx, 'split-units'),
            ),
          if (!line.printedToKitchen)
            ListTile(
              key: const Key('line-timer'),
              leading: const Icon(Icons.timer_outlined),
              title: Text(tr(ctx, 'Fire timing')),
              subtitle: line.fireAt != null
                  ? Text('${tr(ctx, 'Fires in')} ${_minsUntil(line.fireAt!)}')
                  : Text(tr(ctx, 'Send to the kitchen after a delay')),
              onTap: () => Navigator.pop(ctx, 'timer'),
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
    if (action == 'seat') await _assignSeat(line);
    if (action == 'split-units') _changed(() => s.splitLineToUnits(line.uuid));
    if (action == 'timer') await _setFireTiming(lineUuid: line.uuid);
    if (action == 'void') await _voidLine(line);
  }

  /// Minutes from now until [at], as a short "14m" / "now" label.
  static String _minsUntil(DateTime at) {
    final m = at.toUtc().difference(DateTime.now().toUtc()).inMinutes;
    return m <= 0 ? 'now' : '${m}m';
  }

  /// Choose a fire delay for one line (lineUuid) or, when lineUuid is null, the
  /// whole order. Course firing: the chosen items hold back and auto-fire when the
  /// timer elapses.
  Future<void> _setFireTiming({String? lineUuid}) async {
    final choice = await showModalBottomSheet<int>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
                lineUuid == null
                    ? tr(ctx, 'Fire the whole order after')
                    : tr(ctx, 'Fire this item after'),
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            alignment: WrapAlignment.center,
            children: [
              for (final m in const [0, 5, 10, 15, 20, 30, 45])
                ChoiceChip(
                  key: Key('fire-in-$m'),
                  label: Text(m == 0 ? tr(ctx, 'Send now') : '$m ${tr(ctx, 'min')}'),
                  selected: false,
                  onSelected: (_) => Navigator.pop(ctx, m),
                ),
            ],
          ),
          const SizedBox(height: 16),
        ]),
      ),
    );
    if (choice == null) return;
    _changed(() {
      if (lineUuid == null) {
        s.setOrderFireDelay(choice);
      } else {
        s.setLineFireDelay(lineUuid, choice);
      }
    });
  }

  /// Ask which guest a line belongs to (0/blank clears it), for splitting the bill
  /// by cover later. A number pad, because seats are 1..N.
  Future<void> _assignSeat(OrderLine line) async {
    final ctrl = TextEditingController(text: line.seat?.toString() ?? '');
    final seat = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr(ctx, 'Assign to guest')),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(
              labelText: tr(ctx, 'Guest number'), border: const OutlineInputBorder()),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, 0),
              child: Text(tr(ctx, 'Clear'))),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, int.tryParse(ctrl.text.trim()) ?? 0),
              child: Text(tr(ctx, 'Set'))),
        ],
      ),
    );
    if (seat == null || !mounted) return;
    _changed(() => s.setLineSeat(line.uuid, seat > 0 ? seat : null));
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
    // the same permission gate and the same cap and presets.
    if (widget.authorize != null && !await widget.authorize!(Permission.applyDiscount)) return;
    if (!mounted) return;
    final ctrl = TextEditingController(
        text: line.discountPercent > 0 ? line.discountPercent.toStringAsFixed(0) : '');
    var byAmount = false;
    final pct = await showDialog<double>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSt) => AlertDialog(
        title: Text('${tr(ctx, 'Discount')} ${line.name}'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          if (widget.allowAmountDiscount) ...[
            Wrap(spacing: 8, children: [
              ChoiceChip(
                key: const Key('line-discount-mode-percent'),
                label: const Text('%'),
                selected: !byAmount,
                onSelected: (_) => setSt(() {
                  byAmount = false;
                  ctrl.clear();
                }),
              ),
              ChoiceChip(
                key: const Key('line-discount-mode-amount'),
                label: Text(tr(ctx, 'Amount')),
                selected: byAmount,
                onSelected: (_) => setSt(() {
                  byAmount = true;
                  ctrl.clear();
                }),
              ),
            ]),
            const SizedBox(height: 8),
          ],
          TextField(
            key: const Key('line-discount-value'),
            controller: ctrl,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
                labelText: tr(ctx, byAmount ? 'Amount off' : 'Line discount'),
                suffixText: byAmount ? null : '%',
                border: const OutlineInputBorder()),
          ),
          const SizedBox(height: 8),
          if (!byAmount)
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
              // A line's own gross is what its discount is taken off, so that is the
              // base a typed amount converts against.
              onPressed: () => Navigator.pop(
                  ctx, _typedPercent(ctrl.text, byAmount: byAmount, base: line.gross)),
              child: Text(tr(ctx, 'Apply'))),
        ],
        ),
      ),
    );
    if (pct == null) return;
    var applied = pct;
    if (widget.maxDiscountPercent > 0 && applied > widget.maxDiscountPercent) {
      applied = widget.maxDiscountPercent;
      if (mounted) {
        showToast(
            context,
            '${tr(context, 'Capped at')} ${widget.maxDiscountPercent.toStringAsFixed(0)}%',
            kind: ToastKind.info);
      }
    }
    _changed(() => s.setLineDiscount(line.uuid, applied));
  }

  Future<void> _voidLine(OrderLine line) async {
    // Voiding a line is a privileged action, so it needs the void permission first.
    if (widget.authorize != null && !await widget.authorize!(Permission.voidLine)) return;
    if (!mounted) return;
    final reason = await _askReason('Void ${line.name}');
    if (reason == null) return;
    _changed(() {
      s.voidLine(line.uuid, reason);
    });
    // Every void is reported so the shell can print the till's deletion slip; the
    // shell decides separately whether the line also needs a kitchen cancel slip
    // (only when the kitchen already has a copy).
    widget.onLineVoided?.call(line, reason);
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
    // A non-null result (including an empty string from Other / custom) is applied,
    // so clearing the text removes a mistakenly assigned table.
    final label = await _pickTable();
    if (label == null) return;
    // Do not seat this order on a table another open tab already holds, or two bills
    // collide on one table and the floor can only recall one of them. Sending the
    // cashier to recall the existing tab is the safe path.
    if (label.isNotEmpty && label != s.current.tableLabel) {
      final taken = (widget.heldOrders?.call() ?? const <Order>[])
          .any((o) => o.tableLabel == label && o.lines.isNotEmpty);
      if (taken) {
        if (mounted) {
          showToast(context, tr(context, 'Table is occupied. Recall it from the floor.'),
              kind: ToastKind.error);
        }
        return;
      }
    }
    _changed(() => s.setTable(label));
  }

  /// A visual floor picker: every table as a tile coloured by occupancy (this
  /// order's table, an occupied tab, or free), with the running total on the busy
  /// ones. Falls back to free-text for a table that is not on the floor yet.
  /// [exclude] hides one label (used when moving items, to hide the source table).
  Future<String?> _pickTable({String? exclude}) async {
    // Prefer the real floor plan (spatial layout + section tabs) when the shell
    // wires it; the flat-grid sheet below is the fallback for tests or a host that
    // has no floor store.
    if (widget.onPickTable != null) return widget.onPickTable!(exclude: exclude);
    final tables =
        (widget.tables?.call() ?? const <String>[]).where((t) => t != exclude).toList();
    final held = <String, Order>{
      for (final o in (widget.heldOrders?.call() ?? const <Order>[]))
        if (o.tableLabel != null && o.lines.isNotEmpty) o.tableLabel!: o,
    };
    final current = s.current.tableLabel;
    return showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        maxChildSize: 0.9,
        builder: (ctx, scroll) => Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(children: [
            Row(children: [
              Text(tr(ctx, 'Choose a table'),
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              const Spacer(),
              _legendDot(AppColors.tableFree, tr(ctx, 'Free')),
              const SizedBox(width: 10),
              _legendDot(AppColors.tableOccupied, tr(ctx, 'Occupied')),
            ]),
            const SizedBox(height: 10),
            Expanded(
              child: tables.isEmpty
                  ? Center(child: Text(tr(ctx, 'No tables yet. Add them in Settings.')))
                  : GridView.count(
                      controller: scroll,
                      crossAxisCount: 4,
                      childAspectRatio: 1.1,
                      mainAxisSpacing: 10,
                      crossAxisSpacing: 10,
                      children: [
                        for (final t in tables)
                          _TablePickTile(
                            label: t,
                            isCurrent: t == current,
                            occupiedTotal: held[t]?.total,
                            formatAmount: widget.formatAmount,
                            onTap: () => Navigator.pop(ctx, t),
                          ),
                      ],
                    ),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              key: const Key('table-custom'),
              icon: const Icon(Icons.edit),
              label: Text(tr(ctx, 'Other / custom')),
              onPressed: () async {
                // Empty is allowed through so it can clear a table; the move flow
                // ignores an empty destination itself.
                final custom = await _promptCustomTable();
                if (ctx.mounted && custom != null) Navigator.pop(ctx, custom);
              },
            ),
          ]),
        ),
      ),
    );
  }

  Widget _legendDot(Color c, String label) => Row(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 10, height: 10, decoration: BoxDecoration(color: c, shape: BoxShape.circle)),
        const SizedBox(width: 4),
        Text(label, style: const TextStyle(fontSize: 12)),
      ]);

  Future<String?> _promptCustomTable() {
    final ctrl = TextEditingController(text: s.current.tableLabel ?? '');
    return showDialog<String>(
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
  }

  Future<void> _deliveryDetails() async {
    final name = TextEditingController(text: s.current.customerName ?? '');
    final phone = TextEditingController(text: s.current.customerPhone ?? '');
    final addr = TextEditingController(text: s.current.customerAddress ?? '');
    final cost = TextEditingController(
        text: s.current.deliveryCost > 0 ? s.current.deliveryCost.toStringAsFixed(2) : '');
    // The existing customer picked, so the delivery links to that partner rather
    // than being saved as a free-typed name (which would duplicate them in Odoo).
    Customer? picked;
    // Set when the cashier said walk-in, so saving drops the partner that was on
    // the order instead of keeping a link the dialog no longer shows.
    var cleared = false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSt) => AlertDialog(
        title: Text(tr(ctx, 'Delivery details')),
        content: SizedBox(
          width: 360,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            // Check for an existing customer before typing a new one, so a regular
            // is not duplicated on every order.
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                key: const Key('delivery-find-existing'),
                icon: const Icon(Icons.person_search),
                label: Text(tr(ctx, 'Find existing customer')),
                onPressed: () async {
                  final result = await _pickExistingCustomer();
                  if (result == null) return;
                  // Walk-in on a delivery means "this is nobody I have on file":
                  // drop the partner link and the details typed against it, rather
                  // than leaving a stale customer attached to the address.
                  if (result is! Customer) {
                    picked = null;
                    cleared = true;
                    setSt(() {
                      name.clear();
                      phone.clear();
                    });
                    return;
                  }
                  picked = result;
                  cleared = false;
                  setSt(() {
                    name.text = result.name;
                    if (result.phone != null) phone.text = result.phone!;
                  });
                },
              ),
            ),
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
      ),
    );
    if (ok == true) {
      _changed(() {
        // Link the chosen partner first (sets partnerId), then overlay the typed
        // name/phone/address; the partner id survives so the sale is not a duplicate.
        if (picked != null) {
          s.setCustomer(picked);
        } else if (cleared) {
          s.setCustomer(null);
        }
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
      showToast(context, tr(context, 'Order parked. Recall it from Open orders.'),
          kind: ToastKind.success,
          key: const Key('held'),
          duration: const Duration(seconds: 2));
    }
  }

  void _newOrder() {
    // Do not reset here: the floor home starts the next order (via startFresh) when
    // a table or the takeaway/delivery button is chosen, so backing out of the floor
    // leaves the current order untouched and no empty draft is created.
    if (widget.onNewOrder != null) {
      widget.onNewOrder!();
    } else {
      _changed(() => s.newOrder());
    }
  }

  Future<void> _sendToKitchen() async {
    if (!s.hasLines) return;
    final fire = widget.onSendToKitchen;
    if (fire == null) return;
    // Nothing on screen is blocked while the printer is tried: the order is already
    // saved and the cashier can keep ringing. What waits is only the message, because
    // "Sent to kitchen" before the printer has answered is the lie this fixes.
    final result = await fire();
    if (!mounted) return;
    setState(() {});
    _tellKitchenOutcome(result, key: const Key('sent-kitchen'));
  }

  /// Say what actually happened to the ticket. Green only when a printer took it;
  /// amber when it is held and will print itself; red when the kitchen has nothing
  /// and someone has to walk the order over.
  void _tellKitchenOutcome(KitchenFireResult result, {required Key key}) {
    final (message, kind) = switch (result) {
      KitchenFireResult.sent => (tr(context, 'Sent to kitchen.'), ToastKind.success),
      KitchenFireResult.spooled => (
          tr(context, 'Ticket held, printer offline. It will print automatically.'),
          ToastKind.warning
        ),
      KitchenFireResult.lost => (
          tr(context, 'Ticket did not print. Tell the kitchen and try again.'),
          ToastKind.error
        ),
    };
    showToast(context, message,
        kind: kind,
        key: key,
        duration: Duration(seconds: result == KitchenFireResult.sent ? 2 : 4));
  }

  Future<void> _resendToKitchen() async {
    if (!s.hasLines) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr(ctx, 'Resend to kitchen')),
        content: Text(tr(ctx, 'Print the whole ticket again?')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr(ctx, 'Cancel'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr(ctx, 'Resend'))),
        ],
      ),
    );
    if (ok != true) return;
    final resend = widget.onResendToKitchen;
    if (resend == null) return;
    final result = await resend();
    if (!mounted) return;
    _tellKitchenOutcome(result, key: const Key('resent-kitchen'));
  }

  void _pay() {
    if (!s.hasLines) return;
    // If shares were already taken (even split), the main Pay settles what is left,
    // not the whole total again.
    final partPaid = s.current.amountPaid > 0.001;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => _PaymentSheet(
        total: partPaid ? s.current.balance : s.total,
        format: widget.formatAmount,
        methods: s.catalogue.paymentMethods(),
        onConfirm: (payments, label, tip, cashReceived) {
          Navigator.pop(ctx);
          if (partPaid) {
            _completeShare(payments, label, tip, cashReceived);
          } else {
            _complete(payments, label, tip, cashReceived);
          }
        },
      ),
    );
  }

  /// Settle a part payment / even-split share against the open balance. Closes the
  /// table and prints once the balance reaches zero; otherwise keeps it open.
  void _completeShare(
      List<OrderPayment> payments, String label, double tip, double? cashReceived) {
    final settling = s.current; // finalized in place if this share settles it
    final balance = s.payShare(payments: payments, cashReceived: cashReceived, tip: tip);
    setState(() {});
    if (balance <= 0.001) {
      widget.onPaid?.call(settling);
      if (!mounted) return;
      showToast(context, tr(context, 'Table closed.'),
          kind: ToastKind.success, key: const Key('share-settled'));
    } else if (mounted) {
      showToast(
          context,
          '${tr(context, 'Paid')} ${widget.formatAmount(settling.amountPaid)}, '
              '${tr(context, 'balance')} ${widget.formatAmount(balance)}',
          kind: ToastKind.info,
          key: const Key('share-paid'),
          duration: const Duration(seconds: 3));
    }
  }

  void _complete(
      List<OrderPayment> payments, String label, double tip, double? cashReceived) {
    if (tip > 0) s.setTip(tip);
    final order = s.pay(payments: payments, cashReceived: cashReceived);
    setState(() {});
    widget.onPaid?.call(order);
    if (!mounted) return;
    // The sale is saved on this till now; it is sent to Odoo with the rest of the
    // shift's orders at close, so the message does not promise an instant sync.
    showToast(
        context,
        'Sale complete: ${widget.formatAmount(order.total)} ($label). '
            'Saved on this till.',
        kind: ToastKind.success,
        key: const Key('sale-complete'),
        duration: const Duration(seconds: 3));
  }

  // ── dine-in bill: split by guest, pay selected, move, merge ──────

  /// The charge for a subset of the current order's lines, with the whole-order
  /// discount applied (it is a percentage, so it applies to each check's lines).
  double _linesTotal(Iterable<OrderLine> lines) =>
      lines.fold(0.0, (a, l) => a + l.total) * s.current.discountFactor;

  /// Take payment for a subset of the current order as its own check, leaving the
  /// rest of the table open. Reuses the payment sheet and the normal post-payment
  /// path (kitchen fire for any un-fired lines, receipt print).
  void _payLines(List<OrderLine> lines, {String? label}) {
    if (lines.isEmpty) return;
    final ids = lines.map((l) => l.uuid).toList();
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => _PaymentSheet(
        total: _linesTotal(lines),
        format: widget.formatAmount,
        methods: s.catalogue.paymentMethods(),
        onConfirm: (payments, payLabel, tip, cashReceived) {
          Navigator.pop(ctx);
          final check = s.payCheck(ids,
              payments: payments, cashReceived: cashReceived, tip: tip);
          setState(() {});
          widget.onPaid?.call(check);
          if (!mounted) return;
          showToast(
              context,
              '${label ?? tr(context, 'Check')}: '
                  '${widget.formatAmount(check.total)} ($payLabel). '
                  '${s.hasLines ? tr(context, 'Rest of the table stays open.') : tr(context, 'Table closed.')}',
              kind: ToastKind.success,
              key: const Key('check-complete'),
              duration: const Duration(seconds: 3));
        },
      ),
    );
  }

  /// Pay a picks selection as its own check. The chosen quantities are peeled only
  /// inside the payment confirmation, so cancelling the payment sheet leaves the
  /// bill whole (no orphan split lines).
  void _payPicks(Map<String, int> picks, {String? label}) {
    if (picks.isEmpty) return;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => _PaymentSheet(
        total: _picksTotal(picks),
        format: widget.formatAmount,
        methods: s.catalogue.paymentMethods(),
        onConfirm: (payments, payLabel, tip, cashReceived) {
          Navigator.pop(ctx);
          final ids = _peelPicks(picks).map((l) => l.uuid).toList();
          if (ids.isEmpty) return;
          final check = s.payCheck(ids,
              payments: payments, cashReceived: cashReceived, tip: tip);
          setState(() {});
          widget.onPaid?.call(check);
          if (!mounted) return;
          showToast(
              context,
              '${label ?? tr(context, 'Check')}: '
                  '${widget.formatAmount(check.total)} ($payLabel). '
                  '${s.hasLines ? tr(context, 'Rest of the table stays open.') : tr(context, 'Table closed.')}',
              kind: ToastKind.success,
              key: const Key('check-complete'),
              duration: const Duration(seconds: 3));
        },
      ),
    );
  }

  /// The table asked for the bill. Hands the current order to the shell to print and
  /// changes nothing: no state, no lines, no tender, so it can be tapped as often as
  /// the table asks. The shell spools the slip, so a dead printer does not fail the
  /// tap and the toast stays honest about what happened.
  void _printBill() {
    widget.onPrintBill?.call(s.current);
    showToast(context, tr(context, 'Bill sent to the printer'),
        kind: ToastKind.success, key: const Key('bill-printed'));
  }

  /// The dine-in bill menu: split by guest, pay selected items, move items to
  /// another table, or merge another table in. Mirrors a table-service till.
  Future<void> _billOptions() async {
    final action = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        // Scrollable so the menu never overflows a short sheet as options grow.
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
          if (widget.onPrintBill != null)
            ListTile(
              key: const Key('bill-print'),
              leading: const Icon(Icons.receipt_long_outlined),
              title: Text(tr(ctx, 'Print bill')),
              subtitle: Text(tr(ctx, 'The check to take to the table, before payment')),
              onTap: () => Navigator.pop(ctx, 'print'),
            ),
          ListTile(
            key: const Key('bill-split-even'),
            leading: const Icon(Icons.safety_divider),
            title: Text(tr(ctx, 'Split evenly')),
            subtitle: Text(tr(ctx, 'Divide the bill into equal shares')),
            onTap: () => Navigator.pop(ctx, 'even'),
          ),
          ListTile(
            key: const Key('bill-split-guest'),
            leading: const Icon(Icons.groups_2_outlined),
            title: Text(tr(ctx, 'Split by guest')),
            subtitle: Text(tr(ctx, 'Pay each guest separately')),
            onTap: () => Navigator.pop(ctx, 'guest'),
          ),
          ListTile(
            key: const Key('bill-pay-selected'),
            leading: const Icon(Icons.checklist),
            title: Text(tr(ctx, 'Pay selected items')),
            onTap: () => Navigator.pop(ctx, 'selected'),
          ),
          ListTile(
            key: const Key('bill-move'),
            leading: const Icon(Icons.drive_file_move_outline),
            title: Text(tr(ctx, 'Move items to another table')),
            onTap: () => Navigator.pop(ctx, 'move'),
          ),
          ListTile(
            key: const Key('bill-merge'),
            leading: const Icon(Icons.merge_type),
            title: Text(tr(ctx, 'Merge another table in')),
            onTap: () => Navigator.pop(ctx, 'merge'),
          ),
          ListTile(
            key: const Key('bill-timing'),
            leading: const Icon(Icons.timer_outlined),
            title: Text(tr(ctx, 'Course timing (whole order)')),
            subtitle: Text(tr(ctx, 'Hold the order back a set time before the kitchen')),
            onTap: () => Navigator.pop(ctx, 'timing'),
          ),
        ]),
        ),
      ),
    );
    if (!mounted) return;
    switch (action) {
      case 'print':
        _printBill();
      case 'timing':
        await _setFireTiming();
      case 'even':
        await _splitEvenly();
      case 'guest':
        await _splitByGuest();
      case 'selected':
        await _pickLines(
            title: tr(context, 'Pay selected items'),
            confirmLabel: tr(context, 'Pay'),
            onConfirm: (picks) => _payPicks(picks, label: tr(context, 'Check')));
      case 'move':
        await _moveItems();
      case 'merge':
        await _mergeTable();
    }
  }

  /// Even split: ask how many ways, then take one equal share now. The table stays
  /// open on a running balance until every share is paid, so shares can be settled
  /// one at a time. The last share is whatever balance remains, so rounding never
  /// leaves a stray cent.
  Future<void> _splitEvenly() async {
    final ways = await _askShareCount();
    if (ways == null || ways < 2 || !mounted) return;
    final share = s.current.total / ways;
    final due = share < s.current.balance ? share : s.current.balance;
    _payShareSheet(due);
  }

  Future<int?> _askShareCount() {
    final ctrl = TextEditingController(text: '${s.current.guestCount ?? 2}');
    return showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr(ctx, 'Split into how many?')),
        content: TextField(
          key: const Key('split-ways'),
          controller: ctrl,
          autofocus: true,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(
              labelText: tr(ctx, 'Number of shares'), border: const OutlineInputBorder()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr(ctx, 'Cancel'))),
          FilledButton(
            key: const Key('split-ways-ok'),
            onPressed: () => Navigator.pop(ctx, int.tryParse(ctrl.text.trim())),
            child: Text(tr(ctx, 'Next')),
          ),
        ],
      ),
    );
  }

  /// Take one share/part payment against the open balance via the payment sheet.
  void _payShareSheet(double amount) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => _PaymentSheet(
        total: amount,
        format: widget.formatAmount,
        methods: s.catalogue.paymentMethods(),
        onConfirm: (payments, label, tip, cashReceived) {
          Navigator.pop(ctx);
          _completeShare(payments, label, tip, cashReceived);
        },
      ),
    );
  }

  /// One row per guest with its subtotal and a Pay button; unassigned lines are a
  /// "Shared" group paid together. Paying a guest carves their check off the table.
  Future<void> _splitByGuest() async {
    Map<int?, List<OrderLine>> byGuest() {
      final map = <int?, List<OrderLine>>{};
      for (final l in s.current.lines) {
        map.putIfAbsent(l.seat, () => []).add(l);
      }
      return map;
    }

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setSheet) {
        final groups = byGuest();
        final seats = groups.keys.toList()
          ..sort((a, b) => (a ?? 1 << 30).compareTo(b ?? 1 << 30));
        if (s.current.lines.isEmpty) {
          // Table cleared while splitting: close the sheet.
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (Navigator.of(ctx).canPop()) Navigator.pop(ctx);
          });
        }
        return Padding(
          padding: const EdgeInsets.all(16),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(tr(ctx, 'Split by guest'),
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            for (final seat in seats)
              ListTile(
                key: Key('guest-${seat ?? 'shared'}'),
                title: Text(seat == null
                    ? tr(ctx, 'Shared')
                    : '${tr(ctx, 'Guest')} $seat'),
                subtitle: Text(groups[seat]!.map((l) => l.name).join(', '),
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                trailing: FilledButton(
                  onPressed: () {
                    Navigator.pop(ctx);
                    _payLines(groups[seat]!,
                        label: seat == null
                            ? tr(context, 'Shared')
                            : '${tr(context, 'Guest')} $seat');
                  },
                  child: Text(widget.formatAmount(_linesTotal(groups[seat]!))),
                ),
              ),
          ]),
        );
      }),
    );
  }

  /// A checklist of the current lines; the callback gets the chosen ones. Shared by
  /// "pay selected" and "move items".
  /// A checklist of the current lines where each selected line's QUANTITY can be
  /// dialled from 1 up to its count (a multi-unit line can be split part-and-part),
  /// then resolved to real lines by peeling the chosen quantities. Shared by
  /// "pay selected items" and "move items". A fractional/weighed line is taken
  /// whole or not at all.
  /// Turn a picks map (line uuid -> units) into real lines by peeling the chosen
  /// quantities. Call this only at the moment the pay/move actually commits, so a
  /// cancelled flow never leaves the bill split.
  List<OrderLine> _peelPicks(Map<String, int> picks) {
    final ids = <String>[];
    picks.forEach((uuid, q) {
      final resolved = s.splitOffQuantity(uuid, q.toDouble());
      if (resolved != null) ids.add(resolved);
    });
    return s.current.lines.where((l) => ids.contains(l.uuid)).toList();
  }

  /// The charge for a picks selection, computed without peeling (per-unit price x
  /// units), so the payment sheet can show a total before anything is committed.
  double _picksTotal(Map<String, int> picks) {
    var sum = 0.0;
    picks.forEach((uuid, q) {
      final i = s.current.lines.indexWhere((l) => l.uuid == uuid);
      if (i < 0) return;
      final l = s.current.lines[i];
      // A weighed/fractional line can only be taken whole (splitOffQuantity refuses
      // to peel it), so charge its full total; a whole-number line charges per unit.
      final whole = l.quantity == l.quantity.roundToDouble();
      sum += whole ? (l.total / l.quantity) * q : l.total;
    });
    return sum * s.current.discountFactor;
  }

  Future<void> _pickLines({
    required String title,
    required String confirmLabel,
    required void Function(Map<String, int> picks) onConfirm,
  }) async {
    // How many units of each line are picked, keyed by uuid; absent/0 means unpicked.
    final picks = <String, int>{};
    bool whole(OrderLine l) => l.quantity == l.quantity.roundToDouble();
    int maxUnits(OrderLine l) => whole(l) ? l.quantity.toInt() : 1;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setSheet) {
        final lines = s.current.lines;
        final pickedCount = picks.values.where((q) => q > 0).length;
        return Padding(
          padding: EdgeInsets.fromLTRB(
              16, 8, 16, 16 + MediaQuery.of(ctx).viewInsets.bottom),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(title,
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final l in lines)
                    _PickLineTile(
                      key: Key('pick-${l.uuid}'),
                      line: l,
                      format: widget.formatAmount,
                      max: maxUnits(l),
                      picked: picks[l.uuid] ?? 0,
                      onChanged: (q) => setSheet(() {
                        if (q <= 0) {
                          picks.remove(l.uuid);
                        } else {
                          picks[l.uuid] = q;
                        }
                      }),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                key: const Key('pick-confirm'),
                onPressed: pickedCount == 0
                    ? null
                    : () {
                        Navigator.pop(ctx);
                        // Hand the selection forward; the actual peel happens only
                        // when the pay/move commits, so a cancelled flow leaves the
                        // bill untouched.
                        onConfirm(Map.of(picks));
                      },
                child: Text('$confirmLabel ($pickedCount)'),
              ),
            ),
          ]),
        );
      }),
    );
  }

  /// Pick lines and a destination table, then move them onto that table's tab.
  Future<void> _moveItems() async {
    await _pickLines(
      title: tr(context, 'Move items to another table'),
      confirmLabel: tr(context, 'Choose table'),
      onConfirm: (picks) async {
        // Choose the destination first; only peel the quantities once a table is
        // actually picked, so backing out of the picker leaves the bill whole.
        final label = await _pickTable(exclude: s.current.tableLabel);
        if (label == null || label.isEmpty || !mounted) return;
        final lines = _peelPicks(picks);
        if (lines.isEmpty) return;
        final ids = lines.map((l) => l.uuid).toSet();
        _changed(() => s.moveLinesToTable(ids, label));
        if (!mounted) return;
        showToast(context, '${lines.length} ${tr(context, 'item(s) moved to table')} $label',
            kind: ToastKind.success);
      },
    );
  }

  /// Pick another open table's order and fold it into this one.
  Future<void> _mergeTable() async {
    final others = (widget.heldOrders?.call() ?? const <Order>[])
        .where((o) => o.uuid != s.current.uuid && o.lines.isNotEmpty)
        .toList();
    if (others.isEmpty) {
      showToast(context, tr(context, 'No other open tables to merge'), kind: ToastKind.error);
      return;
    }
    final uuid = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: ListView(shrinkWrap: true, children: [
          for (final o in others)
            ListTile(
              key: Key('merge-${o.uuid}'),
              leading: const Icon(Icons.table_bar),
              title: Text(o.tableLabel ?? tr(ctx, 'Tab')),
              subtitle: Text('${o.lines.length} ${tr(ctx, 'item(s)')}'),
              trailing: Text(widget.formatAmount(o.total)),
              onTap: () => Navigator.pop(ctx, o.uuid),
            ),
        ]),
      ),
    );
    if (uuid == null) return;
    _changed(() => s.mergeOrderInto(uuid));
    if (!mounted) return;
    showToast(context, tr(context, 'Tables merged'), kind: ToastKind.success);
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
      final held = widget.spooledJobs?.call() ?? 0;
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
            // Paper waiting on a printer, which is a different problem from sales
            // waiting on the server and needs its own badge.
            if (held > 0)
              Padding(
                padding: const EdgeInsets.only(left: 6),
                child: Chip(
                  key: const Key('spool-count'),
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  avatar: Icon(Icons.print_disabled, size: 14, color: AppColors.warning),
                  label: Text('$held ${tr(context, 'to print')}',
                      style: const TextStyle(fontSize: 11)),
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
    // A manager-picked colour wins; otherwise a stable colour from the palette so
    // the grid reads by category instead of as one flat wall of teal.
    return argb != null ? Color(argb) : AppColors.categoryColor(categoryId);
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
                ? EmptyState(
                    icon: Icons.inventory_2_outlined,
                    title: tr(context, 'No products'),
                    message: tr(context, 'Try a different search or category'),
                  )
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
                ? EmptyState(
                    icon: Icons.shopping_cart_outlined,
                    title: tr(context, 'Start adding products'),
                    message: tr(context, 'Tap a product to add it to the order'),
                  )
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
                          onVoid: () => _voidLine(line),
                        ),
                    ],
                  ),
          ),
          const Divider(height: 1),
          // Chrome above the navigator (the shift nudge) takes height off every
          // screen, and a delivery with a customer and a discount is a tall summary.
          // The totals give way and scroll rather than clip: a total a cashier
          // cannot read is worse than one they have to nudge into view. The action
          // buttons below stay put, because a Pay button that scrolls away is not a
          // Pay button.
          Flexible(child: SingleChildScrollView(child: _totals())),
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
      // Delivery gets the full block, because it needs an address and a charge as
      // well as a name; every other type gets the customer chip below.
      if (o.type == OrderType.delivery)
        ListTile(
          dense: true,
          leading: const Icon(Icons.person_pin_circle_outlined),
          title: Text(o.customerName ?? tr(context, 'Delivery customer')),
          subtitle: (o.customerPhone == null && o.customerAddress == null)
              ? null
              : Text([o.customerPhone, o.customerAddress]
                  .whereType<String>()
                  .where((e) => e.isNotEmpty)
                  .join('  ·  ')),
          trailing: TextButton(
            key: const Key('customer'),
            onPressed: _deliveryDetails,
            child: Text(o.customerName == null ? tr(context, 'Add') : tr(context, 'Change')),
          ),
        ),
      // Dine-in starts at the table: if none is chosen, nudge to pick one first.
      if (o.type == OrderType.dineIn && o.tableLabel == null)
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 2),
          child: SizedBox(
            width: double.infinity,
            child: FilledButton.tonalIcon(
              key: const Key('choose-table'),
              icon: const Icon(Icons.table_restaurant),
              label: Text(tr(context, 'Choose a table')),
              onPressed: _setTable,
            ),
          ),
        ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Wrap(spacing: 8, runSpacing: 4, children: [
          // A named customer is not a delivery-only idea: a takeaway regular and a
          // dine-in booking are both worth booking against the partner rather than
          // as an anonymous sale. First in the row, where delivery puts its own
          // customer block, so the till reads the same whatever the order type.
          if (o.type != OrderType.delivery)
            ActionChip(
              key: const Key('customer-chip'),
              avatar: const Icon(Icons.person_outline, size: 16),
              label: Text(o.customerName ?? tr(context, 'Customer')),
              onPressed: _chooseCustomer,
            ),
          if (o.type == OrderType.dineIn) ...[
            if (o.tableLabel != null)
              ActionChip(
                key: const Key('table'),
                avatar: const Icon(Icons.table_bar, size: 16),
                label: Text('${tr(context, 'Table')} ${o.tableLabel}'),
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
            if (s.hasLines)
              ActionChip(
                key: const Key('bill-options'),
                avatar: const Icon(Icons.call_split, size: 16),
                label: Text(tr(context, 'Split / move')),
                onPressed: _billOptions,
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
            // On an even/part-paid open tab, show what has been taken and what is
            // still owed, so the running balance is visible while the table is open.
            if (s.current.amountPaid > 0.001) ...[
              _totalRow('Paid', '-${widget.formatAmount(s.current.amountPaid)}',
                  key: const Key('paid-line'), green: true),
              _totalRow('Balance', widget.formatAmount(s.current.balance),
                  key: const Key('balance-line')),
            ],
            if (s.hasLines)
              Row(children: [
                TextButton.icon(
                  key: const Key('discount'),
                  onPressed: _openDiscount,
                  icon: const Icon(Icons.percent, size: 16),
                  label: Text(s.current.discountPercent > 0
                      ? tr(context, 'Edit discount')
                      : tr(context, 'Add discount')),
                ),
                const Spacer(),
              ]),
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

  Widget _actions() {
    final unsent = s.current.lines.where((l) => !l.printedToKitchen).length;
    final canFire = s.hasLines && widget.onSendToKitchen != null && unsent > 0;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      child: Column(children: [
        Row(children: [
          // Where a waiter looks when the table asks for the bill. It lives with the
          // actions rather than in the summary above, because the summary scrolls
          // when the chrome squeezes it and a bill nobody can reach is not a feature.
          // Nothing to bill on an empty order, so it stays away until there is.
          if (widget.onPrintBill != null && s.hasLines) ...[
            SizedBox(
              height: 52,
              child: OutlinedButton(
                key: const Key('print-bill'),
                onPressed: _printBill,
                child: const Icon(Icons.receipt_long_outlined),
              ),
            ),
            const SizedBox(width: 8),
          ],
          Expanded(
            child: SizedBox(
              height: 52,
              child: OutlinedButton(
                key: const Key('send-kitchen'),
                // Reads its state by colour and count: blue with "(N)" when there is
                // food to fire, muted once everything is already in the kitchen.
                style: OutlinedButton.styleFrom(
                  foregroundColor: canFire ? AppColors.info : Colors.grey,
                  side: BorderSide(
                      color: canFire ? AppColors.info : Colors.grey.shade400),
                ),
                onPressed: canFire ? _sendToKitchen : null,
                // Long-press re-fires the whole ticket (a lost or re-requested KOT).
                onLongPress: (s.hasLines && widget.onResendToKitchen != null)
                    ? _resendToKitchen
                    : null,
                child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  Icon(unsent > 0 ? Icons.soup_kitchen : Icons.check_circle, size: 20),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                        unsent > 0
                            ? '${tr(context, 'Kitchen')} ($unsent)'
                            : tr(context, 'All sent'),
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
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.held,
                  side: BorderSide(color: AppColors.held.withValues(alpha: 0.6)),
                ),
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
              backgroundColor: AppColors.primary,
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

/// One table on the visual picker: coloured by occupancy, with the running total
/// when a tab is open on it.
class _TablePickTile extends StatelessWidget {
  const _TablePickTile({
    required this.label,
    required this.isCurrent,
    required this.occupiedTotal,
    required this.formatAmount,
    required this.onTap,
  });

  final String label;
  final bool isCurrent;
  final double? occupiedTotal;
  final String Function(double) formatAmount;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final occupied = occupiedTotal != null;
    final color = isCurrent
        ? AppColors.tableThis
        : (occupied ? AppColors.tableOccupied : AppColors.tableFree);
    return Material(
      color: color.withValues(alpha: 0.10),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        key: Key('table-tile-${label.toLowerCase()}'),
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: color, width: isCurrent ? 2.5 : 1.5),
          ),
          padding: const EdgeInsets.all(6),
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(Icons.table_restaurant, color: color, size: 22),
            const SizedBox(height: 2),
            Text(label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
            if (occupied)
              Text(formatAmount(occupiedTotal!),
                  style: TextStyle(fontSize: 11, color: color, fontWeight: FontWeight.w600))
            else
              Text(tr(context, isCurrent ? 'This table' : 'Free'),
                  style: TextStyle(fontSize: 11, color: color)),
          ]),
        ),
      ),
    );
  }
}

/// One row in the pick-lines sheet: a line you can include and, when it holds more
/// than one unit, dial how many of its units to take. A single-unit or weighed line
/// is a plain include/exclude.
class _PickLineTile extends StatelessWidget {
  const _PickLineTile({
    super.key,
    required this.line,
    required this.format,
    required this.max,
    required this.picked,
    required this.onChanged,
  });

  final OrderLine line;
  final String Function(double) format;
  final int max;
  final int picked;
  final void Function(int qty) onChanged;

  @override
  Widget build(BuildContext context) {
    final on = picked > 0;
    final perUnit = line.quantity == 0 ? line.total : line.total / line.quantity;
    return ListTile(
      leading: Checkbox(
        value: on,
        onChanged: (v) => onChanged(v == true ? max : 0),
      ),
      title: Text(line.name),
      subtitle: Text(max > 1
          ? '${on ? picked : 0}/$max × ${format(perUnit)}'
          : format(line.total)),
      trailing: (max > 1 && on)
          ? Row(mainAxisSize: MainAxisSize.min, children: [
              IconButton(
                key: Key('pick-minus-${line.uuid}'),
                icon: const Icon(Icons.remove_circle_outline),
                onPressed: picked > 1 ? () => onChanged(picked - 1) : null,
              ),
              Text('$picked', style: const TextStyle(fontWeight: FontWeight.bold)),
              IconButton(
                key: Key('pick-plus-${line.uuid}'),
                icon: const Icon(Icons.add_circle_outline),
                onPressed: picked < max ? () => onChanged(picked + 1) : null,
              ),
            ])
          : null,
    );
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
    required this.onVoid,
  });

  final OrderLine line;
  final String amount;
  final String Function(double) format;
  final VoidCallback onRemove;
  final void Function(double) onQty;
  final VoidCallback onTapLine;

  /// Take a kitchen-fired line off through the void flow (gate, reason, slip,
  /// audit). Used instead of the free trash once the kitchen holds the line.
  final VoidCallback onVoid;

  String get _qtyText =>
      line.quantity.toStringAsFixed(line.quantity == line.quantity.roundToDouble() ? 0 : 3);

  @override
  Widget build(BuildContext context) {
    // A fired line reads green down its edge; a not-yet-sent line reads in the draft
    // colour, so the cashier can see at a glance what the kitchen already has.
    final sent = line.printedToKitchen;
    // Once the kitchen holds any copy of the line, the inline +/- and trash are
    // removed: taking it off must go through the Void action (manager gate, reason,
    // deletion slip, kitchen cancel, audit), never a silent quantity edit.
    final kitchenHasIt = line.printedToKitchen || line.firedStations.isNotEmpty;
    final edge = sent ? AppColors.sent : AppColors.draft;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        border: Border(left: BorderSide(color: edge, width: 4)),
      ),
      child: ListTile(
        // The wash is the tile's own, not a box painted behind it: a ListTile draws
        // its background and its ink on the nearest Material, so a coloured box
        // around it hides the tap ripple, which newer Flutter refuses outright.
        tileColor: sent ? AppColors.sent.withValues(alpha: 0.05) : null,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        onTap: onTapLine,
        contentPadding: const EdgeInsets.fromLTRB(10, 4, 4, 4),
        title: Row(children: [
          if (line.seat != null) ...[
            _tag('G${line.seat}', AppColors.info, key: Key('seat-badge-${line.uuid}')),
            const SizedBox(width: 6),
          ],
          Text('$_qtyText×',
              style: TextStyle(
                  fontSize: 15, fontWeight: FontWeight.w800, color: AppColors.primary)),
          const SizedBox(width: 6),
          Expanded(
              child: Text(line.name,
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600))),
          if (sent) ...[
            StatusChip(tr(context, 'Sent'), AppColors.sent, icon: Icons.check),
            const SizedBox(width: 6),
          ] else if (line.isTimed) ...[
            StatusChip(_fireCountdown(line.fireAt!), AppColors.pending,
                icon: Icons.timer_outlined),
            const SizedBox(width: 6),
          ],
          Text(amount, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
        ]),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final m in line.modifiers)
              Text(
                  '   + ${m.name}${m.quantity > 1 ? ' ×${m.quantity.toStringAsFixed(0)}' : ''}'
                  '${m.unitPrice == 0 ? '  (${tr(context, 'free')})' : '  ${format(m.total * line.quantity)}'}',
                  style: TextStyle(
                      fontSize: 13,
                      color: m.unitPrice == 0 ? AppColors.modifierFree : AppColors.modifierPaid)),
            if (line.discountPercent > 0)
              Text('   -${line.discountPercent.toStringAsFixed(0)}% ${tr(context, 'discount')}',
                  style: const TextStyle(fontSize: 13, color: AppColors.warning)),
            if (line.note != null)
              Text('   ${line.note}',
                  style: const TextStyle(fontSize: 13, fontStyle: FontStyle.italic)),
            if (!kitchenHasIt)
              Row(children: [
                IconButton(
                    icon: const Icon(Icons.remove_circle_outline, size: 28),
                    color: AppColors.error,
                    onPressed: () => onQty(line.quantity - 1)),
                Container(
                  constraints: const BoxConstraints(minWidth: 32),
                  alignment: Alignment.center,
                  child: Text(_qtyText,
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                ),
                IconButton(
                    icon: const Icon(Icons.add_circle_outline, size: 28),
                    color: AppColors.success,
                    onPressed: () => onQty(line.quantity + 1)),
              ]),
          ],
        ),
        // A sent line shows the Void affordance instead of a free trash: removing it
        // is a permissioned, audited, slip-printing action, not a silent delete.
        trailing: kitchenHasIt
            ? IconButton(
                key: Key('line-void-inline-${line.uuid}'),
                icon: const Icon(Icons.remove_circle_outline, size: 26),
                color: AppColors.error,
                tooltip: tr(context, 'Void this line'),
                onPressed: onVoid)
            : IconButton(
                icon: const Icon(Icons.delete_outline, size: 26),
                color: AppColors.error,
                onPressed: onRemove),
      ),
    );
  }

  /// A short "in 14m" / "due" label for a course-timed line.
  static String _fireCountdown(DateTime at) {
    final m = at.toUtc().difference(DateTime.now().toUtc()).inMinutes;
    return m <= 0 ? 'due' : 'in ${m}m';
  }

  Widget _tag(String text, Color color, {Key? key}) => Container(
        key: key,
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: color.withValues(alpha: 0.5)),
        ),
        child: Text(text,
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: color)),
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
  final void Function(
      List<OrderPayment> payments, String label, double tip, double? cashReceived) onConfirm;

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
    double? cashReceived;
    if (_split) {
      // Each tender is already capped at the remaining balance, so a split settles
      // exactly the total with no change to account for.
      payments = List.of(_tenders);
    } else if (_method != null) {
      // Book the amount due, never the note handed over: an overpayment is change,
      // not revenue. The cash tendered is kept only for the receipt's change line.
      payments = [OrderPayment(methodId: _method!.id, amount: _grand, label: _method!.name)];
      if (_isCash && _receivedAmount > _grand + 0.001) cashReceived = _receivedAmount;
    } else {
      payments = <OrderPayment>[];
    }
    widget.onConfirm(payments, label, _tipAmount, cashReceived);
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
