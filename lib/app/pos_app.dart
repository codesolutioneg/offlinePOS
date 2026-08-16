import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import '../core/i18n/l10n.dart';

import '../core/audit/audit_log.dart';
import '../core/auth/auth_service.dart';
import '../core/auth/bootstrap_cashier.dart';
import '../core/auth/permissions.dart';
import '../core/auth/user_store.dart';
import '../core/config/till_config.dart';
import '../core/db/catalogue_store.dart';
import '../core/db/attendance_store.dart';
import '../core/db/customer_store.dart';
import '../core/db/delivery_store.dart';
import '../core/db/order_store.dart';
import '../core/db/reservation_store.dart';
import '../core/db/settings_store.dart';
import '../core/db/shift_store.dart';
import '../core/db/sqlite_outbox_store.dart';
import '../core/db/table_store.dart';
import '../core/email/email_service.dart';
import '../core/lan/lan_cart_board.dart';
import '../core/lan/lan_claim.dart';
import '../core/lan/lan_shift_board.dart';
import '../core/lan/lan_wiring.dart';
import '../core/onboarding/setup_checklist.dart';
import '../core/onboarding/wizard_id.dart';
import '../core/onboarding/wizard_store.dart';
import '../core/printing/escpos.dart';
import '../core/widgets/feedback.dart';
import '../core/printing/kitchen_ticket.dart';
import '../core/printing/printer_logo.dart';
import '../core/printing/printer_registry.dart';
import '../core/printing/printer_transport.dart';
import '../core/printing/receipt_builder.dart';
import '../core/printing/registry_printer.dart';
import '../core/printing/spool_store.dart';
import '../core/sync/odoo_endpoint.dart';
import '../core/sync/odoo_puller.dart';
import '../core/sync/odoo_wiring.dart';
import '../core/sync/outbox.dart';
import '../core/sync/server_probe.dart';
import '../core/sync/sync_service.dart';
import '../core/theme/app_colors.dart';
import '../core/theme/app_theme.dart';
import '../core/updates/update_service.dart';
import '../domain/business_day.dart';
import '../domain/catalogue.dart';
import '../domain/order.dart';
import '../domain/shift.dart';
import '../features/admin/attendance_screen.dart';
import '../features/admin/roles_permissions_screen.dart';
import '../features/admin/roster_screen.dart';
import '../features/support/audit_log_screen.dart';
import '../features/auth/login_screen.dart';
import '../features/customers/customer_management_screen.dart';
import '../features/display/customer_display_screen.dart';
import '../features/kitchen/kitchen_display_screen.dart';
import '../features/onboarding/setup_checklist_card.dart';
import '../features/onboarding/wizard_overlay.dart';
import '../features/orders/open_orders_screen.dart';
import '../features/orders/order_history_screen.dart';
import '../features/orders/refund_screen.dart';
import '../features/reports/reports_hub_screen.dart';
import '../features/sell/sell_screen.dart';
import '../features/settings/appearance_settings_screen.dart';
import '../features/settings/delivery_settings_screen.dart';
import '../features/settings/discount_settings_screen.dart';
import '../features/settings/email_settings_screen.dart';
import '../features/settings/lan_settings_screen.dart';
import '../features/settings/tax_settings_screen.dart';
import '../features/settings/payment_methods_screen.dart';
import '../features/settings/printers_screen.dart';
import '../features/settings/quick_comments_screen.dart';
import '../features/settings/receipt_designer_screen.dart';
import '../features/settings/server_settings_screen.dart';
import '../features/settings/settings_hub_screen.dart';
import '../features/settings/shop_settings_screen.dart';
import '../features/shift/shift_screen.dart';
import '../features/support/diagnostics_screen.dart';
import '../features/tables/table_floor_screen.dart';
import 'pos_session.dart';
import 'till_activity.dart';

/// Wires the till together and decides which screen is showing.
///
/// Sign-in gates selling, but nothing here waits on a network: the roster, the
/// catalogue and the PIN check are all local, so the app behaves the same whether
/// the line is up or not.
class PosApp extends StatefulWidget {
  const PosApp({
    super.key,
    required this.auth,
    required this.users,
    required this.catalogue,
    required this.orders,
    required this.outbox,
    required this.audit,
    required this.sync,
    required this.outboxStore,
    required this.printers,
    required this.wizards,
    required this.shifts,
    required this.deviceId,
    required this.endpoints,
    required this.odoo,
    required this.tables,
    required this.settings,
    required this.customers,
    required this.attendance,
    this.delivery,
    this.config = const TillConfig(),
    this.receiptSpool,
    this.checkServer,
    this.backup,
    this.activity,
    this.provisioningPin,
    this.updates,
    this.lan,
    this.emailer,
    this.reservations,
  });

  /// Tables booked ahead. Null on a shop that does not take bookings and in the
  /// suites that predate them, and then the floor reads exactly as it did.
  final ReservationStore? reservations;

  final AuthService auth;
  final UserStore users;
  final CatalogueStore catalogue;
  final OrderStore orders;
  final Outbox outbox;
  final AuditLog audit;
  final SyncService sync;
  final SqliteOutboxStore outboxStore;
  final PrinterRegistry printers;
  final WizardStore wizards;
  final ShiftStore shifts;
  final String deviceId;
  final OdooEndpointStore endpoints;
  final OdooWiring odoo;

  /// Asks the configured server whether it is there and whether it knows this
  /// login, for the button on the server screen. Null on a build with no way to
  /// reach out, which hides the button rather than showing one that cannot answer.
  final Future<ServerCheckResult> Function(OdooEndpoint)? checkServer;

  /// Copies the whole encrypted database somewhere a human can pick it up, and
  /// answers with where it landed. Held here rather than built here because this
  /// shell is given stores, not the database they sit in.
  final Future<String> Function()? backup;

  /// The floor plan and the on-device settings a manager edits on the device.
  final TableStore tables;
  final SettingsStore settings;

  /// Customers created on the till (separate from the read-only Odoo partners).
  final CustomerStore customers;

  /// The delivery lists a shop keeps on the device: zones, channels and drivers.
  /// Null on a build that was assembled without one, which simply leaves the zone,
  /// channel and driver controls off the delivery dialog.
  final DeliveryStore? delivery;

  /// Staff clock in / clock out, separate from the cash-drawer shift.
  final AttendanceStore attendance;

  /// Shop name, tax id and receipt footer. Nothing here is invented in code: a
  /// receipt with no shop name and no tax id is not a legal receipt, and a
  /// plausible placeholder hides that from whoever installs the till.
  final TillConfig config;

  /// Where receipts that could not print are held. A durable store on a till, so
  /// a rush spent with the printer off is still reprintable after the nightly
  /// restart.
  final SpoolStore? receiptSpool;

  /// Published for the update gate, so it can see a customer mid-order.
  final TillActivity? activity;

  /// Shown once on the sign-in screen when the till has no real roster yet.
  final String? provisioningPin;

  /// Null when this build has no update channel configured.
  final UpdateService? updates;

  /// Sends the Z report to whoever the shop asked for, best effort. Null on a
  /// build with no mail wired, which hides the setting rather than offering one
  /// that goes nowhere.
  final EmailService? emailer;

  /// This device's presence on the shop LAN, or null when it is not sharing state
  /// with the other devices. Null is the ordinary case: a one-till shop.
  ///
  /// Handed over assembled but not started. Starting it belongs here rather than in
  /// main so that binding a socket happens behind the first frame, and so the shell
  /// can take the device off the LAN the moment the switch is turned off.
  final LanNode? lan;

  /// The name receipts are routed by. Part of the on-disk contract: the printers
  /// table and the held-receipt queue are both keyed on it.
  static const String receiptPrinter = 'receipt';

  static String money(double v) => v.toStringAsFixed(2);

  @override
  State<PosApp> createState() => _PosAppState();
}

/// What the till has to say about the drawer when a cashier signs in: nobody
/// opened a shift, or one is still open from an earlier trading day. Neither stops
/// anyone selling; both are how a day ends up with a Z that makes no sense.
enum ShiftNudge { noShift, staleShift }

/// What a cashier is shown the first time they ring something up.
const _firstSaleSteps = [
  WizardStep(
    title: 'Ring it up',
    body: 'Tap a product to add it. Search or scan a barcode to find one fast.',
  ),
  WizardStep(
    title: 'Take the money',
    body: 'Tap Pay. The sale is saved on this till before anything is sent '
        'anywhere, so it survives the line going down.',
  ),
  WizardStep(
    title: 'If the receipt does not print',
    body: 'The sale is already safe. Open the support screen from the top right '
        'to find the printer again and reprint.',
  ),
];

class _PosAppState extends State<PosApp> {
  /// The navigator MaterialApp builds, so code that runs outside any screen (the
  /// post-sign-in jump to the floor) can still push one.
  final GlobalKey<NavigatorState> _navigator = GlobalKey<NavigatorState>();

  PosSession? _session;
  bool _firstSaleHelp = false;

  /// Whether the walkthrough for the provisioning account is up. Only that account
  /// ever sees it: it is the one that stands in front of an unconfigured till.
  bool _firstSignInHelp = false;
  String? _printError;
  Timer? _background;

  /// What the cashier who just signed in needs telling about the drawer, or null
  /// when the shift is in order. Cleared when they act on it or wave it away.
  ShiftNudge? _nudge;

  /// The lines a paid sale carried when it was reopened for correction, by order
  /// uuid. Kept only until that sale is tendered again, so the second payment can
  /// print one slip for everything that came off a bill the customer had already
  /// paid, whether or not the kitchen ever held it.
  ///
  /// Deliberately not on disk. The sale itself is durable and the correction is in
  /// the audit trail; this is only what a slip is printed from, and a till
  /// restarted mid-correction losing one piece of paper is the right trade against
  /// another schema field to migrate.
  final Map<String, List<OrderLine>> _amending = {};

  /// Lines that already had their own deletion slip printed at the moment they
  /// were voided, so the correction slip does not print them a second time.
  final Set<String> _slipped = {};

  /// Drives the app language and text direction, seeded from the saved setting and
  /// persisting any change.
  late final LocaleController _locale = LocaleController(
    Locale(widget.settings.language),
    onChanged: (code) => widget.settings.language = code,
  );

  /// One spool for the life of the app, above the registry rather than above an
  /// address: a receipt that could not print stays reprintable even if the printer
  /// comes back on a different lease.
  late final SpooledPrinter _receiptPrinter = SpooledPrinter(
    RegistryPrinter(widget.printers, PosApp.receiptPrinter),
    spool: widget.receiptSpool,
    // The cap exists so a printer left off for a week cannot fill the disk, but a
    // discarded receipt is a customer with no proof of payment, so it goes into
    // the audit trail rather than disappearing.
    onDropped: (job) => widget.audit.record(
      _session?.cashierId ?? 'system',
      'receipt.dropped',
      detail: job.reference,
    ),
  );

  @override
  void initState() {
    super.initState();
    // The same slow lane the sync timer runs in. Held receipts used to wait for a
    // human to open the support screen and press Reprint, which meant a printer
    // that came back mid-shift printed nothing until somebody noticed.
    _background = Timer.periodic(const Duration(seconds: 30), (_) => _catchUp());
    unawaited(_startLan());
  }

  @override
  void dispose() {
    _background?.cancel();
    unawaited(widget.lan?.dispose());
    super.dispose();
  }

  /// Bring this device onto the shop LAN, if it is set up for one.
  ///
  /// Never awaited by anything: a bind, a broadcast and a first catch-up all happen
  /// behind the first frame, so the first sale of the day cannot be waiting on a
  /// switch that is not plugged in yet. LanNode logs its own failures and returns
  /// rather than throwing; this catch is for the unforeseen one, because a shop must
  /// still be able to open when its network cannot.
  Future<void> _startLan() async {
    final lan = widget.lan;
    if (lan == null) return;
    try {
      await lan.start();
    } catch (e) {
      widget.audit.record('system', 'lan.start.failed', detail: '$e');
    }
  }

  /// Follow the LAN switch the moment it is flipped.
  ///
  /// Switching sharing off closes the socket and stops the announcements now rather
  /// than at the next restart, so a manager who turns it off has actually turned it
  /// off. Switching it on can only restart a fabric this launch already assembled;
  /// a device that started the day off the LAN picks it up on the next launch, which
  /// is what the screen says, because standing up an event log behind orders that
  /// are already on screen would replicate a half-known shop.
  Future<void> _reconcileLan() async {
    final lan = widget.lan;
    if (lan == null) return;
    if (widget.settings.lanEnabled(fallback: widget.config.lanDefault)) {
      await _startLan();
    } else {
      await lan.stop();
    }
  }

  Future<void> _catchUp() async {
    _fireDueTimedLines();
    if (_receiptPrinter.hasSpooled) await _receiptPrinter.flush();
    // A Z report queued while the line was down goes out on its own, rather than
    // waiting for someone to open a settings screen and press something.
    final emailer = widget.emailer;
    if (emailer != null) await emailer.flush();
    if (mounted) setState(() {});
    // An update is the least important thing this app does, so it runs last and
    // its own gate decides whether anything actually happens.
    await widget.updates?.check();
  }

  /// Fire any course-timed lines whose timer has elapsed on a committed order.
  /// This is what makes "fire the mains 15 minutes after the starters" happen on
  /// its own: the delayed lines were held back at Send, and this sends them when
  /// their time comes.
  void _fireDueTimedLines() {
    final now = DateTime.now().toUtc();
    // Include the order on the counter: a cashier can set a timer and Send while the
    // table stays open (draft), and its delayed lines must still fire on time.
    final orders = <Order>[
      if (_session != null) _session!.current,
      ...widget.orders.held(),
      ...widget.orders.awaitingSync(),
    ];
    final seen = <String>{};
    for (final o in orders) {
      if (!seen.add(o.uuid)) continue;
      final due = o.lines
          .where((l) => l.fireAt != null && !l.printedToKitchen && l.dueAt(now))
          .toList();
      if (due.isNotEmpty) unawaited(_fireKitchen(o, only: due));
    }
  }

  void _signedIn(Cashier cashier) {
    setState(() {
      _session = PosSession(
        catalogue: widget.catalogue,
        orders: widget.orders,
        outbox: widget.outbox,
        audit: widget.audit,
        deviceId: widget.deviceId,
        cashierId: cashier.id,
        // Category/order-type tax rules, so (e.g.) takeaway food can be zero-rated.
        taxRateFor: (categoryId, type) =>
            categoryId == null ? null : widget.settings.categoryTaxRate(categoryId, type),
        // The service percentage a bill opens with. Read per order rather than held,
        // so a manager changing it mid-service applies to the next bill and not to
        // the ones already on the floor.
        serviceChargeFor: widget.settings.serviceChargePercentFor,
        // The number staff and customers actually say out loud. Per till and per
        // trading day, handed out when an order is parked or paid.
        nextOrderNo: () => widget.settings.nextOrderNumber(widget.deviceId),
      );
      _firstSaleHelp = widget.wizards.shouldShow(WizardId.firstSale, cashier.id);
      // The provisioning account is whoever is standing at a till that has just
      // been installed, so it is the one that gets walked through what is left to
      // do. A real cashier meets the first-sale help instead.
      _firstSignInHelp = cashier.id == BootstrapCashier.id &&
          widget.wizards.shouldShow(WizardId.firstSignIn, cashier.id);
    });
    // Support asks who is on the till before anything else.
    widget.sync.cashierId = cashier.id;
    // Ask for the menu now rather than when the age gate expires. A cashier
    // opening the till at 08:00 sells this morning's prices, not last night's.
    // Never awaited: read-only, off the selling path, and a till with no line
    // just carries on with what it has.
    unawaited(widget.sync.refresh(force: true).then((_) {
      if (mounted) setState(() {});
    }));
    _publishActivity();
    final session = _session;
    if (session == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // Through the navigator's own context, not this shell's: this state is the
      // parent of MaterialApp, so Navigator.of would look upwards and find
      // nothing.
      final below = _navigator.currentContext;
      if (!mounted || below == null) return;
      // Land on the floor home once signed in, unless a draft order was restored
      // (crash recovery): the table plan is the base screen an order starts from.
      if (session.current.lines.isEmpty && session.current.tableLabel == null) {
        _openFloor(below, session);
      }
    });
    _nudgeShift();
  }

  /// Work out whether the cashier signing in needs telling about the drawer: no
  /// shift open at all, or one still open from an earlier trading day quietly
  /// absorbing today's sales.
  void _nudgeShift() {
    final shift = widget.shifts.currentOpenShift();
    // One trading day, the shop's own: a shift opened last night is not stale at
    // 02:00 under a 04:00 cutover, because that is still the same service.
    final stale = shift != null &&
        BusinessDay.of(shift.openedAt) != BusinessDay.of(DateTime.now().toUtc());
    final nudge = switch ((shift, stale)) {
      (null, _) => ShiftNudge.noShift,
      (_, true) => ShiftNudge.staleShift,
      _ => null,
    };
    if (nudge != _nudge) setState(() => _nudge = nudge);
  }

  /// The strip that carries [_nudge], above every screen in the app.
  ///
  /// A strip and not a dialog, deliberately. Selling is never gated on this: a queue
  /// at the counter outranks the paperwork, and a modal at sign-in is a modal that
  /// gets dismissed without being read. It sits above the navigator rather than on
  /// one screen, so it is read on the floor the cashier lands on as well as on the
  /// sell screen, and it takes its own space instead of covering the till.
  Widget _shiftNudgeBar(BuildContext context, ShiftNudge nudge) {
    final stale = nudge == ShiftNudge.staleShift;
    return Material(
      key: const Key('shift-nudge'),
      color: AppColors.error,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Row(children: [
            Icon(stale ? Icons.history_toggle_off : Icons.point_of_sale,
                size: 20, color: Colors.white),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                tr(
                    context,
                    stale
                        ? 'A shift is open from an earlier day. Close it first.'
                        : 'No shift is open. Open one with a float?'),
                style: const TextStyle(color: Colors.white),
              ),
            ),
            TextButton(
              key: const Key('shift-nudge-open'),
              style: TextButton.styleFrom(foregroundColor: Colors.white),
              onPressed: () {
                setState(() => _nudge = null);
                final session = _session;
                final below = _navigator.currentContext;
                if (session != null && below != null) _openShift(below, session);
              },
              child: Text(tr(context, stale ? 'Close shift' : 'Open shift')),
            ),
            TextButton(
              key: const Key('shift-nudge-dismiss'),
              style: TextButton.styleFrom(foregroundColor: Colors.white),
              onPressed: () => setState(() => _nudge = null),
              child: Text(tr(context, 'Not now')),
            ),
          ]),
        ),
      ),
    );
  }

  /// Ends the shift without ending the process.
  ///
  /// A shift change with no network is a headline capability of this app, and
  /// until there was a control for it the only way to change cashier was to kill
  /// the app.
  void _signOut() {
    widget.auth.signOut();
    widget.sync.cashierId = null;
    setState(() {
      _session = null;
      _firstSaleHelp = false;
      // The nudge belongs to the cashier who was told it, not to the sign-in screen
      // the next one is looking at.
      _nudge = null;
    });
    _publishActivity();
  }

  /// Tells the update gate whether a customer is standing at the counter. Lines on
  /// screen is the honest signal: the order is already on disk, but replacing the
  /// binary underneath a half-rung sale is exactly what the gate exists to stop.
  void _publishActivity() =>
      widget.activity?.saleInProgress = _session?.hasLines ?? false;

  /// Built as printer bytes, never rasterised, and never awaited by the screen that
  /// took the money: the sale is committed before this runs, so a printer that is
  /// off costs a spooled reprint and nothing else.
  /// A receipt builder wired to the current on-device settings, so the sale slip,
  /// the deletion slip and the sample all lay out identically. [openDrawer] is only
  /// ever true for a cash sale's first copy.
  ReceiptBuilder _receiptBuilder({
    bool openDrawer = false,
    bool? showItemPrice,
    bool showTotals = true,
  }) {
    final s = widget.settings;
    return ReceiptBuilder(
      shopName: s.shopName ?? widget.config.shopName,
      taxId: s.receiptShowTax ? (s.taxId ?? widget.config.taxId) : null,
      footer: s.receiptFooter ?? widget.config.receiptFooter,
      header: s.getString('receipt_header'),
      columns: s.receiptColumns,
      showCashier: s.getBool('receipt_show_cashier', fallback: true),
      showOrderType: s.getBool('receipt_show_ordertype', fallback: true),
      showTax: s.receiptShowTax,
      showDateTime: s.receiptShowDateTime,
      showNumber: s.receiptShowNumber,
      showTable: s.receiptShowTable,
      showPayment: s.receiptShowPayment,
      showItemPrice: showItemPrice ?? s.receiptShowItemPrice,
      showTotals: showTotals,
      logo: s.receiptLogoCommand(),
      paymentLabels: s.paymentMethodLabels,
      dividerStyle: s.receiptDividerStyle,
      openDrawer: openDrawer,
      // The floor plan is on this device, so the slip can say which part of the room
      // the table is in without the printing layer knowing the database exists.
      sectionOf: widget.tables.sectionFor,
      formatAmount: PosApp.money,
    );
  }

  /// The pass's own copy of the slip: the same sale, with the amount column off, on
  /// whichever station the shop nominated. Off unless a station is set.
  ///
  /// Sent the way a kitchen ticket is, so a station that is down falls back to the
  /// receipt printer and its spool rather than losing the copy, and never on a
  /// reprint: the customer's slip comes out again, the pass does not need the same
  /// bag listed twice.
  Future<void> _printSubReceipt(Order order) async {
    final s = widget.settings;
    final station = s.subReceiptStation;
    if (station.isEmpty) return;
    final hide = s.subReceiptHidePrices;
    // Hiding prices takes the money off the whole slip, not just the item column: a
    // copy that still footed a total is a second receipt.
    final bytes = _receiptBuilder(showItemPrice: !hide, showTotals: !hide)
        .build(order);
    await _sendToStation(station, bytes, 'subreceipt-${order.uuid}-$station');
  }

  /// Write the shop's mark into the receipt printer's own flash, once, by hand.
  ///
  /// Sent past the spool for the same reason the drawer kick is: a flash write that
  /// sat in a backlog and replayed itself for a week would spend the printer's
  /// limited write cycles on nothing. It throws when the printer is not there, which
  /// is what the designer wants to be able to say.
  Future<void> _uploadLogo(PrinterLogo logo) =>
      _receiptPrinter.sendNow(logo.defineNv());

  /// Print a record slip when items are voided or an order is cancelled, so every
  /// removal leaves a paper trail at the till alongside the audit entry. Spooled
  /// like any receipt: a record slip that missed the printer is reprinted, not lost.
  Future<void> _printDeletion(Order order, List<OrderLine> lines,
      {required String title, String? reason}) async {
    if (lines.isEmpty) return;
    final bytes = _receiptBuilder().buildDeletion(
      order,
      lines,
      title: title,
      at: DateTime.now(),
      actor: _session?.cashierId,
      reason: reason,
    );
    try {
      await _receiptPrinter.send(bytes, reference: 'void-slip-${order.uuid}-${DateTime.now().microsecondsSinceEpoch}');
    } on PrinterUnavailable {
      // Held in the spool; the background flush reprints it.
    }
  }

  /// Print the check for a table that asked for the bill before paying. Spooled like
  /// any other slip, so a printer that is off holds the bill instead of failing the
  /// waiter's tap, and the order is never touched: this produces paper and an audit
  /// entry, nothing else. Works with no shift open, hence the cashier fallback.
  Future<void> _printBill(Order order) async {
    widget.audit.record(_session?.cashierId ?? order.cashierId, 'bill.printed',
        detail: order.uuid);
    try {
      final bytes = _receiptBuilder().buildBill(order);
      // A bill is reprintable on demand, so the timestamp keeps each copy out of the
      // spool's dedupe rather than folding a second request into the first.
      await _receiptPrinter.send(bytes,
          reference: 'bill-${order.uuid}-${DateTime.now().microsecondsSinceEpoch}');
    } on PrinterUnavailable {
      // Held in the spool; the background flush prints it when the printer is back.
    } catch (e) {
      // Building the slip is inside the try for the same reason as the sale receipt:
      // a character the printer cannot carry must leave a record, not an unhandled
      // error on a waiter's tap.
      widget.audit.record(order.cashierId, 'receipt.failed', detail: '${order.uuid}: $e');
    }
  }

  /// Print one slip for what a corrected sale lost, when it is tendered again.
  ///
  /// A line the kitchen already held printed its own slip the moment it was voided,
  /// and is skipped here. What is left is what the customer had paid for and no
  /// longer has, which leaves no paper anywhere else: a line taken off with a plain
  /// delete, and units stepped off a line that is otherwise still on the bill. A
  /// no-op on any sale that was not reopened.
  void _slipRemovedOnAmend(Order order) {
    final before = _amending.remove(order.uuid);
    if (before == null) return;
    final kept = {for (final l in order.lines) l.uuid: l};
    final removed = <OrderLine>[];
    for (final l in before) {
      final still = kept[l.uuid];
      if (still == null) {
        // Already on paper from its own void slip, and taken off the set as it is
        // consumed so nothing accumulates across a shift.
        if (_slipped.remove(l.uuid)) continue;
        removed.add(l);
        continue;
      }
      // Stepping a line down is money off an already-paid bill too, and the line
      // keeps its uuid, so only the quantity says it happened.
      if (still.quantity < l.quantity) {
        removed.add(_unitsOff(l, l.quantity - still.quantity));
      }
    }
    unawaited(_printDeletion(order, removed,
        title: 'REMOVED ON EDIT', reason: 'Order amended'));
  }

  /// [quantity] units of [line], priced exactly as they were sold, so the slip's
  /// REMOVED total is what the customer is owed back for them.
  static OrderLine _unitsOff(OrderLine line, double quantity) => OrderLine(
        productId: line.productId,
        name: line.name,
        quantity: quantity,
        unitPrice: line.unitPrice,
        categoryId: line.categoryId,
        taxRate: line.taxRate,
        baseTaxRate: line.baseTaxRate,
        discountPercent: line.discountPercent,
        note: line.note,
        seat: line.seat,
        modifiers: line.modifiers,
      );

  Future<void> _printReceipt(Order order, {bool reprint = false}) async {
    try {
      // On-device settings win over the compile-time defaults, so a manager can
      // fix the shop name or tax id on the receipt without a rebuild. Tax id is
      // dropped when the receipt-tax toggle is off.
      final s = widget.settings;
      // Open the drawer for a cash sale: an empty tender books to cash, or any
      // tender against a cash method. A reprint never re-opens the drawer.
      final cashIds = widget.catalogue
          .paymentMethods()
          .where((m) => m.isCash)
          .map((m) => m.id)
          .toSet();
      final isCash = order.payments.isEmpty ||
          order.payments.any((p) => cashIds.contains(p.methodId));
      Uint8List build({required bool openDrawer}) =>
          _receiptBuilder(openDrawer: openDrawer).build(order, reprint: reprint);
      // A reprint uses a distinct reference so it does not collide with the
      // original in the spool's dedupe; extra copies get their own suffix so the
      // dedupe does not fold them into one. Only the first copy carries the drawer
      // kick, so a two-copy cash sale opens the drawer once, not twice.
      final base = reprint ? 'reprint-${order.uuid}' : order.uuid;
      final wantDrawer = isCash && !reprint && s.openDrawerOnSale;
      for (var i = 0; i < s.receiptCopies; i++) {
        try {
          await _receiptPrinter.send(build(openDrawer: wantDrawer && i == 0),
              reference: i == 0 ? base : '$base-c$i');
        } on PrinterUnavailable {
          // Each copy is spooled independently by SpooledPrinter before it rethrows,
          // so keep queuing the rest rather than losing the remaining copies when the
          // printer is down.
        }
      }
      // After the customer's copies, so the slip a cashier is waiting for is never
      // behind the pass's copy on the same roll.
      if (!reprint) await _printSubReceipt(order);
    } on PrinterUnavailable {
      // Already held in the spool by [SpooledPrinter]. Surfacing it here would put a
      // dialog between the cashier and the next customer.
    } catch (e) {
      // Building the receipt is inside the try for a reason: an unprintable
      // character used to throw before the spool had anything to hold, so the sale
      // was committed and the paper trail vanished with nothing anywhere saying so.
      // This is the one place a broad catch is right, and it records rather than
      // swallows.
      widget.audit.record(
        order.cashierId,
        'receipt.failed',
        detail: '${order.uuid}: $e',
      );
      if (mounted) setState(() => _printError = '$e');
    }
  }

  void _closeFirstSaleHelp(WizardOutcome outcome, String cashierId) {
    if (outcome == WizardOutcome.dismissedForever) {
      widget.wizards.dismiss(WizardId.firstSale, cashierId);
    }
    setState(() => _firstSaleHelp = false);
  }

  void _closeFirstSignInHelp(WizardOutcome outcome, String cashierId) {
    if (outcome == WizardOutcome.dismissedForever) {
      widget.wizards.dismiss(WizardId.firstSignIn, cashierId);
    }
    setState(() => _firstSignInHelp = false);
  }

  /// What this till still has to be told, read off the device every time rather
  /// than cached: a manager who adds a printer and comes back must see it ticked.
  SetupChecklist _setupChecklist() => SetupChecklist.of(
        serverConfigured: widget.endpoints.isConfigured,
        menuDownloaded: widget.catalogue.refreshedAt != null,
        printerConfigured: widget.printers.printers.isNotEmpty,
        // The provisioning account does not count as a roster: it is the account
        // that exists so a real one can be created.
        staffEnrolled: !BootstrapCashier.stillNeeded(widget.users.active()),
      );

  /// The walkthrough the provisioning account gets. The last panel is built from
  /// the checklist, so it names what is actually missing on THIS till rather than
  /// a generic list that is wrong the moment half of it is done.
  List<WizardStep> _firstSignInSteps(BuildContext context, SetupChecklist list) => [
        WizardStep(
          title: tr(context, 'This till is ready to sell'),
          body: tr(context,
              'Everything is stored on the device. You can ring a sale right '
              'now, with or without a connection.'),
        ),
        WizardStep(
          title: tr(context, 'Finish the setup from Settings'),
          body: tr(context,
              'Open the menu on the left, then Settings. The checklist at the '
              'top says what is still missing.'),
        ),
        WizardStep(
          title: tr(context,
              list.isComplete ? 'Nothing left to set up' : 'Still to do'),
          body: list.isComplete
              ? tr(context,
                  'The server, the menu, a printer and your staff are all set.')
              : list.outstanding
                  .map((s) => '- ${tr(context, s.title)}')
                  .join('\n'),
        ),
      ];

  @override
  Widget build(BuildContext context) {
    final session = _session;
    // Rebuilds the whole app when the language changes; MaterialApp derives the
    // Arabic right-to-left direction from the locale via the localization delegates.
    return ValueListenableBuilder<Locale>(
      valueListenable: _locale,
      builder: (context, locale, _) => MaterialApp(
        title: 'offlinePOS',
        // Held because this shell sits ABOVE the navigator it builds, so its own
        // context cannot push a route. Sign-in opens the floor from outside any
        // screen, and did nothing at all until this key existed.
        navigatorKey: _navigator,
        // Tuned for a touch screen: comfortable spacing and buttons/inputs tall
        // enough to tap reliably with a finger. Dark is the same theme with the
        // lights off, for a shop whose counter faces a window at night; the choice
        // is read here on every rebuild, so the settings toggle takes effect at once.
        theme: AppTheme.light(),
        darkTheme: AppTheme.dark(),
        themeMode: AppTheme.modeOf(widget.settings.themeMode),
        // Above the navigator, so the shift nudge is read on whatever screen the
        // cashier is on and takes its own strip of the till rather than covering
        // one. Nothing else belongs here: this is the app's only chrome.
        builder: (context, navigator) {
          final nudge = _nudge;
          if (nudge == null || navigator == null) {
            return navigator ?? const SizedBox.shrink();
          }
          return Column(children: [
            _shiftNudgeBar(context, nudge),
            Expanded(child: navigator),
          ]);
        },
        locale: locale,
        supportedLocales: kSupportedLocales,
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: widget.config.displayMode
            ? _displayOnly()
            : widget.config.kdsMode
                ? _kitchenOnly()
                : session == null
                    ? LoginScreen(
                        auth: widget.auth,
                        users: widget.users,
                        onSignedIn: _signedIn,
                        provisioningPin: widget.provisioningPin,
                      )
                    : _selling(session),
      ),
    );
  }

  /// A device that is a customer-facing display and nothing else.
  ///
  /// A device mode exactly like the kitchen board, and for the same reasons: no
  /// sign-in, no shift, nothing it can be typed into, and every line on it arrived
  /// over the shop LAN from the till at the counter. It holds no session and no
  /// outbox, so a screen facing the queue cannot ring anything up, and a display
  /// that loses the network shows its idle panel rather than the last customer's
  /// shopping.
  Widget _displayOnly() => Builder(
        // Builder, so the settings route targets the Navigator inside this MaterialApp.
        builder: (context) => CustomerDisplayScreen(
          board: LanCartBoard(widget.settings),
          formatAmount: PosApp.money,
          shopName: widget.settings.shopName ?? widget.config.shopName,
          tills: [for (final p in widget.lan?.peers.all ?? const []) p.deviceId],
          nameFor: (id) {
            for (final p in widget.lan?.peers.all ?? const []) {
              if (p.deviceId == id) return p.name;
            }
            return id;
          },
          actions: [
            IconButton(
              key: const Key('display-network'),
              // Ungated for the same reason the kitchen board's door is: this device
              // has no roster, so a manager PIN here would be a lock with no key.
              onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
                  builder: (_) => _lanScreen(() => setState(() {})))),
              icon: const Icon(Icons.lan_outlined, size: 18),
              tooltip: tr(context, 'Shop network'),
            ),
          ],
        ),
      );

  /// A device that is a kitchen screen and nothing else.
  ///
  /// No sign-in and no open shift, because a cook takes no money: a board bolted to
  /// a wall behind a cashier's PIN is a board nobody uses. Every ticket on it arrived
  /// over the fabric, and a bump leaves the same way, as a status event rather than a
  /// claim on somebody else's sale, so this device can neither ring up nor report nor
  /// push anything. The printed kitchen ticket is untouched by this and stays the
  /// answer for a kitchen with no screen.
  Widget _kitchenOnly() => Builder(
        // Builder, so the settings route targets the Navigator inside this MaterialApp.
        builder: (context) => KitchenDisplayScreen(
          load: () => widget.orders.kitchenTickets(),
          onStatus: (uuid, status) => widget.orders.setKitchenStatus(uuid, status),
          actions: [
            IconButton(
              key: const Key('kds-network'),
              // Ungated, unlike the same screen on a till: a kitchen screen has no
              // roster and never sees the sign-in screen, so a manager PIN here would
              // be a lock with no key. There is nothing behind it to take either: a
              // device id, a name and who else is on the LAN.
              onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
                  builder: (_) => _lanScreen(() => setState(() {})))),
              icon: const Icon(Icons.lan_outlined),
              tooltip: tr(context, 'Shop network'),
            ),
          ],
        ),
      );

  /// Customers the till never pulled, asked for while the cashier types in the
  /// picker. The catalogue pull is bounded at 500 partners, which a shop with a
  /// real customer book outgrows; this reaches the rest through the same read-only
  /// call_kw the catalogue uses.
  ///
  /// Everything about it degrades to nothing: an offline till never asks, a server
  /// that errors or times out answers with an empty list, and the picker is already
  /// full of local results either way. It is never on the way to a payment.
  Future<List<Customer>> _searchServerCustomers(String term) async {
    if (!widget.sync.online.value) return const [];
    try {
      final found =
          await OdooPuller(call: widget.odoo.catalogueCall).searchCustomers(term);
      // Kept, so a partner found once is pickable again with the line down.
      widget.catalogue.mergeCustomers(found);
      return found;
    } catch (_) {
      return const [];
    }
  }

  Widget _selling(PosSession session) => Stack(
        fit: StackFit.expand,
        children: [
          Builder(
            // Builder, so navigation targets the Navigator inside this MaterialApp.
            builder: (context) => SellScreen(
              session: session,
              formatAmount: PosApp.money,
              staleness: widget.catalogue.stalenessAt(DateTime.now().toUtc()),
              catalogueChanged: widget.sync.catalogueRevision,
              // No per-sale push: orders are held and sent as one batch at shift
              // close, so the shared Odoo login is not hit per order.
              online: widget.sync.online,
              pendingToSync: () => widget.sync.pendingSales,
              // Tickets and receipts a printer would not take. They flush themselves,
              // but until they do the kitchen has not seen them.
              spooledJobs: () => _receiptPrinter.spooledCount,
              categoryColors: widget.settings.categoryColors,
              // Read only when the shop shows them, and answered from a map the
              // catalogue holds: no picture is fetched while a tile is being built.
              productImages: widget.settings.showProductImages
                  ? widget.catalogue.images()
                  : const {},
              quickComments: widget.settings.quickComments,
              discountReasons: widget.settings.discountReasons,
              discountPercents: widget.settings.discountPercents,
              maxDiscountPercent: widget.settings.maxDiscountPercent,
              allowAmountDiscount: widget.settings.allowAmountDiscount,
              authorize: (p) => _authorize(p, context),
              unavailableProducts: widget.settings.unavailableProducts,
              onToggleAvailable: (id, available) {
                widget.settings.setProductAvailable(id, available);
                widget.audit.record(session.cashierId,
                    available ? 'product.available' : 'product.sold_out', detail: '$id');
                setState(() {});
              },
              favourites: widget.settings.favourites,
              onToggleFavourite: (id, fav) {
                widget.settings.setFavourite(id, fav);
                setState(() {});
              },
              gridColumns: widget.settings.gridColumns,
              extraCustomers: (q) => widget.customers.search(query: q, limit: 30),
              // A customer captured mid-order is kept on the till like any other, so
              // the next order can pick them instead of retyping them.
              onAddCustomer: ({required name, phone, address}) =>
                  widget.customers.add(name: name, phone: phone, address: address),
              // A shop with more partners than the catalogue pull carries can find
              // the rest while the line is up. Off the payment path, and silent
              // when there is no line: the picker keeps answering from disk.
              searchServerCustomers: _searchServerCustomers,
              // The delivery lists, read live so an edit in settings shows on the
              // next order without a restart.
              deliveryZones: widget.delivery == null ? null : () => widget.delivery!.zones(),
              deliveryChannels:
                  widget.delivery == null ? null : () => widget.delivery!.channels(),
              drivers: widget.delivery == null
                  ? null
                  : () => widget.delivery!.drivers(activeOnly: true),
              // What this cashier's role may open. Read per build, so a manager
              // narrowing it takes effect on the next order rather than at restart.
              allowedOrderTypes: _allowedOrderTypes,
              // The tender an on-account sale books against, when the shop runs
              // accounts. Absent, the payment sheet offers no such thing.
              payLaterMethodId: widget.settings.payLaterMethodId,
              // Dividers are floor decoration, never a table an order sits at.
              tables: () => widget.tables
                  .all()
                  .where((t) => !t.isDivider)
                  .map((t) => t.name)
                  .toList(),
              heldOrders: () => widget.orders.held(),
              // Seat a dine-in (or move a bill) on the real floor plan, not a flat
              // list, so choosing a table looks like the floor the manager drew.
              onPickTable: ({exclude}) =>
                  _pickTableFromFloor(context, session, exclude: exclude),
              // New order returns to the floor home to choose a table or the
              // takeaway/delivery buttons.
              onNewOrder: () => _openFloor(context, session),
              onChanged: _publishActivity,
              onSignOut: _signOut,
              drawer: _buildDrawer(context, session),
              onOpenOrders: () => _openOrders(context, session),
              // The table asked for the bill. Paper only: nothing is settled, nothing
              // is pushed, and the order stays exactly as it is.
              onPrintBill: (order) => unawaited(_printBill(order)),
              onHold: () {
                // Holding only parks the order. It does NOT fire the kitchen: food
                // reaches the kitchen only via the explicit Send to kitchen button,
                // so a cashier can park a tab that is still being built without the
                // line cooking it.
                session.hold();
                _publishActivity();
              },
              // Fire the kitchen ticket but keep the order on the counter. The
              // result is handed back so the screen can say what really happened.
              onSendToKitchen: () => _fireKitchen(session.current),
              // Re-fire every line (a lost or re-requested ticket), ignoring the
              // already-printed flag.
              onResendToKitchen: () =>
                  _fireKitchen(session.current, only: session.current.lines, resend: true),
              onLineVoided: (line, reason) {
                // The deletion slip is the till's own record that an item was taken
                // off, printed for every void. The kitchen cancel slip only fires
                // when the kitchen already has a copy, or it would send a cancel for
                // food that was never ordered to the pass.
                if (line.printedToKitchen || line.firedStations.isNotEmpty) {
                  unawaited(_fireVoid(session.current, line, reason));
                }
                // Only while this order is being corrected, so the set stays the
                // size of one amendment rather than a shift's worth of voids.
                if (_amending.containsKey(session.current.uuid)) {
                  _slipped.add(line.uuid);
                }
                unawaited(_printDeletion(session.current, [line],
                    title: 'ITEM VOIDED', reason: reason));
              },
              onPaid: (order) {
                _publishActivity();
                final sale = order as Order;
                // A straight counter sale never held, so its lines reach the
                // kitchen here; a dine-in order already fired on hold and reprints
                // nothing. Only lines the kitchen has never seen are fired, which
                // is also what keeps a corrected sale from cooking its food twice.
                // The sale is NOT pushed to Odoo now: it waits on the till for the
                // shift-close batch.
                _slipRemovedOnAmend(sale);
                unawaited(_fireKitchen(sale).then((_) => _printReceipt(sale)));
              },
            ),
          ),
          // One coach at a time, and setting the till up comes before the first
          // sale: two scrims over each other is a cashier with no way out.
          if (_firstSignInHelp)
            // Builder, so the panels are written in the language the app is in.
            Builder(
              builder: (context) => WizardOverlay(
                steps: _firstSignInSteps(context, _setupChecklist()),
                onClosed: (outcome) =>
                    _closeFirstSignInHelp(outcome, session.cashierId),
              ),
            )
          else if (_firstSaleHelp)
            WizardOverlay(
              steps: _firstSaleSteps,
              onClosed: (outcome) =>
                  _closeFirstSaleHelp(outcome, session.cashierId),
            ),
        ],
      );

  /// The app shell's navigation. Selling stays on the main screen; everything a
  /// cashier or manager reaches occasionally lives here so the sell screen is not
  /// buried under buttons.
  Widget _buildDrawer(BuildContext rootContext, PosSession session) {
    final isManager = widget.auth.signedIn?.isManager ?? false;
    return Drawer(
      child: SafeArea(
        child: ListView(children: [
          const DrawerHeader(
            child: Center(
              child: Text('offlinePOS',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
            ),
          ),
          ListTile(
            key: const Key('nav-tables'),
            leading: const Icon(Icons.table_bar),
            title: Text(tr(rootContext, 'Tables')),
            onTap: () {
              Navigator.pop(rootContext);
              _openFloor(rootContext, session);
            },
          ),
          ListTile(
            key: const Key('nav-open-orders'),
            leading: const Icon(Icons.table_restaurant),
            title: Text(tr(rootContext, 'Open orders')),
            trailing: session.heldCount > 0 ? Chip(label: Text('${session.heldCount}')) : null,
            onTap: () {
              Navigator.pop(rootContext);
              _openOrders(rootContext, session);
            },
          ),
          ListTile(
            key: const Key('nav-history'),
            leading: const Icon(Icons.receipt_long),
            title: Text(tr(rootContext, 'Order history')),
            onTap: () {
              Navigator.pop(rootContext);
              _openHistory(rootContext);
            },
          ),
          ListTile(
            key: const Key('nav-kitchen'),
            leading: const Icon(Icons.soup_kitchen),
            title: Text(tr(rootContext, 'Kitchen display')),
            onTap: () {
              Navigator.pop(rootContext);
              _openKitchen(rootContext);
            },
          ),
          ListTile(
            key: const Key('nav-report'),
            leading: const Icon(Icons.bar_chart),
            title: Text(tr(rootContext, 'Reports')),
            onTap: () async {
              Navigator.pop(rootContext);
              if (await _authorize(Permission.viewReports, rootContext)) {
                if (rootContext.mounted) _openReports(rootContext);
              }
            },
          ),
          ListTile(
            key: const Key('nav-shift'),
            leading: const Icon(Icons.point_of_sale),
            title: Text(tr(rootContext, 'Shift / cash-up')),
            onTap: () {
              Navigator.pop(rootContext);
              _openShift(rootContext, session);
            },
          ),
          ListTile(
            key: const Key('nav-attendance'),
            leading: const Icon(Icons.how_to_reg_outlined),
            title: Text(tr(rootContext, 'Attendance')),
            onTap: () {
              Navigator.pop(rootContext);
              _openAttendance(rootContext);
            },
          ),
          ListTile(
            key: const Key('nav-nosale'),
            leading: const Icon(Icons.money_off),
            title: Text(tr(rootContext, 'No sale (open drawer)')),
            onTap: () {
              Navigator.pop(rootContext);
              unawaited(_openDrawerNoSale(rootContext));
            },
          ),
          const Divider(),
          if (isManager)
            ListTile(
              key: const Key('nav-staff'),
              leading: const Icon(Icons.badge_outlined),
              title: Text(tr(rootContext, 'Staff')),
              onTap: () {
                Navigator.pop(rootContext);
                _openRoster(rootContext);
              },
            ),
          if (isManager)
            ListTile(
              key: const Key('nav-audit'),
              leading: const Icon(Icons.fact_check_outlined),
              title: Text(tr(rootContext, 'Audit log')),
              onTap: () {
                Navigator.pop(rootContext);
                Navigator.of(rootContext).push(MaterialPageRoute<void>(
                  builder: (_) => AuditLogScreen(audit: widget.audit),
                ));
              },
            ),
          ListTile(
            key: const Key('nav-settings'),
            leading: const Icon(Icons.settings),
            title: Text(tr(rootContext, 'Settings')),
            onTap: () {
              Navigator.pop(rootContext);
              _openSettingsHub(rootContext);
            },
          ),
          ListTile(
            key: const Key('nav-support'),
            leading: const Icon(Icons.support_agent),
            title: Text(tr(rootContext, 'Support & printers')),
            onTap: () {
              Navigator.pop(rootContext);
              _openDiagnostics(rootContext);
            },
          ),
        ]),
      ),
    );
  }

  /// A required free-text reason, for discarding a tab the kitchen has started.
  /// Returns null if the manager backs out (which aborts the cancel).
  Future<String?> _promptReason(BuildContext context, String title) {
    final ctrl = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          key: const Key('cancel-reason'),
          controller: ctrl,
          autofocus: true,
          decoration: InputDecoration(
              labelText: tr(ctx, 'Reason'), border: const OutlineInputBorder()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr(ctx, 'Cancel'))),
          FilledButton(
            key: const Key('cancel-reason-ok'),
            onPressed: () {
              final r = ctrl.text.trim();
              if (r.isNotEmpty) Navigator.pop(ctx, r);
            },
            child: Text(tr(ctx, 'Confirm')),
          ),
        ],
      ),
    );
  }

  void _openAttendance(BuildContext context) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => AttendanceScreen(users: widget.users, attendance: widget.attendance),
    ));
  }

  void _openOrders(BuildContext context, PosSession session) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (sheetContext) => OpenOrdersScreen(
        orders: widget.orders.held(),
        formatAmount: PosApp.money,
        // Through the same door as the floor, so table security cannot be walked
        // around by resuming the tab from the list instead of the plan. The list
        // closes itself on the tap, so the question about whose tab it is is asked
        // on the screen underneath, one microtask later.
        onRecall: (order) => scheduleMicrotask(() {
          final below = _navigator.currentContext;
          if (below != null) {
            unawaited(_resumeTab(below, session, order, closeAfter: false));
          }
        }),
        // A parked tab's bill prints without recalling it, so the list stays put.
        onPrintBill: (order) => unawaited(_printBill(order)),
        // Discarding a parked order is money not taken, so it is manager-gated and
        // audited, then the list is popped so the change is visible.
        onCancel: (order) async {
          if (!await _authorize(Permission.cancelOrder, sheetContext)) return;
          // Any line the kitchen holds, even partially fired to one of several
          // stations, means food is already cooking.
          final firedLines = order.lines
              .where((l) => l.printedToKitchen || l.firedStations.isNotEmpty)
              .toList();
          // Discarding a tab the kitchen has started demands a reason: it prints on
          // the cancel slip and lands in the audit, and abandoning the prompt aborts
          // the cancel so food that is cooking is never dropped without a record.
          var reason = 'Order cancelled';
          if (firedLines.isNotEmpty) {
            if (!sheetContext.mounted) return;
            final given = await _promptReason(sheetContext, tr(sheetContext, 'Cancel order'));
            if (given == null) return;
            reason = given;
          }
          // Tell each station that holds the line to stop, so cancelling a sent
          // order does not leave food cooking.
          for (final line in firedLines) {
            unawaited(_fireVoid(order, line, reason));
          }
          // The till's own record that the whole order was discarded, listing every
          // line and the total removed, printed alongside the audit entry.
          unawaited(_printDeletion(order, order.lines,
              title: 'ORDER CANCELLED', reason: reason));
          widget.orders.delete(order.uuid);
          // Nothing left to correct, so the snapshot taken when it was reopened
          // has no second payment coming to consume it.
          _amending.remove(order.uuid);
          widget.audit.record(session.cashierId, 'order.cancelled',
              detail: '${order.uuid}|$reason');
          if (sheetContext.mounted) Navigator.of(sheetContext).pop();
          setState(() {});
        },
      ),
    ));
  }

  void _openHistory(BuildContext context) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (historyContext) => OrderHistoryScreen(
        orders: widget.orders.recent(limit: 1000),
        formatAmount: PosApp.money,
        onReprint: (order) async {
          // Reprinting a receipt is a permissioned action: a cashier without it
          // needs a manager to approve, or the toggle would be cosmetic.
          if (!await _authorize(Permission.reprint, context)) return;
          await _printReceipt(order, reprint: true);
        },
        onRefund: (order) => _openRefund(context, order),
        // Only offered while a session is selling: a correction lands in the cart,
        // and there is no cart with nobody signed in.
        onEdit: _session == null
            ? null
            : (order) => _amendOrder(historyContext, order),
      ),
    ));
  }

  /// Put a paid sale back on the counter to be corrected, and land the cashier on
  /// it. The daily "rang it wrong" and "they added one more thing" flow, which
  /// otherwise costs a refund and a full re-ring.
  ///
  /// The store decides whether the sale may be reopened at all and takes its queued
  /// push back out of the outbox in the same transaction; a refusal here is that
  /// answer, told plainly rather than as a dead button.
  Future<void> _amendOrder(BuildContext context, Order order) async {
    final session = _session;
    if (session == null) return;
    if (!await _authorize(Permission.amendOrder, context)) return;
    // What the customer was charged before the correction, read before anything
    // moves, for the audit trail and for the removal slip at the second payment.
    final oldTotal = order.total;
    final before = List<OrderLine>.of(order.lines);
    final reopened = widget.orders.reopen(
      order.uuid,
      // A batch push owns the queue while it runs, and its entries are already read
      // out of the table, so withdrawing one there would take back a sale that is
      // on its way to being booked. Refuse instead: the answer a moment later is a
      // refund, which is right and reversible, rather than a silent divergence.
      withdrawPush: (uuid) =>
          widget.sync.state != SyncState.working &&
          widget.outboxStore.withdrawPending('order.push', uuid),
    );
    if (!reopened) {
      if (context.mounted) {
        showToast(
            context,
            tr(context,
                'This sale can no longer be edited here. Refund it and ring it again.'),
            kind: ToastKind.error);
      }
      return;
    }
    widget.audit.record(session.cashierId, 'order.amended',
        detail: '${order.uuid}|${PosApp.money(oldTotal)}');
    _amending[order.uuid] = before;
    session.recall(order.uuid);
    _publishActivity();
    // Back to the sell screen, past the detail and the history list, so the
    // reopened order is on the counter rather than behind two screens.
    if (context.mounted) Navigator.of(context).popUntil((r) => r.isFirst);
    if (mounted) setState(() {});
  }

  /// Refund a past sale: pick the lines, then record, queue and print the reversal.
  Future<void> _openRefund(BuildContext context, Order original) async {
    // A refund returns money, so it needs the refund permission before the flow opens.
    if (!await _authorize(Permission.refund, context)) return;
    if (!context.mounted) return;
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => RefundScreen(
        original: original,
        formatAmount: PosApp.money,
        // Book the money-out against the cashier and till actually processing it.
        actingCashierId: _session?.cashierId ?? original.cashierId,
        deviceId: widget.deviceId,
        onRefund: (refund) {
          // A refund is a durable order like a sale: saved, queued to sync, audited,
          // and a slip printed for the customer.
          widget.orders.save(refund);
          widget.outbox.enqueue('order.push', refund.uuid, refund.toServerPayload());
          widget.audit.record(refund.cashierId, 'order.refunded',
              detail: '${refund.uuid} of ${original.uuid}');
          unawaited(_printReceipt(refund));
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                content: Text('${'Refund recorded: '}${PosApp.money(refund.total.abs())}')));
          }
        },
      ),
    ));
    if (mounted) setState(() {});
  }

  /// The reports hub, with a date-range filter over the recent completed sales.
  void _openReports(BuildContext context) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => ReportsHubScreen(
        allOrders: widget.orders.recent(limit: 1000),
        categories: widget.catalogue.categories(),
        formatAmount: PosApp.money,
        audit: widget.audit,
        // One read of a column no selling query touches, so the margin reports have
        // something to compare the takings against.
        costs: widget.catalogue.costsById(),
        // Paid-outs live inside shifts, so the expenses report reads them itself.
        shifts: widget.shifts,
        // Clock-ins, and who the ids belong to, for the hours report.
        attendance: widget.attendance,
        staffNames: {for (final u in widget.users.all()) u.id: u.name},
        openTables: widget.orders
            .heldAnywhere()
            .where((o) => o.tableLabel != null)
            .length,
        onPrint: _printShiftReport,
      ),
    ));
  }

  void _openKitchen(BuildContext context) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => KitchenDisplayScreen(
        load: () => widget.orders.kitchenTickets(),
        onStatus: (uuid, status) => widget.orders.setKitchenStatus(uuid, status),
      ),
    ));
  }

  void _openRoster(BuildContext context) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => RosterScreen(
        users: widget.users,
        auth: widget.auth,
        onChanged: () => setState(() {}),
        // Cashier plus whatever roles the shop invented, so a new starter can be
        // put straight onto one instead of being a cashier with a manager stood
        // behind them.
        roles: widget.settings.assignableRoles,
        // Only a signed-in manager may mint or edit manager accounts. A cashier who
        // reaches here via the manageStaff permission can manage cashiers only, so
        // the manager role stays out of reach and self-promotion is impossible.
        canAssignManager: widget.auth.signedIn?.isManager ?? false,
      ),
    ));
  }

  /// The floor plan. Tapping a table recalls the order parked on it, or starts a
  /// fresh dine-in seated at it, then drops back to the sell screen.
  /// Which tables read as occupied right now, and their running total + age, from
  /// the held orders plus the one on screen. Shared by the floor plan and the table
  /// picker so both colour tables identically.
  ({Set<String> occupied, Map<String, ({double total, DateTime since})> info})
      _floorOccupancy(PosSession session) {
    // Every parked order in the shop, not just this till's. A table busy on the bar
    // till has to read as busy here, or two cashiers seat the same table and the
    // second guest's food goes to a bill nobody is holding.
    final held = widget.orders.heldAnywhere();
    final occupied = held.map((o) => o.tableLabel).whereType<String>().toSet();
    final info = <String, ({double total, DateTime since})>{
      for (final o in held)
        if (o.tableLabel != null) o.tableLabel!: (total: o.total, since: o.createdAt),
    };
    // The order on screen (not yet held) also occupies its table, or opening the
    // floor and tapping it would start a second order on the same table.
    final active = session.current;
    if (active.lines.isNotEmpty && active.tableLabel != null) {
      occupied.add(active.tableLabel!);
      info[active.tableLabel!] = (total: active.total, since: active.createdAt);
    }
    return (occupied: occupied, info: info);
  }

  /// Choose a table on the same drawn floor plan the manager laid out, with the
  /// section tabs and occupancy colours, and return the chosen name. Used by the
  /// sell screen for seating a dine-in and for moving a bill to another table.
  Future<String?> _pickTableFromFloor(BuildContext context, PosSession session,
      {String? exclude}) {
    final occ = _floorOccupancy(session);
    return Navigator.of(context).push(MaterialPageRoute<String>(
      builder: (routeContext) => TableFloorScreen(
        store: widget.tables,
        pickMode: true,
        exclude: exclude,
        occupiedLabels: occ.occupied,
        occupiedInfo: occ.info,
        formatAmount: PosApp.money,
        onOpenTable: (t) => Navigator.of(routeContext).pop(t.name),
      ),
    ));
  }

  /// Resume one of the parked deliveries, start a new one, or back out.
  ///
  /// Returns the [Order] to pick up, null to ring a new one, or 'cancel' when the
  /// cashier dismissed the sheet: backing out must not silently start an order.
  Future<Object?> _pickParkedDelivery(BuildContext context, List<Order> parked) =>
      showModalBottomSheet<Object?>(
        context: context,
        builder: (ctx) => SafeArea(
          child: ListView(shrinkWrap: true, children: [
            ListTile(
              title: Text(tr(ctx, 'Deliveries waiting'),
                  style: const TextStyle(fontWeight: FontWeight.bold)),
              subtitle: Text(tr(ctx, 'Pick one up, or start a new order.')),
            ),
            for (final o in parked)
              ListTile(
                key: Key('resume-delivery-${o.uuid}'),
                leading: const Icon(Icons.delivery_dining),
                title: Text(o.customerName ?? '#${o.displayNo}'),
                subtitle: Text([
                  if (o.customerPhone != null) o.customerPhone!,
                  if (o.deliveryChannel != null) o.deliveryChannel!,
                  PosApp.money(o.total),
                ].join('  ·  ')),
                onTap: () => Navigator.pop(ctx, o),
              ),
            ListTile(
              key: const Key('new-delivery'),
              leading: const Icon(Icons.add),
              title: Text(tr(ctx, 'New delivery')),
              onTap: () => Navigator.pop(ctx, 'new'),
            ),
          ]),
        ),
      ).then((v) => v ?? 'cancel');
  /// The kinds of sale the signed-in role may open. Unrestricted until a manager
  /// says otherwise, and a manager themselves is never restricted.
  Set<OrderType> get _allowedOrderTypes =>
      widget.settings.orderTypesFor(widget.auth.signedIn?.role ?? 'cashier');

  void _openFloor(BuildContext context, PosSession session) {
    final occ = _floorOccupancy(session);
    final occupied = occ.occupied;
    final allowed = _allowedOrderTypes;
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (floorContext) => TableFloorScreen(
        // Read as the floor is built, so a close that arrives over the fabric shows
        // the next time a waiter looks at the plan rather than at the next restart.
        dayNotice: _dayCloseNotice(floorContext)?.text,
        blockNewOrders: _dayCloseNotice(floorContext)?.blocking ?? false,
        store: widget.tables,
        occupiedLabels: occupied,
        occupiedInfo: occ.info,
        formatAmount: PosApp.money,
        // The floor's own rules, on the screen a manager already opens to lay the
        // room out.
        settings: widget.settings,
        onTransferTables: () => unawaited(_transferTables(floorContext)),
        authorize: () => _authorize(Permission.openSettings, floorContext),
        // The book, so a table with guests due shortly says so on the plan.
        reservations: widget.reservations,
        // The two table-less ways to start an order, straight from the floor home.
        // Each starts a fresh order of that type and drops to the order screen. A
        // type this role may not ring has no button rather than a button that
        // refuses.
        onTakeaway: !allowed.contains(OrderType.takeaway)
            ? null
            : () {
                setState(() => session.startFresh(OrderType.takeaway));
                Navigator.of(floorContext).pop();
              },
        onDelivery: !allowed.contains(OrderType.delivery)
            ? null
            : () async {
                // A delivery has no table to tap, so a parked one is only reachable
                // through Open orders: a cashier taking the next call has no way of
                // knowing they are about to start a second order for a bag already
                // waiting. Ask, but only when there is something to resume.
                final parked = widget.orders
                    .held()
                    .where((o) => o.type == OrderType.delivery)
                    .toList();
                final resume = parked.isEmpty
                    ? null
                    : await _pickParkedDelivery(floorContext, parked);
                if (resume == 'cancel') return;
                setState(() {
                  if (resume is Order) {
                    session.recall(resume.uuid);
                  } else {
                    session.startFresh(OrderType.delivery);
                  }
                });
                if (floorContext.mounted) Navigator.of(floorContext).pop();
              },
        onOpenTable: (t) async {
          // Tapping the table the current order is already seated at just returns
          // to it rather than parking it and starting a duplicate.
          if (session.current.tableLabel == t.name &&
              session.current.lines.isNotEmpty) {
            Navigator.of(floorContext).pop();
            return;
          }
          final held =
              widget.orders.held().where((o) => o.tableLabel == t.name).toList();
          if (held.isEmpty) {
            // Parked on another till. Neither start a second order on the table nor
            // recall theirs: a tab is settled where it was opened, because that till
            // is the one that books it.
            final elsewhere = widget.orders
                .heldElsewhere()
                .where((o) => o.tableLabel == t.name)
                .toList();
            if (elsewhere.isNotEmpty) {
              // Unless the shop runs handhelds and has said a tab may change
              // hands, in which case the other till is asked and has to agree.
              if (widget.lan != null && widget.settings.lanAllowTakeover) {
                unawaited(_takeOverTab(floorContext, session, elsewhere.first));
                return;
              }
              ScaffoldMessenger.of(floorContext).showSnackBar(SnackBar(
                content: Text(tr(floorContext,
                    'This table is open on another device. Settle it there.')),
              ));
              return;
            }
            // Seating a table opens a dine-in, so a role that does not ring them is
            // told plainly instead of landing on a sale it may not have started.
            // Recalling a tab that is already open is untouched by this: settling
            // somebody else's table is not opening one.
            if (!allowed.contains(OrderType.dineIn)) {
              ScaffoldMessenger.of(floorContext).showSnackBar(SnackBar(
                content: Text(
                    tr(floorContext, 'This role does not open dine-in orders.')),
              ));
              return;
            }
          }
          // How many are sitting down, when the shop asks. Before the order is
          // started, so backing out of the prompt leaves no half-seated table
          // behind, and only when a table is actually being seated: recalling a
          // tab already has its covers.
          if (held.isNotEmpty) {
            // Whose tab it is may need answering first; the rest of the tap waits
            // for that answer rather than opening the bill behind it. Before the
            // guest prompt, so resuming never sits behind an await it does not need.
            unawaited(_resumeTab(floorContext, session, held.first));
            return;
          }
          int? covers;
          if (widget.settings.askGuestCount) {
            covers = await _askGuestCount(floorContext, t.seats);
            if (covers == null) return;
          }
          setState(() {
            session.startFresh(OrderType.dineIn);
            session.setTable(t.name);
            // The prompt's answer when there was one, otherwise the table's own
            // seat count, which is what the floor has always seeded. A tab that was
            // already open never reaches here: the resume path above took it.
            final seated = covers ?? t.seats;
            if (seated > 0) session.setGuestCount(seated);
          });
          if (floorContext.mounted) Navigator.of(floorContext).pop();
        },
      ),
    ));
  }

  // ── the shop's trading day, across devices ───────────────────────

  /// Tell the other devices this till has closed the day.
  ///
  /// Best effort and never in the way: the shift is already closed and the drawer
  /// already counted when this runs, so a fabric that is off, a switch that is out
  /// or a peer that is asleep changes nothing about the cash-up.
  void _announceDayClose(PosSession session) => widget.lan?.announceDayClose(
        businessDate: BusinessDay.of(DateTime.now().toUtc()).key,
        cashierId: session.cashierId,
      );

  /// What another till has said about today, and whether this one should stop
  /// starting new work over it.
  ///
  /// Null unless all of it is true: this device is on the fabric, the shop asked for
  /// the coordination, another till has closed THIS trading day, and this one still
  /// has a shift open. A device that hears nothing degrades to exactly the behaviour
  /// it had before any of this existed, which is the rule the whole feature is bound
  /// by: the shop must not stop trading because a switch died.
  ({String text, bool blocking})? _dayCloseNotice(BuildContext context) {
    if (widget.lan == null) return null;
    final board = LanShiftBoard(widget.settings);
    final policy = board.policy;
    if (policy == LanDayClosePolicy.off) return null;
    if (widget.shifts.currentOpenShift() == null) return null;
    final notice = board.closedOn(BusinessDay.of(DateTime.now().toUtc()).key);
    if (notice == null) return null;
    final blocking = policy == LanDayClosePolicy.block;
    return (
      text: '${tr(context, 'The day was closed on')} ${notice.deviceName}. '
          '${tr(context, blocking ? 'New orders are held until this till is closed too.' : 'Close this till too.')}',
      blocking: blocking,
    );
  }

  /// Bring a parked tab back to the counter, asking whose it is first when the shop
  /// has said tabs belong to the cashier who opened them.
  ///
  /// One door for every way a tab is resumed, so the answer cannot be walked around
  /// by opening it from the other screen.
  /// [closeAfter] is false when the screen that asked has already closed itself.
  Future<void> _resumeTab(BuildContext context, PosSession session, Order tab,
      {bool closeAfter = true}) async {
    if (!await _authorizeTab(context, tab)) return;
    setState(() => session.recall(tab.uuid));
    _publishActivity();
    if (closeAfter && context.mounted) Navigator.of(context).pop();
  }

  /// Whether the cashier on the till may open [tab].
  ///
  /// Free unless the shop asked for table security, and free on your own tab either
  /// way: the prompt exists for the till several people share, where each answers
  /// for their own takings, and it would be friction for nothing anywhere else. The
  /// cashier who opened it can unlock it without signing in, and a manager can
  /// override; both outcomes are audited, because a tab opened by somebody else is
  /// exactly the thing that has to be explainable afterwards.
  Future<bool> _authorizeTab(BuildContext context, Order tab) async {
    if (!widget.settings.tableSecurity) return true;
    final who = _session?.cashierId;
    if (who == null || tab.cashierId == who) return true;
    final owner = widget.users.byId(tab.cashierId);
    final pin = await _promptPin(
      context,
      tr(context, 'This tab belongs to another cashier'),
      tr(context, 'Enter their PIN, or a manager PIN.'),
      subject: owner?.name ?? tab.cashierId,
    );
    if (pin == null || pin.isEmpty) return false;
    final ok = await widget.auth.authorizeCashier(tab.cashierId, pin) ||
        await widget.auth.authorizeManager(pin);
    widget.audit.record(who, ok ? 'order.unlocked' : 'order.locked',
        detail: '${tab.uuid}|${tab.cashierId}');
    if (!ok && context.mounted) {
      showToast(context, tr(context, 'That PIN did not open this tab'),
          kind: ToastKind.error);
    }
    return ok;
  }

  /// A PIN, asked for on behalf of somebody in particular. The manager dialog asks
  /// the same question of whoever is standing there; this one names the person it
  /// expects, because a cashier being asked for "a PIN" with no name on it does not
  /// know whose is wanted.
  Future<String?> _promptPin(BuildContext context, String title, String message,
      {required String subject}) {
    final ctrl = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          Text('$subject. $message'),
          const SizedBox(height: 12),
          TextField(
            key: const Key('tab-pin'),
            controller: ctrl,
            autofocus: true,
            obscureText: true,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
                labelText: tr(ctx, 'PIN'), border: const OutlineInputBorder()),
          ),
        ]),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: Text(tr(ctx, 'Cancel'))),
          FilledButton(
            key: const Key('tab-pin-ok'),
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: Text(tr(ctx, 'Open tab')),
          ),
        ],
      ),
    );
  }

  /// Move every tab one cashier is holding to another one.
  ///
  /// The end of a waiter's shift with four tables still sitting: without this the
  /// tabs stay locked to somebody who has gone home and land on their flash. Only
  /// parked tabs move, never a paid sale, so who took the money is never rewritten.
  Future<void> _transferTables(BuildContext context) async {
    if (!await _authorizeManager(context)) return;
    final held = widget.orders.held();
    final holders = held.map((o) => o.cashierId).toSet().toList()..sort();
    if (!context.mounted) return;
    if (holders.isEmpty) {
      showToast(context, tr(context, 'No tabs are open on this till'));
      return;
    }
    final from = await _pickCashier(
        context, tr(context, 'Move tabs from'), holders);
    if (from == null || !context.mounted) return;
    final to = await _pickCashier(
      context,
      tr(context, 'Move tabs to'),
      widget.users.active().map((u) => u.id).where((id) => id != from).toList(),
    );
    if (to == null) return;
    final moved = held.where((o) => o.cashierId == from).toList();
    for (final tab in moved) {
      widget.orders.reassignCashier(tab.uuid, to);
    }
    widget.audit.record(_session?.cashierId ?? 'system', 'tables.transferred',
        detail: '$from->$to|${moved.length} tab(s)');
    if (!context.mounted) return;
    setState(() {});
    showToast(context, '${tr(context, 'Tabs moved')}: ${moved.length}',
        kind: ToastKind.success);
  }

  /// Pick one of the staff on this till by name, for the transfer.
  Future<String?> _pickCashier(
      BuildContext context, String title, List<String> ids) {
    final byId = {for (final u in widget.users.active()) u.id: u.name};
    return showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(title),
        children: [
          for (final id in ids)
            SimpleDialogOption(
              key: Key('transfer-$id'),
              onPressed: () => Navigator.pop(ctx, id),
              child: Text(byId[id] ?? id),
            ),
        ],
      ),
    );
  }

  /// Take a tab parked on another till, so the counter can settle what a handheld
  /// opened. Manager-gated, because it moves a bill between two sets of books.
  ///
  /// The owning till has to agree and gives the tab up as it agrees, so the tab is
  /// never open in two places. A till that cannot be reached is therefore a refusal
  /// and not a wait: it cannot let go, and taking it anyway is how one bill gets
  /// settled twice. Nothing here is on a selling path; the sale that follows is an
  /// ordinary local recall.
  Future<void> _takeOverTab(
      BuildContext context, PosSession session, Order tab) async {
    final lan = widget.lan;
    if (lan == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr(ctx, 'Take over this tab?')),
        content: Text(tr(
            ctx,
            'It is open on another device. That device is asked first and gives '
                'it up, so it cannot be settled in two places.')),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(tr(ctx, 'Cancel'))),
          FilledButton(
            key: const Key('confirm-takeover'),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr(ctx, 'Take over')),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    if (!await _authorizeManager(context)) return;
    final result = await lan.claim(tab, cashier: session.cashierId);
    if (!context.mounted) return;
    if (result.order == null) {
      showToast(
          context,
          tr(
              context,
              result.refusal == LanClaimRefusal.ownerUnreachable
                  ? 'That device did not answer, so the tab stays with it. '
                      'Settle it there.'
                  : 'That device would not hand the tab over.'),
          kind: ToastKind.error);
      return;
    }
    setState(() => session.recall(tab.uuid));
    _publishActivity();
    Navigator.of(context).pop();
  }

  /// How many are sitting at the table just tapped, offered as quick counts with
  /// the table's own seats first. Returns null when the waiter backs out, which
  /// aborts the seating rather than opening a tab nobody asked for.
  Future<int?> _askGuestCount(BuildContext context, int seats) {
    final counts = <int>{if (seats > 0) seats, 1, 2, 3, 4, 6, 8}.toList()..sort();
    return showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        key: const Key('guest-count-prompt'),
        title: Text(tr(ctx, 'How many guests?')),
        content: Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final n in counts)
              ActionChip(
                key: Key('guests-$n'),
                label: Text('$n'),
                onPressed: () => Navigator.pop(ctx, n),
              ),
          ],
        ),
        actions: [
          TextButton(
            key: const Key('guests-cancel'),
            onPressed: () => Navigator.pop(ctx),
            child: Text(tr(ctx, 'Cancel')),
          ),
        ],
      ),
    );
  }

  /// The settings hub: one door onto everything a manager configures on the device.
  void _openSettingsHub(BuildContext context) {
    void refresh() => setState(() {});
    void push(Widget screen) => Navigator.of(context)
        .push(MaterialPageRoute<void>(builder: (_) => screen));
    // Sensitive config (server credentials, printers, shop identity) is gated by the
    // matching permission so a cashier cannot repoint the till or rewrite the
    // receipt; a manager, or a role granted the permission, passes straight through.
    Future<void> pushGated(Permission p, Widget screen) async {
      if (!await _authorize(p, context)) return;
      push(screen);
    }
    final entries = <SettingsEntry>[
      SettingsEntry(
        title: _locale.isArabic ? 'Language: العربية' : 'Language: English',
        subtitle: 'Switch English / العربية',
        icon: Icons.language,
        keyValue: 'set-language',
        group: 'Language',
        // Toggling rebuilds the whole app in the other language and flips the text
        // direction; the hub is popped so the change is obvious.
        onTap: () {
          _locale.toggle();
          Navigator.of(context).pop();
        },
      ),
      SettingsEntry(
        title: 'Shop & receipt',
        subtitle: 'Name, tax id, footer',
        icon: Icons.store,
        keyValue: 'set-shop',
        group: 'Shop',
        onTap: () => pushGated(Permission.openSettings,
            ShopSettingsScreen(settings: widget.settings, onChanged: refresh)),
      ),
      SettingsEntry(
        title: 'Payment methods',
        subtitle: 'What each tender is called on the receipt',
        icon: Icons.payments,
        keyValue: 'set-payment-methods',
        group: 'Shop',
        onTap: () => pushGated(
            Permission.openSettings,
            PaymentMethodsScreen(
                settings: widget.settings,
                methods: widget.catalogue.paymentMethods(),
                onChanged: refresh)),
      ),
      SettingsEntry(
        title: 'Receipt designer',
        subtitle: 'Header, footer, what prints',
        icon: Icons.receipt_long,
        keyValue: 'set-receipt',
        group: 'Shop',
        onTap: () => pushGated(
            Permission.openSettings,
            ReceiptDesignerScreen(
                settings: widget.settings,
                onChanged: refresh,
                onUploadLogo: _uploadLogo,
                onTestPrint: () => _printReceipt(_sampleOrder(), reprint: true))),
      ),
      SettingsEntry(
        title: 'Printers & kitchen routing',
        icon: Icons.print,
        keyValue: 'set-printers',
        group: 'Hardware',
        onTap: () => pushGated(Permission.managePrinters, PrintersScreen(
            printers: widget.printers,
            settings: widget.settings,
            categories: widget.catalogue.categories(),
            products: widget.catalogue.products(),
            onChanged: refresh,
            // Send a sample receipt straight to the chosen printer so a manager can
            // prove THAT printer is wired. No receipt-printer fallback here: a test
            // must fail honestly if the named station is unreachable.
            onTestPrint: (name) async {
              final s = widget.settings;
              final bytes = ReceiptBuilder(
                shopName: s.shopName ?? widget.config.shopName,
                footer: s.receiptFooter ?? widget.config.receiptFooter,
                columns: s.receiptColumns,
                dividerStyle: s.receiptDividerStyle,
                logo: s.receiptLogoCommand(),
                formatAmount: PosApp.money,
              ).build(_sampleOrder(), reprint: true);
              await RegistryPrinter(widget.printers, name)
                  .send(Uint8List.fromList(bytes));
            })),
      ),
      SettingsEntry(
        title: 'Appearance',
        subtitle: 'Theme, pictures, category and table colours',
        icon: Icons.palette,
        keyValue: 'set-appearance',
        group: 'Shop',
        onTap: () => push(AppearanceSettingsScreen(
            settings: widget.settings,
            categories: widget.catalogue.categories(),
            onChanged: refresh)),
      ),
      SettingsEntry(
        title: 'Grid density',
        subtitle: 'Tiles per row',
        icon: Icons.grid_view,
        keyValue: 'set-grid',
        group: 'Shop',
        onTap: () async {
          final n = await showDialog<int>(
            context: context,
            builder: (dctx) => SimpleDialog(
              title: Text(tr(dctx, 'Tiles per row')),
              children: [
                for (final c in const [0, 2, 3, 4, 5, 6])
                  SimpleDialogOption(
                    onPressed: () => Navigator.pop(dctx, c),
                    child: Text(c == 0 ? tr(dctx, 'Auto (fit width)') : '$c'),
                  ),
              ],
            ),
          );
          if (n != null) {
            widget.settings.gridColumns = n;
            refresh();
          }
        },
      ),
      SettingsEntry(
        title: 'Customers',
        subtitle: 'Add / search till customers',
        icon: Icons.people_outline,
        keyValue: 'set-customers',
        group: 'People & customers',
        onTap: () => push(CustomerManagementScreen(store: widget.customers, onChanged: refresh)),
      ),
      if (widget.delivery != null)
        SettingsEntry(
          title: 'Delivery',
          subtitle: 'Zones, channels, drivers',
          icon: Icons.delivery_dining,
          keyValue: 'set-delivery',
          group: 'Shop',
          // Zone fees are what a customer is charged, so this sits behind the same
          // gate as the rest of the shop's pricing.
          onTap: () => pushGated(
              Permission.openSettings,
              DeliverySettingsScreen(
                  delivery: widget.delivery!,
                  partners: widget.catalogue.customers(limit: 500),
                  onChanged: refresh)),
        ),
      SettingsEntry(
        title: 'Quick notes',
        icon: Icons.sticky_note_2_outlined,
        keyValue: 'set-notes',
        group: 'Shop',
        onTap: () => push(QuickCommentsScreen(settings: widget.settings, onChanged: refresh)),
      ),
      SettingsEntry(
        title: 'Discounts',
        subtitle: 'Percentages, cap, reasons',
        icon: Icons.percent,
        keyValue: 'set-discounts',
        group: 'Shop',
        // The discount cap is what the apply-discount grant is bounded by, so
        // editing it must clear the same manager gate: otherwise a cashier allowed
        // to discount could raise the cap and discount without limit.
        onTap: () => pushGated(Permission.openSettings,
            DiscountSettingsScreen(settings: widget.settings, onChanged: refresh)),
      ),
      SettingsEntry(
        title: 'Tax rules',
        subtitle: 'Per category, per order type',
        icon: Icons.receipt_long_outlined,
        keyValue: 'set-tax',
        group: 'Shop',
        // Tax config changes the reported tax, so it clears the same manager gate as
        // the other shop settings.
        onTap: () => pushGated(
            Permission.openSettings,
            TaxSettingsScreen(
                settings: widget.settings,
                categories: widget.catalogue.categories(),
                onChanged: refresh)),
      ),
      SettingsEntry(
        title: 'Server (Odoo)',
        subtitle: 'Where sales sync at shift close',
        icon: Icons.dns,
        keyValue: 'set-server',
        group: 'Server',
        onTap: () async {
          final ok = await _authorize(Permission.openSettings, context);
          if (ok && context.mounted) _openSettings(context);
        },
      ),
      // Only offered on a build that has a sender: a setting whose switch does
      // nothing is worse than no setting.
      if (widget.emailer != null)
        SettingsEntry(
          title: 'Email the Z report',
          subtitle: 'Send the end-of-day figures to the owner',
          icon: Icons.mail_outline,
          keyValue: 'set-email',
          group: 'Server',
          // A mailbox password and where the day's takings are sent: the same
          // gate as the rest of the sensitive configuration.
          onTap: () => pushGated(
              Permission.openSettings,
              EmailSettingsScreen(
                  settings: widget.settings,
                  emailer: widget.emailer,
                  onChanged: refresh)),
        ),
      SettingsEntry(
        title: 'Refresh menu',
        subtitle: _menuAgeLabel(context),
        icon: Icons.sync,
        keyValue: 'set-refresh-menu',
        group: 'Server',
        // Ungated on purpose: pulling prices is a read, it books nothing, and the
        // person who notices a wrong price is whoever is at the counter.
        onTap: () => unawaited(_refreshMenuNow(context)),
      ),
      SettingsEntry(
        title: 'Shop network',
        subtitle: 'Share open tabs, tickets and the floor plan',
        icon: Icons.lan_outlined,
        keyValue: 'set-lan',
        group: 'Server',
        // Behind the same gate as the server settings: this is the one switch in the
        // app that opens a listening socket, so it is not a cashier's to flip.
        onTap: () => pushGated(Permission.openSettings, _lanScreen(refresh)),
      ),
      SettingsEntry(
        title: 'Staff',
        icon: Icons.badge_outlined,
        keyValue: 'set-staff',
        group: 'People & customers',
        onTap: () async {
          final ok = await _authorize(Permission.manageStaff, context);
          if (ok && context.mounted) _openRoster(context);
        },
      ),
      // Editing who can do what is manager-only and not delegatable: a cashier must
      // not be able to widen their own permissions, so this always asks for a manager.
      SettingsEntry(
        title: 'Roles & permissions',
        subtitle: 'What each role can do without a manager',
        icon: Icons.admin_panel_settings_outlined,
        keyValue: 'set-roles',
        group: 'People & customers',
        onTap: () async {
          final ok = await _authorizeManager(context);
          if (ok && context.mounted) {
            push(RolesPermissionsScreen(
              settings: widget.settings,
              onChanged: refresh,
              staffOnRole: (role) =>
                  widget.users.active().where((c) => c.role == role).length,
              onRoleRenamed: _moveStaffToRole,
              // A deleted role leaves its staff with no permissions at all, so
              // they land back on the role every account falls back to.
              onRoleDeleted: (role) => _moveStaffToRole(role, 'cashier'),
            ));
          }
        },
      ),
    ];
    push(SettingsHubScreen(entries: entries, header: _setupHeader(context)));
  }

  /// The setup checklist, or nothing once the till is set up.
  ///
  /// Completing it is what puts it away for good: the card is recorded as
  /// dismissed the moment every item is ticked, so removing a printer months later
  /// does not bring an onboarding card back over a working shop.
  Widget? _setupHeader(BuildContext context) {
    final who = _session?.cashierId;
    if (who == null) return null;
    final list = _setupChecklist();
    if (list.isComplete) {
      widget.wizards.dismiss(WizardId.setupChecklist, who);
      return null;
    }
    if (!widget.wizards.shouldShow(WizardId.setupChecklist, who)) return null;
    return SetupChecklistCard(
      checklist: list,
      onDismiss: () {
        widget.wizards.dismiss(WizardId.setupChecklist, who);
        // Back to the sell screen: the hub was built with the card in it, and
        // popping is how the change is seen rather than a stale list.
        Navigator.of(context).pop();
      },
    );
  }

  /// Move every account on [from] onto [to], keeping their PIN and their active
  /// flag. Called when a role is renamed or deleted, because the roster stores the
  /// role by name and an account left on a name that no longer exists reads as a
  /// role with no permissions.
  void _moveStaffToRole(String from, String to) {
    for (final c in widget.users.all().where((c) => c.role == from)) {
      widget.users.upsert(Cashier(
        id: c.id,
        name: c.name,
        role: to,
        pinSalt: c.pinSalt,
        pinHash: c.pinHash,
        active: c.active,
      ));
    }
    widget.audit.record(_session?.cashierId ?? 'system', 'role.reassigned',
        detail: '$from -> $to');
  }

  /// How old the prices on this till are, in the shortest true form. Shown on the
  /// Refresh menu row so the age is readable long before the sell screen's
  /// day-old banner appears.
  ///
  /// Translated here rather than by the hub tile, because a count is baked into
  /// the middle of it and an interpolated sentence never matches a lookup.
  String _menuAgeLabel(BuildContext context) {
    final at = widget.catalogue.refreshedAt;
    if (at == null) return tr(context, 'Prices have never been downloaded');
    final age = DateTime.now().toUtc().difference(at);
    final prefix = tr(context, 'Prices last updated');
    if (age.inMinutes < 1) return '$prefix ${tr(context, 'just now')}';
    final (count, unit) = switch (age) {
      _ when age.inHours < 1 => (age.inMinutes, 'minute(s) ago'),
      _ when age.inDays < 1 => (age.inHours, 'hour(s) ago'),
      _ => (age.inDays, 'day(s) ago'),
    };
    return '$prefix $count ${tr(context, unit)}';
  }

  /// Pull the menu on demand, and say what actually happened. The wait is on a
  /// settings screen, never on a sale, and a till with no line keeps selling from
  /// the prices it already has.
  Future<void> _refreshMenuNow(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    // Translated before the await: the context may be gone by the time it lands.
    final words = {
      for (final o in RefreshOutcome.values) o: tr(context, _refreshWords[o]!),
    };
    messenger.showSnackBar(SnackBar(
      key: const Key('menu-refreshing'),
      content: Text(tr(context, 'Getting the latest prices...')),
      duration: const Duration(seconds: 30),
    ));
    final outcome = await widget.sync.refresh(force: true);
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        key: const Key('menu-refresh-result'),
        content: Text(words[outcome]!),
      ));
    if (mounted) setState(() {});
  }

  static const Map<RefreshOutcome, String> _refreshWords = {
    RefreshOutcome.updated: 'Menu and prices updated.',
    RefreshOutcome.unchanged: 'Already up to date.',
    RefreshOutcome.unreachable:
        'No connection. The till keeps selling from the prices it has.',
    RefreshOutcome.failed: 'The server answered, but the menu did not come down.',
  };

  /// What this device is on the shop LAN, and who else it can see. The fabric is
  /// read through a callback rather than copied in, so the peer list and the last
  /// catch-up are what is true while the screen is open.
  Widget _lanScreen(VoidCallback refresh) => LanSettingsScreen(
        settings: widget.settings,
        deviceId: widget.deviceId,
        buildDefault: widget.config.lanDefault,
        facts: widget.lan == null ? null : () => widget.lan!.facts,
        onSyncNow: widget.lan?.pass,
        onChanged: () {
          refresh();
          unawaited(_reconcileLan());
        },
      );

  /// Gate a privileged action behind manager approval. A manager already signed in
  /// passes straight through; anyone else must enter a manager PIN.
  Future<bool> _authorizeManager(BuildContext context) async {
    if (widget.auth.signedIn?.isManager ?? false) return true;
    final ctrl = TextEditingController();
    final codeCtrl = TextEditingController();
    // Only a shop that has enrolled an authenticator is shown the second field, so
    // nothing changes for a till that does not use one.
    final second = widget.auth.managersUseSecondFactor;
    final entered = await showDialog<(String, String)>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr(ctx, 'Manager approval')),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
            key: const Key('manager-pin'),
            controller: ctrl,
            autofocus: true,
            obscureText: true,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
                labelText: tr(ctx, 'Manager PIN'), border: const OutlineInputBorder()),
          ),
          if (second) ...[
            const SizedBox(height: 10),
            TextField(
              key: const Key('manager-code'),
              controller: codeCtrl,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                  labelText: tr(ctx, 'Authenticator code'),
                  helperText: tr(ctx, 'Only if this manager set one up'),
                  border: const OutlineInputBorder()),
            ),
          ],
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr(ctx, 'Cancel'))),
          FilledButton(
            key: const Key('manager-ok'),
            onPressed: () =>
                Navigator.pop(ctx, (ctrl.text.trim(), codeCtrl.text.trim())),
            child: Text(tr(ctx, 'Approve')),
          ),
        ],
      ),
    );
    if (entered == null || entered.$1.isEmpty) return false;
    final ok = await widget.auth.authorizeManager(entered.$1, code: entered.$2);
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(tr(context, 'Manager approval failed'))));
    }
    return ok;
  }

  /// Gate a privileged action behind the signed-in cashier's role permissions.
  ///
  /// If their role may do [p] on its own, it passes with no prompt. Otherwise it
  /// falls back to the manager-PIN dialog so a manager can approve on the spot. A
  /// denial that is neither self-permitted nor manager-approved is audited so a
  /// blocked action still leaves a trail.
  Future<bool> _authorize(Permission p, BuildContext context) async {
    final cashier = widget.auth.signedIn;
    final role = cashier?.role ?? 'cashier';
    if (widget.settings.roleCan(role, p)) return true;
    final approved = await _authorizeManager(context);
    if (!approved) {
      widget.audit.record(cashier?.id ?? 'unknown', 'permission.denied', detail: p.key);
    }
    return approved;
  }

  // ── kitchen tickets ──────────────────────────────────────────────

  /// Fire a kitchen ticket for the lines not yet sent. Best-effort and never on the
  /// path of a tap: a kitchen printer that is off must not stop the sale. When no
  /// kitchen printer answers, the ticket falls back to the receipt printer so a
  /// slip still comes out that staff can carry to the pass.
  ///
  /// Returns what actually became of the ticket, so the cashier can be told the
  /// truth rather than a cheerful "Sent to kitchen" over a printer that is off.
  Future<KitchenFireResult> _fireKitchen(Order order,
      {List<OrderLine>? only, bool resend = false}) async {
    // A normal Send fires only lines that are due now; a course-timed line with a
    // future timer is held back until the ticker fires it. An explicit `only` list
    // (a resend, or the ticker's due lines) is honoured as given.
    final now = DateTime.now().toUtc();
    final lines =
        only ?? order.lines.where((l) => !l.printedToKitchen && l.dueAt(now)).toList();
    if (lines.isEmpty) return KitchenFireResult.sent;
    // The ticket says which part of the floor the plate is going to, resolved from
    // the floor plan on this device.
    final builder = KitchenTicketBuilder(sectionOf: widget.tables.sectionFor);
    // Route each line to its category's station, so a multi-station kitchen sends
    // hot food and bar drinks to different printers. Unmapped categories fall to
    // the single default kitchen.
    // A line routes to a per-item printer override if set, else its category's
    // station(s), else the default kitchen; a line can print at several stations.
    final routed = routeToStations(lines,
        categoryToStations: widget.settings.categoryStations,
        productToStations: widget.settings.productStations);
    // Which stations each line needs, so a line is marked fully fired only once
    // every station it routes to has its copy.
    final stationsOf = <String, Set<String>>{};
    for (final entry in routed.entries) {
      for (final l in entry.value) {
        stationsOf.putIfAbsent(l.uuid, () => {}).add(entry.key);
      }
    }
    // The worst thing that happened to any station's copy, since that is what the
    // cashier has to act on.
    var outcome = KitchenFireResult.sent;
    // Send per station, but only the lines that have NOT already reached it: a
    // resend after a partial failure must not reprint at a station that already got
    // the ticket. A line records each station it lands at, so retries are idempotent
    // per station and a later void follows it even if routing changes.
    for (final entry in routed.entries) {
      final station = entry.key;
      // A deliberate resend reprints everything; an ordinary fire only sends the
      // lines a station has not already received.
      final pending = resend
          ? entry.value
          : entry.value.where((l) => !l.firedStations.contains(station)).toList();
      if (pending.isEmpty) continue;
      final bytes = builder.build(order, only: pending, station: station);
      final result = await _sendToStation(station, bytes, 'kot-${order.uuid}-$station');
      outcome = outcome.worst(result);
      if (result == KitchenFireResult.lost) continue;
      for (final l in pending) {
        // Dedupe: a deliberate resend must not append the same station twice, or a
        // later void would send duplicate cancel slips to it.
        if (!l.firedStations.contains(station)) l.firedStations.add(station);
      }
    }
    for (final l in lines) {
      final stations = stationsOf[l.uuid] ?? const <String>{};
      if (stations.isNotEmpty && stations.every(l.firedStations.contains)) {
        l.printedToKitchen = true;
      }
    }
    widget.orders.save(order);
    return outcome;
  }

  Future<void> _fireVoid(Order order, OrderLine line, String reason) async {
    final bytes = KitchenTicketBuilder(sectionOf: widget.tables.sectionFor)
        .buildVoid(order, line, reason);
    // Void goes to the station(s) this line was actually fired to; only when that
    // was not recorded (older orders) do we fall back to the current routing.
    final stations = line.firedStations.isNotEmpty
        ? line.firedStations
        : routeToStations([line],
                categoryToStations: widget.settings.categoryStations,
                productToStations: widget.settings.productStations)
            .keys
            .toList();
    for (final station in stations) {
      await _sendToStation(station, bytes, 'void-${order.uuid}-${line.uuid}-$station');
    }
  }

  /// Send a kitchen ticket to [station]: [KitchenFireResult.sent] if a printer took
  /// it, [KitchenFireResult.spooled] if it is held for the background flush, and
  /// [KitchenFireResult.lost] if it reached neither (so the caller can keep the lines
  /// un-fired and retry later).
  Future<KitchenFireResult> _sendToStation(
      String station, List<int> bytes, String reference) async {
    final payload = Uint8List.fromList(bytes);
    try {
      await RegistryPrinter(widget.printers, station).send(payload);
      return KitchenFireResult.sent;
    } on PrinterUnavailable {
      // No station printer: fall back to the receipt printer. It persists the ticket
      // to the spool on any failure before rethrowing, so once we hand it over the
      // ticket is durable and the background flush will print it. That counts as
      // delivered: firing the lines here is what stops a re-fire duplicating it.
      try {
        await _receiptPrinter.send(payload, reference: reference);
        return KitchenFireResult.sent;
      } on PrinterUnavailable {
        // Held in the spool; the background flush will retry it. Nothing is cooking
        // yet, so say so.
        return KitchenFireResult.spooled;
      } catch (e) {
        // Also spooled (SpooledPrinter persists before it rethrows); note it for
        // diagnostics. Durable, but still not on a pass anybody can read.
        widget.audit.record(_session?.cashierId ?? 'system', 'kitchen.spooled',
            detail: '$reference: $e');
        return KitchenFireResult.spooled;
      }
    } catch (e) {
      // The station printer failed with something other than "unavailable", so the
      // ticket reached neither a printer nor the spool: keep the lines un-fired so a
      // later re-fire retries them.
      widget.audit.record(_session?.cashierId ?? 'system', 'kitchen.failed',
          detail: '$reference: $e');
      return KitchenFireResult.lost;
    }
  }

  /// Kick the cash drawer open outside a sale (to make change, drop a float),
  /// printing a short NO SALE slip so the open is on paper. Permissioned, and
  /// audit-logged so an out-of-sale open is always traceable.
  Future<void> _openDrawerNoSale(BuildContext context) async {
    // Read the one translated word the slip needs before any await, so the printed
    // text does not depend on the context surviving the permission prompt.
    final noSale = tr(context, 'NO SALE');
    if (!await _authorize(Permission.openDrawer, context)) return;
    final who = _session?.cashierId ?? 'system';
    final slip = EscPos()
      ..align(EscPosAlign.center)
      ..bold(true)
      ..line(noSale)
      ..bold(false)
      ..align(EscPosAlign.left)
      ..line(who)
      ..feed(1)
      ..openDrawer()
      ..cut();
    try {
      // Immediate-or-nothing: a drawer pulse must never be spooled, or the till
      // could pop open unexpectedly when the backlog flushes later.
      await _receiptPrinter.sendNow(slip.build());
    } on PrinterUnavailable {
      widget.audit.record(who, 'drawer.nosale.failed');
      if (context.mounted) {
        showToast(context, tr(context, 'Printer unavailable, drawer not opened'), kind: ToastKind.error);
      }
      return;
    }
    widget.audit.record(who, 'drawer.nosale');
    if (context.mounted) showToast(context, tr(context, 'Drawer opened'), kind: ToastKind.success);
  }

  void _openSettings(BuildContext context) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => ServerSettingsScreen(
        store: widget.endpoints,
        // Rewire the live sender the moment settings are saved, so a till just
        // pointed at a server drains its queue without a restart.
        onSaved: widget.odoo.configure,
        check: widget.checkServer,
      ),
    ));
  }

  void _openShift(BuildContext context, PosSession session) {
    // Which tenders count as drawer cash, read from the synced catalogue so the
    // X/Z drawer total reconciles cash and leaves card sales out.
    final cashMethodIds = widget.catalogue
        .paymentMethods()
        .where((m) => m.isCash)
        .map((m) => m.id)
        .toSet();
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => ShiftScreen(
        store: widget.shifts,
        cashierId: session.cashierId,
        cashMethodIds: cashMethodIds,
        formatAmount: PosApp.money,
        onPrintReport: _printShiftReport,
        // Read at the moment the Z is attempted, not now: a tab can be settled
        // while the shift screen is open.
        openWork: () => _openWork(context),
        // Leaving a parked tab or an unfired course behind is money and food nobody
        // has accounted for, so it always takes a manager, whatever the cashier's
        // role allows for an ordinary close. Audited either way: an override and a
        // refusal are both worth knowing about the morning after.
        authorizeOpenWork: () async {
          final who = session.cashierId;
          final ok = await _authorizeManager(context);
          widget.audit.record(
              who, ok ? 'shift.close.override' : 'shift.close.blocked');
          return ok;
        },
        // Gated BEFORE the shift closes, since the close is irreversible: the
        // cashier's role may allow it outright, otherwise a manager approves.
        authorizeClose: () => _authorize(Permission.closeShift, context),
        // A copy of the day for whoever is not in the building. Queued and left
        // to the background lane, so the cash-up is over before the first packet
        // is sent and a mail server that is down changes nothing about closing.
        onZClosed: _emailZReport,
        // Closing the shift is when the day's orders are pushed to Odoo in one
        // batch. Returns a message for the cashier: how it went, or that the
        // orders are safe and will sync once the connection is back.
        onCloseSync: () async {
          // The drawer is counted and the shift is already closed, so telling the
          // other devices costs the cash-up nothing and cannot delay it.
          _announceDayClose(session);
          // Sweep any paid sale that never reached the outbox back in first, so the
          // count below reflects everything owed to the server, not just what
          // happened to be queued.
          await widget.sync.reconcilePending();
          final pendingBefore = widget.sync.pendingSales;
          if (pendingBefore == 0) return 'No orders to sync.';
          await widget.sync.flush();
          final left = widget.sync.pendingSales;
          if (left == 0) {
            return 'Synced $pendingBefore order(s) to Odoo.';
          }
          if (!widget.sync.online.value) {
            return 'Offline. $left order(s) saved on this till and will sync when '
                'the connection is back (or from Support > Sync now).';
          }
          return 'Synced ${pendingBefore - left} of $pendingBefore. $left still '
              'pending, try again from Support > Sync now.';
        },
      ),
    ));
  }

  /// Queue the closed Z for whoever the shop asked to send it to.
  ///
  /// Never awaited and never able to throw: the shift is already closed by the
  /// time this runs, and the queue owns delivery from here. A till with no mail
  /// configured queues nothing at all.
  void _emailZReport(Shift closed, List<(String, String)> rows) {
    final emailer = widget.emailer;
    if (emailer == null || !emailer.configured) return;
    final shop = widget.settings.shopName ?? widget.config.shopName;
    final when = (closed.closedAt ?? DateTime.now().toUtc()).toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    final stamp = '${when.year}-${two(when.month)}-${two(when.day)} '
        '${two(when.hour)}:${two(when.minute)}';
    final body = StringBuffer()
      ..writeln('$shop  Z report')
      ..writeln(stamp)
      ..writeln('Till: ${widget.deviceId}')
      ..writeln('Closed by: ${closed.cashierId}')
      ..writeln();
    for (final row in rows) {
      body.writeln('${row.$1.padRight(24)}${row.$2}');
    }
    // Keyed on the shift, so a close replayed after a crash is one email.
    unawaited(emailer.send(
      uuid: 'z-${closed.uuid}',
      subject: '$shop  Z report  $stamp',
      body: body.toString(),
    ));
  }

  /// What is still unfinished on this till: tabs parked on tables, and lines held
  /// back for a course that has not fired yet. Both survive a Z, and neither is in
  /// its takings, so the cashier is shown them by name before the day is closed.
  ///
  /// Scoped to this till's own orders, like everything else that decides money: a
  /// tab parked on the bar till is that till's to settle and close over.
  OpenWork _openWork(BuildContext context) {
    final held = widget.orders.held();
    final session = _session;
    // Every order a course can still be waiting on: parked tabs, the one on the
    // counter (a timer can be set on a table that was never parked), and sales
    // already paid whose later course has not fired yet. The same list the ticker
    // fires from, so the two never disagree about what is still coming.
    final withTimers = <String, Order>{
      for (final o in held) o.uuid: o,
      for (final o in widget.orders.awaitingSync()) o.uuid: o,
      if (session != null && session.current.lines.isNotEmpty)
        session.current.uuid: session.current,
    };
    final timed = <String>[];
    for (final o in withTimers.values) {
      for (final l in o.lines.where((l) => l.isTimed)) {
        timed.add('${_orderWhere(context, o)}: ${l.name} '
            '${_atClock(l.fireAt!)}');
      }
    }
    return OpenWork(
      heldOrders: [
        for (final o in held)
          '${_orderWhere(context, o)} - ${PosApp.money(o.total)}',
      ],
      timedLines: timed,
    );
  }

  /// Where an order is, in the words a cashier uses: the table it is on, or what
  /// kind of sale it is when it is not on one.
  String _orderWhere(BuildContext context, Order order) =>
      order.tableLabel ?? tr(context, order.type.label);

  /// A local wall clock, which is what a fire time means to the kitchen.
  static String _atClock(DateTime utc) {
    final t = utc.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(t.hour)}:${two(t.minute)}';
  }

  /// Print an X or Z shift report to the receipt printer (spooled if it is down).
  Future<void> _printShiftReport(String title, List<(String, String)> rows) async {
    final shop = widget.settings.shopName ?? widget.config.shopName;
    final p = EscPos()..reset();
    p.align(EscPosAlign.center)
      ..size(doubleWidth: true, doubleHeight: true)
      ..bold(true)
      ..line(shop)
      ..bold(false)
      ..size()
      ..line(title);
    final now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    p.align(EscPosAlign.left)
      ..rule()
      ..line('${now.year}-${two(now.month)}-${two(now.day)} ${two(now.hour)}:${two(now.minute)}')
      ..rule();
    for (final r in rows) {
      p.row(r.$1, r.$2);
    }
    final bytes = (p..feed(2)..cut()).build();
    try {
      await _receiptPrinter.send(bytes, reference: 'shift-$title-${now.millisecondsSinceEpoch}');
    } on PrinterUnavailable {
      // Held in the spool; the flush retries it.
    }
  }

  /// A throwaway order for the receipt-designer test print. Never saved or synced.
  Order _sampleOrder() => Order(
        deviceId: widget.deviceId,
        cashierId: _session?.cashierId ?? 'sample',
        lines: [
          OrderLine(productId: 0, name: 'Sample item', quantity: 1, unitPrice: 10),
        ],
      )..payments = [const OrderPayment(methodId: 0, amount: 10, label: 'Cash')];

  void _openDiagnostics(BuildContext context) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => DiagnosticsScreen(
        sync: widget.sync,
        outboxStore: widget.outboxStore,
        printers: widget.printers,
        spool: _receiptPrinter,
        updates: widget.updates,
        wizards: widget.wizards,
        cashierId: _session?.cashierId,
        printError: _printError,
        authorize: (p) => _authorize(p, context),
        onBackup: widget.backup,
      ),
    ));
  }
}
