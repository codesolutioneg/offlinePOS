import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/pos_session.dart';
import '../../core/auth/permissions.dart';
import '../../core/db/catalogue_store.dart' show ModifierMark;
import '../../core/db/settings_store.dart';
import '../../core/i18n/l10n.dart';
import '../../core/printing/kitchen_ticket.dart' show KitchenFireResult;
import '../../core/printing/receipt_builder.dart' show PartialPayment;
import '../../core/theme/app_colors.dart';
import '../../core/widgets/feedback.dart';
import '../../core/widgets/numeric_keypad.dart';
import '../../domain/catalogue.dart';
import '../../domain/delivery.dart';
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
    this.pricesAt,
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
    this.productImages = const {},
    this.quickComments = const ['No onions', 'Extra spicy', 'Well done', 'Allergy'],
    this.discountReasons = const [],
    this.discountPercents = const [5, 10, 15, 20],
    this.maxDiscountPercent = 0,
    this.allowAmountDiscount = false,
    this.authorize,
    this.authorizeTabTable,
    this.unavailableProducts = const {},
    this.onToggleAvailable,
    this.favourites = const {},
    this.onToggleFavourite,
    this.gridColumns = 0,
    this.extraCustomers,
    this.onAddCustomer,
    this.searchServerCustomers,
    this.deliveryZones,
    this.deliveryChannels,
    this.drivers,
    this.tables,
    this.heldOrders,
    this.onPickTable,
    this.onNewOrder,
    this.onResendToKitchen,
    this.onPrintBill,
    this.onPartialPayment,
    this.allowedOrderTypes = const {
      OrderType.dineIn,
      OrderType.takeaway,
      OrderType.toGo,
      OrderType.delivery,
    },
    this.payLaterMethodId,
    this.shiftOpen,
    this.onOpenShift,
    this.settings,
  });

  /// Reads which payment methods the shop offers at the till. Null (as in some
  /// tests) offers every method the catalogue carries.
  final SettingsStore? settings;

  final PosSession session;
  final String Function(double) formatAmount;
  final void Function(dynamic order)? onPaid;

  /// Fired whenever the open order gains or loses lines, so anything that needs to
  /// know a customer is mid-order does not have to poll for it.
  final VoidCallback? onChanged;

  /// Ends the shift. Absent, the screen shows no control for it.
  final VoidCallback? onSignOut;

  final Duration? staleness;

  /// When the menu on this till last came down from the server, in UTC. Shown
  /// beside the online badge as a plain fact rather than only as a warning once the
  /// prices are a day old, because "is this the current price?" is a question a
  /// cashier has long before that. Null on a till that has never pulled, which shows
  /// nothing rather than a made-up time.
  final DateTime? pricesAt;

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

  /// A payment that leaves the bill part paid (a share, a guest's check, a selection
  /// of items) was taken. The shell prints its detail slip. Fired after the money is
  /// already booked, so paper never stands between the cashier and the next guest.
  final void Function(PartialPayment payment)? onPartialPayment;

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

  /// Product id to its picture, for the shops that show them. Empty (the default,
  /// and what a shop with the switch off always gets) leaves every tile coloured.
  final Map<int, Uint8List> productImages;

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

  /// Clears the gate to work a parked tab sitting on a table that belongs to another
  /// waiter. Null asks nobody, which is a shop that has assigned no tables and every
  /// host that predates them.
  final Future<bool> Function(Order tab)? authorizeTabTable;

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

  /// Ask the server for customers the till never pulled, for a shop with more
  /// partners than the catalogue carries. Convenience only: it runs while the
  /// cashier types in the picker, its answer is merged in when it arrives, and a
  /// failure or an offline till simply leaves the local results as they are. Never
  /// awaited by anything on the way to a payment.
  final Future<List<Customer>> Function(String query)? searchServerCustomers;

  /// The delivery lists the shop configured: zones with a preset charge, the
  /// channels an order can arrive through, and the drivers who can carry it. Read
  /// through a function so an edit in settings shows on the next dialog. Null or
  /// empty simply leaves those controls off the delivery dialog.
  final List<DeliveryZone> Function()? deliveryZones;
  final List<DeliveryChannel> Function()? deliveryChannels;
  final List<Driver> Function()? drivers;

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

  /// The kinds of sale the signed-in role may open. Everything by default; a shop
  /// that runs a delivery desk or a counter-only till narrows it per role, and the
  /// chips for the rest are simply not offered.
  final Set<OrderType> allowedOrderTypes;

  /// The payment method an on-account ("pay later") sale books against. Null, the
  /// default, means the shop does not run accounts and the payment sheet is
  /// unchanged.
  final int? payLaterMethodId;

  /// Whether a cash-drawer shift is open right now, read on every build. When it
  /// answers false the screen takes no order at all: a sale rung outside a shift
  /// belongs to no drawer and no Z, which is how a day ends up unreconcilable.
  /// Null means the caller does not run shifts and nothing is gated.
  final bool Function()? shiftOpen;

  /// Sends the cashier to the shift screen to open one, from the refusal panel.
  final VoidCallback? onOpenShift;

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

  /// The search box, so a keyboard can jump to it without reaching for the screen.
  final FocusNode _searchFocus = FocusNode();

  PosSession get s => widget.session;

  /// No open shift, so no order may be started. Read fresh every time rather than
  /// cached: the cashier opens the shift on another screen and comes straight back.
  bool get _noShift => widget.shiftOpen != null && !widget.shiftOpen!();

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
    _searchFocus.dispose();
    super.dispose();
  }

  /// Every key the screen sees: the shortcuts a till with a keyboard expects, then
  /// the barcode scanner, which is a keyboard too. Shortcuts are taken first and
  /// swallowed, so a shortcut can never end up half-typed into the scan buffer.
  void _onKey(KeyEvent e) {
    // A scanner is a keyboard, and Pay is a keystroke. With no shift open neither
    // may reach the order: the refusal panel would hide a line the scanner added.
    if (_noShift) return;
    if (e is KeyDownEvent && _shortcut(e)) return;
    _onScanKey(e);
  }

  /// F12 takes the money and Ctrl+K jumps to the search box, which is what the
  /// people who ring hundreds of orders a day use instead of the screen. Returns
  /// whether the key was one of them.
  bool _shortcut(KeyDownEvent e) {
    if (e.logicalKey == LogicalKeyboardKey.f12) {
      // Same door as the Pay button, so nothing about the sale differs: an empty
      // order simply does nothing.
      _pay();
      return true;
    }
    if (e.logicalKey == LogicalKeyboardKey.keyK &&
        HardwareKeyboard.instance.isControlPressed) {
      _searchFocus.requestFocus();
      return true;
    }
    return false;
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
    // 86 and favourites are what this menu changes, so that is the permission it
    // asks for. It used to ask for the price-override grant, which is a different
    // decision entirely and now gates the price itself.
    if (widget.authorize != null &&
        !await widget.authorize!(Permission.itemAvailability)) {
      return;
    }
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
        // The term the last server search was fired for, so a reply that arrives
        // after the cashier has typed on is dropped instead of replacing the list
        // under their finger.
        var searching = '';
        return StatefulBuilder(
          builder: (ctx, setSt) {
            // A shop with more partners than the pull carries can still reach the
            // rest, but only as a bonus on top of the local answer: the list is
            // already filled from disk before this is asked, and an offline till,
            // a slow server or an error simply leaves it as it is.
            void askServer(String term) {
              final search = widget.searchServerCustomers;
              if (search == null) return;
              // Recorded before the length test as well, so a reply to a longer term
              // the cashier has since deleted back to two letters is dropped rather
              // than dressing the list with names that do not match what they typed.
              searching = term;
              if (term.trim().length < 3) return;
              unawaited(search(term).then((found) {
                if (found.isEmpty || searching != term || !ctx.mounted) return;
                final have = results.map((c) => c.id).toSet();
                setSt(() => results = [
                      ...results,
                      ...found.where((c) => have.add(c.id)),
                    ]);
              }).catchError((_) {
                // A search is a convenience. Nothing on this screen depends on it.
              }));
            }

            return AlertDialog(
            title: Text(tr(ctx, 'Customer')),
            content: SizedBox(
              width: 360,
              height: 420,
              child: Column(children: [
                TextField(
                  key: const Key('customer-search'),
                  controller: ctrl,
                  autofocus: true,
                  decoration: InputDecoration(
                    prefixIcon: const Icon(Icons.search),
                    hintText: tr(ctx, 'Search name or phone'),
                    border: const OutlineInputBorder(),
                    isDense: true,
                  ),
                  onChanged: (v) {
                    setSt(() => results = lookup(v));
                    askServer(v);
                  },
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
            );
          },
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
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        // Scrollable so the menu never overflows a short sheet as options grow.
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            key: const Key('line-note'),
            leading: const Icon(Icons.sticky_note_2_outlined),
            title: Text(tr(ctx, 'Note for kitchen')),
            subtitle: line.note != null ? Text(line.note!) : null,
            onTap: () => Navigator.pop(ctx, 'note'),
          ),
          ListTile(
            key: const Key('line-price'),
            leading: const Icon(Icons.sell_outlined),
            title: Text(tr(ctx, 'Change the price')),
            subtitle: Text('${tr(ctx, 'Now')} ${widget.formatAmount(line.unitPrice)}'),
            onTap: () => Navigator.pop(ctx, 'price'),
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
      ),
    );
    if (action == 'note') await _lineNote(line);
    if (action == 'price') await _linePrice(line);
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

  /// Sell this line at another price. Gated, and the session records what it was:
  /// a price typed at the counter has to be as traceable as a discount is.
  Future<void> _linePrice(OrderLine line) async {
    if (widget.authorize != null &&
        !await widget.authorize!(Permission.priceOverride)) {
      return;
    }
    if (!mounted) return;
    final ctrl = TextEditingController(text: line.unitPrice.toStringAsFixed(2));
    final price = await showDialog<double>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('${tr(ctx, 'Price')} ${line.name}'),
        content: TextField(
          key: const Key('line-price-value'),
          controller: ctrl,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(
              labelText: tr(ctx, 'Price for one'),
              helperText: tr(ctx, 'Anything added to the item keeps its own price'),
              border: const OutlineInputBorder()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr(ctx, 'Cancel'))),
          FilledButton(
            key: const Key('apply-line-price'),
            onPressed: () => Navigator.pop(ctx, double.tryParse(ctrl.text.trim())),
            child: Text(tr(ctx, 'Apply')),
          ),
        ],
      ),
    );
    if (price == null || price < 0) return;
    _changed(() => s.setLinePrice(line.uuid, price));
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
    final companyNo =
        TextEditingController(text: s.current.companyOrderNo ?? '');
    final zones = widget.deliveryZones?.call() ?? const <DeliveryZone>[];
    final channels = widget.deliveryChannels?.call() ?? const <DeliveryChannel>[];
    final drivers = widget.drivers?.call() ?? const <Driver>[];
    // Matched by name, which is what the order stores: a channel renamed or deleted
    // in settings leaves the order's own label alone rather than rewriting history.
    final wasOn =
        channels.where((c) => c.name == s.current.deliveryChannel).firstOrNull;
    var channel = wasOn;
    // A driver taken off the roster mid-delivery stays selectable on the order they
    // are already carrying, so saving the dialog cannot quietly drop their name.
    final driverNames = <String>[
      for (final d in drivers) d.name,
      if (s.current.driverName != null &&
          !drivers.any((d) => d.name == s.current.driverName))
        s.current.driverName!,
    ];
    var driver = s.current.driverName;
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
            // Zones price the drive, so the charge is a tap rather than a number
            // remembered per area and typed again on every order. The field below
            // stays editable: a zone is a preset, not a rule.
            if (zones.isNotEmpty) ...[
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: Wrap(spacing: 6, runSpacing: 4, children: [
                  for (final z in zones)
                    ActionChip(
                      key: Key('delivery-zone-${z.id}'),
                      label: Text('${z.name}  ${widget.formatAmount(z.fee)}'),
                      onPressed: () => setSt(
                          () => cost.text = z.fee.toStringAsFixed(2)),
                    ),
                ]),
              ),
            ],
            const SizedBox(height: 8),
            TextField(
                key: const Key('delivery-cost'),
                controller: cost,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(labelText: tr(ctx, 'Delivery charge'), border: const OutlineInputBorder(), isDense: true)),
            // Which app sent the order, and the number that app calls it by, which
            // is what the rider and the call centre quote when they ring.
            if (channels.isNotEmpty) ...[
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: Wrap(spacing: 6, runSpacing: 4, children: [
                  for (final c in channels)
                    ChoiceChip(
                      key: Key('delivery-channel-${c.id}'),
                      label: Text(c.name),
                      selected: channel?.id == c.id,
                      onSelected: (on) =>
                          setSt(() => channel = on ? c : null),
                    ),
                ]),
              ),
              if (channel != null) ...[
                const SizedBox(height: 8),
                TextField(
                    key: const Key('delivery-company-no'),
                    controller: companyNo,
                    decoration: InputDecoration(
                        labelText: tr(ctx, 'Order number at the channel'),
                        border: const OutlineInputBorder(),
                        isDense: true)),
              ],
            ],
            if (driverNames.isNotEmpty) ...[
              const SizedBox(height: 8),
              DropdownButtonFormField<String?>(
                key: const Key('delivery-driver'),
                initialValue: driver,
                isExpanded: true,
                decoration: InputDecoration(
                    labelText: tr(ctx, 'Driver'),
                    border: const OutlineInputBorder(),
                    isDense: true),
                items: [
                  DropdownMenuItem<String?>(
                      value: null, child: Text(tr(ctx, 'No driver yet'))),
                  for (final n in driverNames)
                    DropdownMenuItem<String?>(value: n, child: Text(n)),
                ],
                onChanged: (v) => setSt(() => driver = v),
              ),
            ],
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
        // Last, so an aggregator's own partner wins over whoever was picked above:
        // the company is who the shop invoices, and the typed name stays on the
        // slip as the person the driver is looking for.
        s.setDeliveryChannel(channel,
            companyOrderNo: companyNo.text, previous: wasOn);
        s.setDriver(driver);
      });
    }
  }

  /// Hand the open delivery to a driver without reopening the whole dialog: the
  /// bag is usually assigned when the food is up, not when it is rung.
  Future<void> _chooseDriver() async {
    final drivers = widget.drivers?.call() ?? const <Driver>[];
    final chosen = await showModalBottomSheet<Object?>(
      context: context,
      builder: (ctx) => SafeArea(
        child: ListView(shrinkWrap: true, children: [
          ListTile(
            title: Text(tr(ctx, 'Driver'),
                style: const TextStyle(fontWeight: FontWeight.bold)),
          ),
          if (drivers.isEmpty)
            ListTile(
              key: const Key('no-drivers'),
              title: Text(tr(ctx, 'No drivers yet. Add them in Settings.')),
            ),
          for (final d in drivers)
            ListTile(
              key: Key('driver-${d.id}'),
              leading: const Icon(Icons.delivery_dining),
              title: Text(d.name),
              subtitle: d.phone == null ? null : Text(d.phone!),
              onTap: () => Navigator.pop(ctx, d.name),
            ),
          // Distinguishable from backing out, exactly as walk-in is on the customer
          // picker: one takes the driver off, the other leaves them on.
          ListTile(
            key: const Key('driver-clear'),
            leading: const Icon(Icons.person_off_outlined),
            title: Text(tr(ctx, 'No driver yet')),
            onTap: () => Navigator.pop(ctx, 'clear'),
          ),
        ]),
      ),
    );
    if (chosen == null) return;
    _changed(() => s.setDriver(chosen == 'clear' ? null : chosen as String));
  }

  void _hold() {
    if (!s.hasLines) return;
    widget.onHold?.call();
    setState(() {});
    // With a floor home the shell has already put the cashier on the plan and says
    // it there, above the room. A toast would land at the bottom of that screen, on
    // top of the To go / Takeaway / Delivery row the cashier taps next, so this is
    // only for the till that has no floor to go back to.
    if (mounted && widget.onNewOrder == null) {
      showToast(context, tr(context, 'Order parked. Recall it from Open orders.'),
          kind: ToastKind.success,
          key: const Key('held'),
          duration: const Duration(seconds: 2));
    }
  }

  void _newOrder() {
    // Do not touch the order here: the shell owns what happens to it on the way out
    // (it parks it, so the floor and the open-orders list can both find it again).
    // Without a floor home there is nowhere to go, so the session parks it instead.
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

  /// The tender an on-account sale books against, or null when the shop has not
  /// nominated one (or the catalogue no longer carries it, after a method was
  /// removed in Odoo: the option disappears rather than booking against nothing).
  PaymentMethod? _onAccountMethod() {
    final id = widget.payLaterMethodId;
    if (id == null) return null;
    for (final m in s.catalogue.paymentMethods()) {
      if (m.id == id) return m;
    }
    return null;
  }

  /// The payment methods offered at the till: the catalogue's methods minus any the
  /// shop switched off in Settings. With no settings (as in some tests) every method
  /// is kept, and if a shop turned them all off the sheet still falls back to all of
  /// them rather than showing a payment screen that cannot take money.
  List<PaymentMethod> _offeredMethods() {
    final all = s.catalogue.paymentMethods();
    final settings = widget.settings;
    if (settings == null) return all;
    final offered =
        all.where((m) => settings.isPaymentMethodOffered(m.id)).toList();
    return offered.isEmpty ? all : offered;
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
        billTotal: s.current.total,
        alreadyPaid: s.current.amountPaid,
        format: widget.formatAmount,
        methods: _offeredMethods(),
        // How the bill can be split is asked here, at the top of the payment sheet,
        // because everything about taking money belongs in one place. The split
        // flows themselves are dine-in only, so a counter sale sees a plain tender
        // step with no first step to answer.
        modes: _splitModes(),
        onMode: (mode) {
          Navigator.pop(ctx);
          _startPayMode(mode);
        },
        // Only on the whole bill: a share left on account is a part-paid tab and a
        // receivable at once, which is more bookkeeping than a till should invent.
        onAccountMethod: partPaid ? null : _onAccountMethod(),
        hasCustomer: s.current.partnerId != null ||
            (s.current.customerName ?? '').isNotEmpty,
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

  /// The ways this bill can be split, offered as the payment sheet's first step.
  /// Only a seated table can be split: a counter sale has no guests to divide it
  /// between and no table to leave open on a balance.
  List<_PayMode> _splitModes() => s.current.type == OrderType.dineIn
      ? const [_PayMode.all, _PayMode.evenly, _PayMode.guest, _PayMode.item]
      : const [];

  /// Leave the tender step and start the chosen way of splitting. Each route ends
  /// back in the same payment sheet, at its tender step, for the amount that route
  /// worked out.
  Future<void> _startPayMode(_PayMode mode) async {
    switch (mode) {
      // The sheet the cashier just left already was "all of it", so there is nothing
      // to start; it is in the list to show which step they are on.
      case _PayMode.all:
        return;
      case _PayMode.evenly:
        await _splitEvenly();
      case _PayMode.guest:
        await _splitByGuest();
      case _PayMode.item:
        await _pickLines(
            title: tr(context, 'Pay selected items'),
            confirmLabel: tr(context, 'Pay'),
            onConfirm: (picks) => _payPicks(picks, label: tr(context, 'Check')));
    }
  }

  /// Settle a part payment / even-split share against the open balance. Closes the
  /// table and prints once the balance reaches zero; otherwise keeps it open.
  void _completeShare(
      List<OrderPayment> payments, String label, double tip, double? cashReceived,
      {String? slipTitle}) {
    final settling = s.current; // finalized in place if this share settles it
    final balance = s.payShare(payments: payments, cashReceived: cashReceived, tip: tip);
    final paidNow = payments.fold(0.0, (a, p) => a + p.amount);
    setState(() {});
    if (balance <= 0.001) {
      widget.onPaid?.call(settling);
      if (!mounted) return;
      showToast(context, tr(context, 'Table closed.'),
          kind: ToastKind.success, key: const Key('share-settled'));
    } else {
      // A share that leaves money on the table is the one payment nothing else puts
      // on paper: the sale receipt only prints when the tab settles. Fired after the
      // money is booked, so the slip cannot hold the next guest up.
      widget.onPartialPayment?.call(PartialPayment(
        order: settling,
        paidNow: paidNow,
        stillOwed: balance,
        title: slipTitle ?? tr(context, 'Part payment'),
        tenders: payments,
        cashReceived: cashReceived,
      ));
      if (!mounted) return;
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

  /// The charge for a subset of the current order's lines: the session's own figure,
  /// which is exactly what payCheck books. Deriving it here instead once quoted the
  /// food without the service, and a guest paying their share left the table eating
  /// the difference.
  double _linesTotal(Iterable<OrderLine> lines) => s.checkTotal(lines);

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
        methods: _offeredMethods(),
        // Back steps out of this guest's tender and reopens the guest list, so the
        // cashier can pick another guest without settling this one first.
        onBack: () {
          Navigator.pop(ctx);
          _splitByGuest();
        },
        onConfirm: (payments, payLabel, tip, cashReceived) {
          Navigator.pop(ctx);
          _completeCheck(ids, payments, payLabel, tip, cashReceived, label);
        },
      ),
    );
  }

  /// Book a check (a guest's lines, or a picked selection) and tell the cashier what
  /// happened to the table. The check is a paid sale of its own, so the shell prints
  /// its receipt; the detail slip on top of it is the only paper that states what
  /// the table still owes, so it prints only while something is still owed.
  void _completeCheck(List<String> ids, List<OrderPayment> payments, String payLabel,
      double tip, double? cashReceived, String? label) {
    final check =
        s.payCheck(ids, payments: payments, cashReceived: cashReceived, tip: tip);
    // Read before the rebuild, and only while the table is still open: once the last
    // check is paid the session has moved on to a fresh blank order.
    final owed = s.hasLines ? s.current.balance : 0.0;
    setState(() {});
    widget.onPaid?.call(check);
    if (owed > 0.001) {
      widget.onPartialPayment?.call(PartialPayment(
        order: check,
        paidNow: check.total,
        stillOwed: owed,
        title: label ?? tr(context, 'Check'),
        tenders: check.payments,
        covered: check.lines,
        cashReceived: cashReceived,
        alsoReceipted: true,
      ));
    }
    if (!mounted) return;
    showToast(
        context,
        '${label ?? tr(context, 'Check')}: '
            '${widget.formatAmount(check.total)} ($payLabel). '
            '${s.hasLines ? tr(context, 'Rest of the table stays open.') : tr(context, 'Table closed.')}',
        kind: ToastKind.success,
        key: const Key('check-complete'),
        duration: const Duration(seconds: 3));
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
        methods: _offeredMethods(),
        onConfirm: (payments, payLabel, tip, cashReceived) {
          Navigator.pop(ctx);
          final ids = _peelPicks(picks).map((l) => l.uuid).toList();
          if (ids.isEmpty) return;
          _completeCheck(ids, payments, payLabel, tip, cashReceived, label);
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

  /// The dine-in table menu: print the check, move items to another table, merge
  /// another table in, hold the order back from the kitchen. Everything about taking
  /// money moved to the payment sheet, where a cashier looks for it.
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
            key: const Key('bill-move-order'),
            leading: const Icon(Icons.table_restaurant_outlined),
            title: Text(tr(ctx, 'Move the whole order to another table')),
            onTap: () => Navigator.pop(ctx, 'move-order'),
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
      case 'move-order':
        await _moveWholeOrder();
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
    _payShareSheet(due, slipTitle: '${tr(context, 'Share of')} $ways');
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
  void _payShareSheet(double amount, {String? slipTitle}) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => _PaymentSheet(
        total: amount,
        billTotal: s.current.total,
        alreadyPaid: s.current.amountPaid,
        format: widget.formatAmount,
        methods: _offeredMethods(),
        onConfirm: (payments, label, tip, cashReceived) {
          Navigator.pop(ctx);
          _completeShare(payments, label, tip, cashReceived, slipTitle: slipTitle);
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
    final taken = <OrderLine>[];
    final units = <String, double>{};
    picks.forEach((uuid, q) {
      final i = s.current.lines.indexWhere((l) => l.uuid == uuid);
      if (i < 0) return;
      final l = s.current.lines[i];
      taken.add(l);
      // A weighed/fractional line can only be taken whole (splitOffQuantity refuses
      // to peel it), so charge its full quantity; a whole-number line charges per unit.
      units[l.uuid] =
          l.quantity == l.quantity.roundToDouble() ? q.toDouble() : l.quantity;
    });
    // The bill's own arithmetic: discount, service and tax exactly as payCheck will
    // book them, so the sheet asks for the figure the check is about to be.
    return s.current
        .chargeFor(taken, quantityOf: (l) => units[l.uuid] ?? l.quantity);
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
  /// Move the whole open order to another table in one step. Every line goes, so
  /// the source table is left empty and closed and the destination takes the order
  /// (merged if it already had one). Reuses the same move the item picker commits.
  Future<void> _moveWholeOrder() async {
    if (!s.hasLines) return;
    final label = await _pickTable(exclude: s.current.tableLabel);
    if (label == null || label.isEmpty || !mounted) return;
    final ids = s.current.lines.map((l) => l.uuid).toSet();
    _changed(() => s.moveLinesToTable(ids, label));
    if (!mounted) return;
    showToast(context, '${tr(context, 'Order moved to table')} $label',
        kind: ToastKind.success, key: const Key('order-moved'));
  }

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
    // Merging takes another table's lines and its money onto this bill, so it is as
    // much "opening" that table as tapping its tile is. Without this the floor could
    // refuse a waiter a colleague's table and this sheet would hand it over anyway.
    final source = others.firstWhere((o) => o.uuid == uuid);
    if (!(await widget.authorizeTabTable?.call(source) ?? true)) return;
    if (!mounted) return;
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
          // Recalling a tab or starting a new order is selling, so both go with the
          // grid while the drawer is shut.
          if (widget.onOpenOrders != null && !_noShift)
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
          // The way back to the floor home, where the next order is started. Offered
          // even with no shift open and on an empty order: a cashier who opened the
          // counter by mistake, or who cannot sell yet, must still be able to leave
          // it. Without a floor home this is the plain "park it and start another",
          // which is a no-op on nothing and stays disabled.
          if (widget.onNewOrder != null)
            IconButton(
              key: const Key('new-order'),
              tooltip: tr(context, 'Tables'),
              icon: const Icon(Icons.table_bar),
              onPressed: _newOrder,
            )
          else if (!_noShift)
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
        onKeyEvent: _onKey,
        child: SafeArea(
        child: Column(
          children: [
            if (widget.staleness != null && widget.staleness!.inHours >= 24)
              _StaleBanner(age: widget.staleness!),
            Expanded(
              child: _noShift
                  ? _noShiftGate()
                  : Row(
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

  /// What the till shows instead of the catalogue when no shift is open.
  ///
  /// It replaces the order panel and the grid, not the whole screen: the app bar and
  /// the drawer stay, so reprinting an old receipt, the support screens and the shift
  /// screen itself are all still one tap away. Only ringing up is refused.
  Widget _noShiftGate() => SingleChildScrollView(
        // Scrollable, because a short till in landscape has very little height left
        // under the app bar and the nudge strip.
        padding: const EdgeInsets.all(24),
        child: Center(
          child: Column(
            key: const Key('no-shift-gate'),
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.point_of_sale, size: 56, color: AppColors.error),
              const SizedBox(height: 16),
              Text(
                tr(context, 'No shift is open'),
                style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                tr(context,
                    'Open a shift with a float before you take an order. Reprints and support still work.'),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 20),
              if (widget.onOpenShift != null)
                SizedBox(
                  height: 52,
                  child: FilledButton.icon(
                    key: const Key('no-shift-open-shift'),
                    icon: const Icon(Icons.play_arrow),
                    label: Text(tr(context, 'Open shift')),
                    onPressed: widget.onOpenShift,
                  ),
                ),
              // The way off the till goes with the grid, so it is offered here too:
              // a cashier who is not the one opening the drawer must still be able
              // to hand the till back.
              if (widget.onSignOut != null)
                TextButton.icon(
                  key: const Key('sign-out'),
                  icon: const Icon(Icons.logout),
                  label: Text(tr(context, 'End shift')),
                  onPressed: widget.onSignOut,
                ),
            ],
          ),
        ),
      );

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
            // When the prices on the grid came down. The one fact behind "is this
            // still what Odoo says?", on screen from the first sale rather than as a
            // banner that only appears once the menu is a day old.
            if (widget.pricesAt != null)
              Padding(
                padding: const EdgeInsets.only(left: 6),
                child: Chip(
                  key: const Key('prices-as-of'),
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  avatar: const Icon(Icons.sell_outlined, size: 14),
                  label: Text(
                      '${tr(context, 'Prices')} ${_hhmm(widget.pricesAt!)}',
                      style: const TextStyle(fontSize: 11)),
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

  /// A UTC instant as the local wall clock, which is the only way a cashier reads a
  /// time.
  static String _hhmm(DateTime utc) {
    final at = utc.toLocal();
    return '${at.hour.toString().padLeft(2, '0')}:'
        '${at.minute.toString().padLeft(2, '0')}';
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

  /// A colour set on the item itself beats its category's, so a manager can pull one
  /// dish out of the block its category is drawn in.
  Color? _tileColorFor(Product p) =>
      p.color != null ? Color(p.color!) : _colorFor(p.categoryId);

  Widget _catalogue(List<Product> products) {
    // One grouped read for the whole grid, not one per tile: which items carry
    // choices is a question about the whole menu, and the answer has to be current
    // because a manager can add a group in the editor and come straight back here.
    final marks = s.catalogue.modifierMarks();
    return Column(
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
              focusNode: _searchFocus,
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
                      color: _tileColorFor(products[i]),
                      modifiers: marks[products[i].id],
                      image: widget.productImages[products[i].id],
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
  }

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
          _categoryChip(id: c.id, name: c.name),
        ],
      ],
    );
  }

  /// A category chip in that category's own colour: a dot of it when the chip is
  /// idle, the whole chip filled with it when it is the one being shown. The strip
  /// and the grid then read as one thing, which is the point of colouring either.
  Widget _categoryChip({required int id, required String name}) {
    final selected = _categoryId == id && !_favesOnly;
    final color = _colorFor(id);
    return ChoiceChip(
      key: Key('cat-chip-$id'),
      avatar: color == null || selected
          ? null
          : CircleAvatar(backgroundColor: color, radius: 6),
      label: Text(name),
      selected: selected,
      selectedColor: color?.withValues(alpha: 0.9),
      // White on the shop's colour rather than on the theme's, so a dark chip is
      // still readable whichever colour the manager picked.
      labelStyle: selected && color != null
          ? const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)
          : null,
      showCheckmark: false,
      side: color == null
          ? null
          : BorderSide(color: color.withValues(alpha: selected ? 0.9 : 0.4)),
      onSelected: (_) => setState(() {
        _categoryId = id;
        _favesOnly = false;
      }),
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
          // Scrolls rather than overflows: the chips do not all fit a narrow till
          // panel, and a clipped selector is worse than a scrollable one.
          child: ListView(
            key: const Key('order-type-strip'),
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            children: [
              // Only the types this role rings, plus whatever the order in hand
              // already is: a tab handed over from another till has to stay
              // settleable even when this cashier could not have opened it.
              for (final t in OrderType.values)
                if (widget.allowedOrderTypes.contains(t) || s.current.type == t) ...[
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

  /// The one line under a delivery's name: where it goes, how to ring, and which
  /// channel sent it, which is the block a cashier reads back to a rider.
  String _deliveryLine(Order o) => [
        o.customerPhone,
        o.customerAddress,
        o.deliveryChannel,
        if (o.companyOrderNo != null) '#${o.companyOrderNo}',
      ].whereType<String>().where((e) => e.isNotEmpty).join('  ·  ');

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
          subtitle: _deliveryLine(o).isEmpty ? null : Text(_deliveryLine(o)),
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
          // A to-go can sit at a table while it is packed, so it carries the same
          // table chip. Optional, unlike a dine-in: the chip offers a table rather
          // than nagging for one, and covers and splitting stay with the bills that
          // are actually eaten and shared in the room.
          if (o.type == OrderType.toGo)
            ActionChip(
              key: const Key('table'),
              avatar: const Icon(Icons.table_bar, size: 16),
              label: Text(o.tableLabel == null
                  ? tr(context, 'Table')
                  : '${tr(context, 'Table')} ${o.tableLabel}'),
              onPressed: _setTable,
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
                avatar: const Icon(Icons.drive_file_move_outline, size: 16),
                label: Text(tr(context, 'Move / merge')),
                onPressed: _billOptions,
              ),
          ],
          if (o.type == OrderType.delivery) ...[
            ActionChip(
              key: const Key('delivery'),
              avatar: const Icon(Icons.delivery_dining, size: 16),
              label: Text(o.deliveryCost > 0
                  ? '${tr(context, 'Delivery')} ${widget.formatAmount(o.deliveryCost)}'
                  : tr(context, 'Delivery details')),
              onPressed: _deliveryDetails,
            ),
            // Assigning the bag is its own moment, later than ringing it, so it is
            // one tap from the order rather than buried in the details dialog.
            if (widget.drivers != null)
              ActionChip(
                key: const Key('driver-chip'),
                avatar: const Icon(Icons.two_wheeler, size: 16),
                label: Text(o.driverName ?? tr(context, 'Driver')),
                onPressed: _chooseDriver,
              ),
          ],
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
            // Charged on top of the net prices, so it is a row of the sum the
            // cashier reads out, not a note about what is inside the total.
            if (s.current.taxTotal > 0.001)
              _totalRow('VAT', widget.formatAmount(s.current.taxTotal),
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
    this.image,
    this.modifiers,
    this.unavailable = false,
    this.favourite = false,
    this.onLongPress,
  });
  final Product product;
  final String price;
  final VoidCallback onTap;
  final Color? color;

  /// The choices this item carries, or null when it has none. The shop owner could
  /// not tell which items would ask him something and which would not; this is the
  /// mark that answers it without a tap.
  final ModifierMark? modifiers;

  /// The product's picture, when the shop shows pictures and this product has one.
  /// Null is the normal case and leaves the tile exactly as it has always been.
  final Uint8List? image;
  final bool unavailable;
  final bool favourite;
  final VoidCallback? onLongPress;

  /// A picture is drawn behind the words, so the words are set to stay readable over
  /// whatever the photograph turns out to be: white on a dark wash, with a shadow.
  bool get _onPicture => image != null && !unavailable;

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
            // Positioned rather than laid out, so the tile is sized by its words
            // exactly as it was before pictures existed. Decoding happens off this
            // frame: the grid is drawn and tappable before the first one arrives.
            if (_onPicture) ...[
              Positioned.fill(
                child: Image.memory(
                  image!,
                  key: Key('product-image-${product.id}'),
                  fit: BoxFit.cover,
                  gaplessPlayback: true,
                  // A picture that will not decode leaves the tile as it would have
                  // been rather than blanking it, which reads as a missing product.
                  errorBuilder: (_, _, _) => const SizedBox.shrink(),
                ),
              ),
              const Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Colors.black26, Colors.black87],
                    ),
                  ),
                ),
              ),
            ],
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
                          : TextStyle(
                              fontSize: 15,
                              height: 1.15,
                              fontWeight: FontWeight.w500,
                              color: _onPicture ? Colors.white : null,
                              shadows: _onPicture ? _readable : null)),
                  const SizedBox(height: 8),
                  if (unavailable)
                    Text(tr(context, 'Sold out'),
                        key: Key('soldout-${product.id}'),
                        style: TextStyle(color: Colors.red.shade700, fontWeight: FontWeight.bold, fontSize: 13))
                  else
                    Text(price,
                        style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 17,
                            color: _onPicture ? Colors.white : null,
                            shadows: _onPicture ? _readable : null)),
                ],
              ),
            ),
            if (favourite)
              const Positioned(
                top: 2,
                right: 2,
                child: Icon(Icons.star, size: 14, color: Colors.amber),
              ),
            // The bottom leading corner, so it clears the favourite star at the top
            // and follows the text direction into Arabic. A required group is drawn
            // in the attention colour and an optional one in the neutral: the
            // cashier's question is not "does this have extras" but "will this stop
            // me", and the badge answers that before the tile is tapped.
            if (modifiers != null && !unavailable)
              PositionedDirectional(
                bottom: 2,
                start: 2,
                child: Container(
                  key: Key('product-mods-${product.id}'),
                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                  decoration: BoxDecoration(
                    color: modifiers!.required
                        ? AppColors.warning
                        : Colors.black.withValues(alpha: 0.55),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    const Icon(Icons.tune, size: 11, color: Colors.white),
                    if (modifiers!.groups > 1) ...[
                      const SizedBox(width: 2),
                      Text('${modifiers!.groups}',
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 10,
                              fontWeight: FontWeight.bold)),
                    ],
                  ]),
                ),
              ),
          ],
        ),
      ),
    );
    return tile;
  }

  static const _readable = [Shadow(blurRadius: 4, color: Colors.black87)];
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

/// How a bill is being paid. The payment sheet's first question, and the reason a
/// cashier no longer has to leave the payment sheet to split a table.
enum _PayMode { all, evenly, guest, item }

/// The tender step: choose how the bill is being paid (all of it, or split), pick
/// the method, split it across methods if needed, add a tip, enter cash received to
/// see the change, and confirm. A real payment moment with feedback, not a silent
/// clear.
class _PaymentSheet extends StatefulWidget {
  const _PaymentSheet({
    required this.total,
    required this.format,
    required this.methods,
    required this.onConfirm,
    this.onAccountMethod,
    this.hasCustomer = false,
    this.modes = const [],
    this.onMode,
    this.billTotal,
    this.alreadyPaid = 0,
    this.onBack,
  });

  final double total;
  final String Function(double) format;
  final List<PaymentMethod> methods;
  final void Function(
      List<OrderPayment> payments, String label, double tip, double? cashReceived) onConfirm;

  /// The ways this bill can be split, offered above the tender step. Empty leaves
  /// the sheet a plain tender step, which is all a counter sale ever needs.
  final List<_PayMode> modes;

  /// A way of splitting was chosen. The host closes the sheet and runs that flow,
  /// which comes back to this same sheet for the share it worked out.
  final void Function(_PayMode mode)? onMode;

  /// What the whole bill comes to, when [total] is only part of it. Shown beside
  /// what has already been taken, so a part-paid tab reads as a running balance
  /// rather than as a bare figure a cashier has to trust.
  final double? billTotal;
  final double alreadyPaid;

  /// The method an on-account sale books against, when the shop runs accounts.
  /// Null leaves the sheet exactly as it was.
  final PaymentMethod? onAccountMethod;

  /// Whether the order names the customer whose tab this would go on. Without one
  /// there is nobody to bill, so the action is offered but refused.
  final bool hasCustomer;

  /// Step back out of this tender step to the step before it (the guest list, when
  /// paying guest by guest), instead of only cancelling out of payment entirely.
  /// Null hides the back control, which is what a plain whole-bill payment wants.
  final VoidCallback? onBack;

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
    // Seeded with what is owed, because the common cash sale is exact and Charge
    // is gated on the received amount covering the bill. Without this the cashier
    // has to type the total back in before the button will even light up. Anything
    // typed over it still gives change, and the tip keeps it in step from here.
    _received.text = _grand.toStringAsFixed(2);
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

  /// Put the whole bill on the customer's tab. One tender, the full amount, under
  /// its own label, so the sale books and reports like any other sale while the
  /// receivables list can still pick it out. Refused without a customer: an unnamed
  /// debt is money written off.
  void _confirmOnAccount() {
    final method = widget.onAccountMethod;
    if (method == null) return;
    if (!widget.hasCustomer) {
      showToast(
          context, tr(context, 'Add a customer to the order before billing it.'),
          kind: ToastKind.error, key: const Key('on-account-refused'));
      return;
    }
    widget.onConfirm(
      [OrderPayment(methodId: method.id, amount: _grand, label: kOnAccountLabel)],
      kOnAccountLabel,
      _tipAmount,
      null,
    );
  }

  /// What is owed, in the biggest type on the sheet, because it is the number the
  /// cashier and the customer both look for. A tab that has already had shares taken
  /// off it shows the bill and what has been paid underneath, so the running balance
  /// is obvious rather than inferred.
  Widget _amountOwed(BuildContext context) {
    final bill = widget.billTotal;
    final partPaid = bill != null && widget.alreadyPaid > 0.001;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.primary.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(tr(context, 'Amount due'),
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
              Text(widget.format(_grand),
                  key: const Key('pay-total'),
                  style: const TextStyle(fontSize: 30, fontWeight: FontWeight.bold)),
            ],
          ),
          if (partPaid) ...[
            const SizedBox(height: 4),
            Text(
              '${tr(context, 'Bill')} ${widget.format(bill)}  ·  '
              '${tr(context, 'Paid')} ${widget.format(widget.alreadyPaid)}',
              key: const Key('running-balance'),
              style: const TextStyle(fontSize: 13, color: Colors.black54),
            ),
          ],
        ],
      ),
    );
  }

  /// The first step: how is this being paid. Answered in the payment sheet, where a
  /// cashier looks for it, rather than in a menu somewhere else on the screen.
  Widget _modeRow(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(tr(context, 'How is this being paid?'),
            style: const TextStyle(fontSize: 13, color: Colors.black54)),
        const SizedBox(height: 8),
        Row(children: [
          for (final mode in widget.modes) ...[
            Expanded(child: _modeButton(context, mode)),
            if (mode != widget.modes.last) const SizedBox(width: 8),
          ],
        ]),
      ],
    );
  }

  Widget _modeButton(BuildContext context, _PayMode mode) {
    // "All of it" is where the sheet already is, so it reads as the selected step
    // rather than as a button that would do something.
    final selected = mode == _PayMode.all;
    final (icon, label) = switch (mode) {
      _PayMode.all => (Icons.payments, tr(context, 'All of it')),
      _PayMode.evenly => (Icons.safety_divider, tr(context, 'Split evenly')),
      _PayMode.guest => (Icons.groups_2_outlined, tr(context, 'By guest')),
      _PayMode.item => (Icons.checklist, tr(context, 'By item')),
    };
    return InkWell(
      key: Key('pay-mode-${mode.name}'),
      borderRadius: BorderRadius.circular(12),
      onTap: selected ? null : () => widget.onMode?.call(mode),
      child: Container(
        height: 72,
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
        decoration: BoxDecoration(
          color: selected
              ? AppColors.primary.withValues(alpha: 0.16)
              : Colors.black.withValues(alpha: 0.04),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
              color: selected ? AppColors.primary : Colors.black.withValues(alpha: 0.12),
              width: selected ? 2 : 1),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 22, color: selected ? AppColors.primary : Colors.black87),
            const SizedBox(height: 4),
            Text(label,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 12,
                    height: 1.1,
                    fontWeight: selected ? FontWeight.bold : FontWeight.w500)),
          ],
        ),
      ),
    );
  }

  /// A tender as a button big enough to hit without looking, the way the shop's
  /// other till does it. The icon is picked off the method so cash, card and wallet
  /// are told apart at a glance on a busy screen.
  Widget _methodButton(BuildContext context, PaymentMethod m) {
    final selected = _method?.id == m.id;
    return SizedBox(
      width: 132,
      child: InkWell(
        key: Key('method-${m.id}'),
        borderRadius: BorderRadius.circular(14),
        onTap: () => setState(() => _method = m),
        child: Container(
          height: 76,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          decoration: BoxDecoration(
            color: selected
                ? AppColors.primary.withValues(alpha: 0.16)
                : Colors.black.withValues(alpha: 0.04),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
                color:
                    selected ? AppColors.primary : Colors.black.withValues(alpha: 0.12),
                width: selected ? 2 : 1),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(_methodIcon(m),
                  size: 24, color: selected ? AppColors.primary : Colors.black87),
              const SizedBox(height: 4),
              Text(m.name,
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 14,
                      fontWeight: selected ? FontWeight.bold : FontWeight.w500)),
            ],
          ),
        ),
      ),
    );
  }

  IconData _methodIcon(PaymentMethod m) {
    if (m.isCash) return Icons.payments_outlined;
    final name = m.name.toLowerCase();
    if (name.contains('wallet') || name.contains('محفظة')) {
      return Icons.account_balance_wallet_outlined;
    }
    if (name.contains('transfer') || name.contains('bank')) {
      return Icons.account_balance_outlined;
    }
    return Icons.credit_card;
  }

  /// Change owed, as a band the cashier cannot miss. Nothing is shown when there is
  /// no change: an empty row where a number should be reads as a fault.
  Widget _changeBanner(BuildContext context) {
    if (_change <= 0.001) return const SizedBox.shrink();
    return Container(
      key: const Key('change'),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.green.shade50,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.green.shade400),
      ),
      child: Row(children: [
        Icon(Icons.savings_outlined, color: Colors.green.shade800),
        const SizedBox(width: 10),
        Expanded(
            child: Text(tr(context, 'Change to give back'),
                style: const TextStyle(fontWeight: FontWeight.w600))),
        Text(widget.format(_change),
            style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.bold,
                color: Colors.green.shade800)),
      ]),
    );
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
      // The header is outside the scroll view so what is owed stays on screen while
      // the cashier works down the sheet, keyboard up and all.
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(children: [
            if (widget.onBack != null)
              IconButton(
                key: const Key('payment-back'),
                icon: const BackButtonIcon(),
                tooltip: tr(context, 'Back'),
                onPressed: widget.onBack,
              ),
            Text(tr(context, 'Payment'),
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const Spacer(),
            // One bill paid part cash, part card. Named for the methods, not for
            // splitting the bill: that is what the mode row answers.
            FilterChip(
              key: const Key('split-toggle'),
              label: Text(tr(context, 'Mixed methods')),
              selected: _split,
              onSelected: (v) => setState(() {
                _split = v;
                _tenders.clear();
              }),
            ),
          ]),
          const SizedBox(height: 8),
          _amountOwed(context),
          Flexible(
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                if (widget.modes.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  _modeRow(context),
                ],
                const SizedBox(height: 12),
                // The tender comes before the tip and the cash, because picking it is
                // what the cashier does first and what the rest of the sheet reacts to.
                if (_methods.isNotEmpty)
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      for (final m in _methods) _methodButton(context, m),
                    ],
                  )
                else
                  // No tender came from Odoo. The sale still goes through and books
                  // as cash, but silence here reads as "this till only takes cash",
                  // so it says which of the two it is and what fixes it.
                  Column(
                    key: const Key('no-payment-methods'),
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(tr(context, 'Cash'),
                          style: const TextStyle(
                              fontSize: 16, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 4),
                      Text(
                        tr(context,
                            'No payment methods have come from Odoo yet, so this sale '
                            'books as cash. Set the server in Settings, then refresh '
                            'the menu.'),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                const SizedBox(height: 12),
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
                ],
              ),
            ),
          ),
          // Outside the scroll view on purpose. Charge is the whole point of the
          // sheet, and on a short till it was scrolling off the bottom where a
          // cashier could not reach it. The fields above scroll; the money button
          // does not move.
          const SizedBox(height: 10),
          _changeBanner(context),
          const SizedBox(height: 14),
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
          if (widget.onAccountMethod != null) ...[
            const SizedBox(height: 8),
            SizedBox(
              height: 52,
              child: OutlinedButton.icon(
                key: const Key('pay-later'),
                onPressed: _confirmOnAccount,
                icon: const Icon(Icons.account_balance_wallet_outlined),
                label: Text(widget.hasCustomer
                    ? tr(context, 'Put it on the account')
                    : tr(context, 'On account (needs a customer)')),
              ),
            ),
          ],
          const SizedBox(height: 4),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(tr(context, 'Cancel')),
          ),
        ],
      ),
    );
  }
}
