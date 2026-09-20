import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import '../core/i18n/l10n.dart';

import '../core/audit/audit_log.dart';
import '../core/auth/auth_service.dart';
import '../core/auth/bootstrap_cashier.dart';
import '../core/auth/fingerprint_agent_launcher.dart';
import '../core/auth/fingerprint_service.dart';
import '../core/auth/fingerprint_store.dart';
import '../core/auth/permissions.dart';
import '../core/auth/user_store.dart';
import '../features/auth/fingerprint_or_pin_dialog.dart';
import '../core/config/till_config.dart';
import '../core/db/catalogue_store.dart';
import '../core/db/attendance_store.dart';
import '../core/db/customer_store.dart';
import '../core/db/delivery_store.dart';
import '../core/db/order_store.dart';
import '../core/db/reservation_store.dart';
import '../core/db/table_assignment_store.dart';
import '../core/db/settings_store.dart';
import '../core/db/shift_store.dart';
import '../core/db/sqlite_outbox_store.dart';
import '../core/db/table_store.dart';
import '../core/email/email_service.dart';
import '../core/lan/lan_cart_board.dart';
import '../core/lan/lan_claim.dart';
import '../core/lan/lan_credential.dart';
import '../core/lan/lan_shift_board.dart';
import '../core/lan/lan_wiring.dart';
import '../core/onboarding/setup_checklist.dart';
import '../core/onboarding/wizard_id.dart';
import '../core/onboarding/wizard_store.dart';
import '../core/printing/escpos.dart';
import '../core/widgets/feedback.dart';
import '../core/widgets/numeric_keypad.dart';
import '../core/printing/kitchen_ticket.dart';
import '../core/printing/printer_logo.dart';
import '../core/printing/printer_registry.dart';
import '../core/printing/printer_transport.dart';
import '../core/printing/receipt_builder.dart';
import '../core/printing/registry_printer.dart';
import '../core/printing/spool_store.dart';
import '../core/sync/dishflow_mirror.dart';
import '../core/sync/dishflow_wiring.dart';
import '../core/sync/ecommerce_orders_client.dart';
import '../core/sync/odoo_endpoint.dart';
import '../core/sync/odoo_puller.dart';
import '../core/sync/odoo_wiring.dart';
import '../core/sync/outbox.dart';
import '../core/sync/store_order_alert.dart';
import '../core/sync/server_probe.dart';
import '../core/sync/sync_service.dart';
import '../core/theme/app_colors.dart';
import '../core/theme/app_theme.dart';
import '../core/updates/update_service.dart';
import '../domain/business_day.dart';
import '../domain/catalogue.dart';
import '../domain/order.dart';
import '../domain/table_floor_info.dart';
import '../domain/table_section_config.dart';
import '../domain/shift.dart';
import '../features/admin/attendance_screen.dart';
import '../features/admin/roles_permissions_screen.dart';
import '../features/admin/roster_screen.dart';
import '../features/support/audit_log_screen.dart';
import '../features/auth/login_screen.dart';
import '../features/customers/customer_management_screen.dart';
import '../features/display/customer_display_screen.dart';
import '../features/kitchen/kitchen_display_screen.dart';
import '../features/menu/menu_editor_screen.dart';
import '../features/onboarding/setup_checklist_card.dart';
import '../features/onboarding/wizard_overlay.dart';
import '../features/orders/delivery_waiting_screen.dart';
import '../features/orders/ecommerce_orders_screen.dart';
import '../features/orders/open_orders_screen.dart';
import '../features/orders/order_history_screen.dart';
import '../features/orders/refund_screen.dart';
import '../features/reports/reports_hub_screen.dart';
import '../features/reports/flash/flash_report_data.dart';
import '../features/reports/flash/flash_thermal_escpos.dart';
import '../features/reports/flash/flash_type_dialog.dart';
import '../features/sell/sell_screen.dart';
import '../features/settings/appearance_settings_screen.dart';
import '../features/settings/delivery_settings_screen.dart';
import '../features/settings/dishflow_mirror_settings_screen.dart';
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
import '../features/settings/fingerprint_diag_screen.dart';
import '../features/settings/station_settings_screen.dart';
import '../features/settings/table_preorder_screen.dart';
import '../features/shift/shift_screen.dart';
import '../features/support/diagnostics_screen.dart';
import '../features/support/sql_console_screen.dart';
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
    required     this.attendance,
    this.fingerprints,
    this.fingerprintStore,
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
    this.assignments,
    this.dishflow,
    this.loginManagersOnly = true,
    this.nowFn = DateTime.now,
  });

  /// The clock the idle lock reads. Injectable for the tests, exactly as the
  /// floor's booking badges inject theirs; production reads the real one.
  final DateTime Function() nowFn;

  /// When true, the lock screen lists managers only. Cashiers clock in from
  /// Attendance and open tables with their PIN.
  final bool loginManagersOnly;

  /// Tables booked ahead. Null on a shop that does not take bookings and in the
  /// suites that predate them, and then the floor reads exactly as it did.
  final ReservationStore? reservations;

  /// Who works which table this service. Null in the suites that predate it, and
  /// then every table is open to whoever is signed in, exactly as before.
  final TableAssignmentStore? assignments;

  /// Owner-mirror wiring for Dishflow. Null in suites that do not exercise it.
  final DishflowWiring? dishflow;

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

  /// ZKTeco USB fingerprint reader (local agent). Null = PIN only.
  final FingerprintService? fingerprints;

  /// Enrolled templates (LAN-synced). Null when fingerprints are off.
  final FingerprintStore? fingerprintStore;

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

  /// Customer / driver slip for delivery bags (store delivery and company).
  /// Distinct from kitchen stations so a shop can put the bag receipt on its
  /// own roll — or the same physical printer under this name.
  static const String deliveryReceiptPrinter = 'delivery';

  static String money(double v) => v.toStringAsFixed(2);

  @override
  State<PosApp> createState() => _PosAppState();
}

/// What the till has to say about the drawer when a cashier signs in: nobody
/// opened a shift, or one is still open from an earlier trading day. Both are how a
/// day ends up with a Z that makes no sense; the first one also stops the till
/// selling, which the sell screen enforces.
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
  /// The navigator MaterialApp builds, so code that runs outside any screen can
  /// still reach one: the shift nudge above the navigator, and the tab recalled
  /// from the Open orders list after that list has closed itself.
  final GlobalKey<NavigatorState> _navigator = GlobalKey<NavigatorState>();

  PosSession? _session;

  /// Whether the counter is up. False is the resting state of a restaurant till:
  /// the floor is home, and an order has to be started or recalled to leave it.
  bool _onCounter = false;

  /// The room the waiter has open on the floor, and what the next table tap seats.
  ///
  /// Held up here because home swaps the floor out for the counter on every order
  /// and takes the floor's own state with it: a waiter working the Terrace was
  /// landing back on the first section after every single order.
  ///
  /// Deliberately NOT persisted across a restart. It is where one waiter is standing
  /// this minute, not a rule about the shop: a till reopened in the morning should
  /// show the room the shop starts in rather than wherever last night's closer
  /// happened to be, and it is cleared at sign-out for the same reason.
  String? _floorSection;
  OrderType? _floorSeatAs;

  bool _firstSaleHelp = false;

  /// Whether the walkthrough for the provisioning account is up. Only that account
  /// ever sees it: it is the one that stands in front of an unconfigured till.
  bool _firstSignInHelp = false;

  /// Live copy of the Setup PIN so a till that missed it at boot can regenerate
  /// and show it on the lock screen without a full restart.
  String? _provisioningPin;

  String? _printError;
  Timer? _background;
  Timer? _storeOrderPoll;

  /// Seen Firebase store-order ids — first poll is silent, then new ones alert.
  final StoreOrderWatchState _storeWatch = StoreOrderWatchState();

  /// Active store orders (`pending`/`received`) last seen while signed in.
  int _storeOrderCount = 0;

  /// Banner + dialog stay up until the cashier opens Store orders or dismisses.
  bool _storeAlertVisible = false;
  String? _storeAlertOrderNo;
  int _storeAlertNewCount = 0;
  bool _storeAlertDialogOpen = false;

  /// Soft hint when the till can sell but cannot hear store orders yet.
  bool _storeMirrorHint = false;
  String? _storePollError;

  /// What the cashier who just signed in needs telling about the drawer, or null
  /// when the shift is in order. Cleared when they act on it or wave it away.
  ShiftNudge? _nudge;

  /// The last moment anybody touched the till, for the idle lock. Stamped by
  /// every pointer-down and by every change to the open order, so a till worked
  /// entirely by barcode scanner counts as busy too.
  late DateTime _lastTouch = widget.nowFn();

  /// The bill that was just parked, for the line the floor says about it, or null
  /// when there is nothing to say. The table is null on a bill that was never
  /// seated.
  ///
  /// A strip above the plan and not a toast: a toast lands at the bottom of the
  /// screen, which on the floor is the To go / Takeaway / Delivery row, so the
  /// confirmation sat on top of the button the cashier taps next.
  ({String? table})? _justParked;
  Timer? _justParkedClear;

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
    _provisioningPin = widget.provisioningPin;
    // If Setup is the only account but the PIN did not arrive from boot (or the
    // lock screen clipped it away), mint again so the cashier is never stranded.
    if (_provisioningPin == null &&
        BootstrapCashier.stillNeeded(widget.users.active())) {
      unawaited(_refreshSetupPin());
    }
    // The same slow lane the sync timer runs in. Held receipts used to wait for a
    // human to open the support screen and press Reprint, which meant a printer
    // that came back mid-shift printed nothing until somebody noticed.
    _background = Timer.periodic(const Duration(seconds: 30), (_) => _catchUp());
    unawaited(_startLan());
  }

  Future<void> _refreshSetupPin() async {
    final pin = await BootstrapCashier.ensure(widget.auth, widget.users);
    if (!mounted || pin == null) return;
    setState(() => _provisioningPin = pin);
  }

  @override
  void dispose() {
    _background?.cancel();
    _stopStoreOrderWatch();
    _justParkedClear?.cancel();
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
    _lockIfIdle();
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
      // The draft outlives its session: the idle lock signs the cashier out
      // over a half-rung bill, and any course-timed lines on it still owe the
      // kitchen their food whoever is standing at the till.
      ...widget.orders.drafts(),
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
    _lastTouch = widget.nowFn();
    setState(() {
      final session = _session = PosSession(
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
        nextOrderNo: () {
          // Climb past any number already on this shop (other tills / older
          // sales) so Flash never lists two different checks as the same #.
          var floor = 0;
          for (final o in widget.orders.recentAnywhere(limit: 2000)) {
            final n = int.tryParse(o.displayNo);
            if (n != null && n > floor) floor = n;
          }
          return widget.settings
              .nextOrderNumber(widget.deviceId, atLeast: floor);
        },
        settings: widget.settings,
      );
      _firstSaleHelp = widget.wizards.shouldShow(WizardId.firstSale, cashier.id);
      // The provisioning account is whoever is standing at a till that has just
      // been installed, so it is the one that gets walked through what is left to
      // do. A real cashier meets the first-sale help instead.
      _firstSignInHelp = cashier.id == BootstrapCashier.id &&
          widget.wizards.shouldShow(WizardId.firstSignIn, cashier.id);
      // Crash recovery: a draft read back off the disk puts the cashier straight
      // onto that order, because half a bill with a customer standing there is not
      // something to make them go and find. An empty till lands on the floor, which
      // is where a service starts.
      _onCounter = session.current.lines.isNotEmpty ||
          session.current.tableLabel != null;
    });
    // Support asks who is on the till before anything else.
    widget.sync.cashierId = cashier.id;
    // Ask for the menu now rather than when the age gate expires. A cashier
    // opening the till at 08:00 sells this morning's prices, not last night's.
    // Never awaited: read-only, off the selling path, and a till with no line
    // just carries on with what it has.
    unawaited(() async {
      await widget.sync.refresh(force: true);
      // The refresh authenticated the login, so Odoo can now say whose branch
      // this till is; adopting after it and pulling again costs a second pull
      // only on the day the answer changes.
      if (await _adoptOdooBranch()) await widget.sync.refresh(force: true);
      if (mounted) setState(() {});
    }());
    _publishActivity();
    _nudgeShift();
    unawaited(_offerLanRoleIfNeeded());
    _startStoreOrderWatch();
  }

  /// First install (or after Unlink): ask Primary / Join / Skip once.
  Future<void> _offerLanRoleIfNeeded() async {
    if (!mounted) return;
    if (widget.settings.deviceRole != DeviceRole.unset) return;
    if (widget.settings.lanRolePromptDismissed) return;
    // PosApp's State sits above MaterialApp; dialogs need the navigator below.
    await Future<void>.delayed(Duration.zero);
    if (!mounted) return;
    final navCtx = _navigator.currentContext;
    if (navCtx == null) return;
    final choice = await showDialog<String>(
      context: navCtx,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        key: const Key('lan-role-prompt'),
        title: Text(tr(ctx, 'Link tills on this network?')),
        content: Text(tr(
            ctx,
            'If another till in the shop is already set up, join it with a PIN. '
                'If this is the first till, make it the primary.')),
        actions: [
          TextButton(
            key: const Key('lan-role-prompt-skip'),
            onPressed: () => Navigator.pop(ctx, 'skip'),
            child: Text(tr(ctx, 'Skip for now')),
          ),
          OutlinedButton(
            key: const Key('lan-role-prompt-primary'),
            onPressed: () => Navigator.pop(ctx, 'primary'),
            child: Text(tr(ctx, 'This is the primary')),
          ),
          FilledButton(
            key: const Key('lan-role-prompt-join'),
            onPressed: () => Navigator.pop(ctx, 'join'),
            child: Text(tr(ctx, 'Join with a PIN')),
          ),
        ],
      ),
    );
    if (!mounted || choice == null) return;
    widget.settings.lanRolePromptDismissed = true;
    if (choice == 'skip') return;
    final messengerCtx = _navigator.currentContext ?? context;
    if (choice == 'primary') {
      widget.settings.deviceRole = DeviceRole.primary;
      if (!(widget.settings.lanEnabled(fallback: widget.config.lanDefault))) {
        widget.settings.setLanEnabled(true);
      }
      widget.settings.lanShopKey ??= LanCredential.newKey();
      unawaited(_reconcileLan());
      if (mounted) setState(() {});
      if (widget.lan == null && mounted) {
        ScaffoldMessenger.of(messengerCtx).showSnackBar(SnackBar(
          content: Text(tr(
              messengerCtx,
              'Primary saved. Restart the app once so Share can start on the network.')),
        ));
      }
      return;
    }
    // Join: open Shop network as secondary so they can pick the primary + PIN.
    widget.settings.deviceRole = DeviceRole.secondary;
    if (!(widget.settings.lanEnabled(fallback: widget.config.lanDefault))) {
      widget.settings.setLanEnabled(true);
    }
    unawaited(_reconcileLan());
    if (!mounted) return;
    setState(() {});
    if (widget.lan == null) {
      ScaffoldMessenger.of(messengerCtx).showSnackBar(SnackBar(
        content: Text(tr(
            messengerCtx,
            'Restart the app, then open Shop network and Join with the PIN '
                'from the primary.')),
      ));
      return;
    }
    _openLanSettings();
  }

  void _openLanSettings() {
    final nav = Navigator.of(context);
    nav.push(MaterialPageRoute<void>(
      builder: (_) => _lanScreen(() {
        if (mounted) setState(() {});
      }),
    ));
  }

  /// Put the cashier on the counter, for an order they have just started, recalled
  /// or reopened. The only way a bill gets on screen.
  void _toCounter() {
    if (!mounted || _onCounter) return;
    setState(() => _onCounter = true);
  }

  /// Leave the counter and show the floor again.
  ///
  /// Whatever is still on the counter is PARKED on the way out rather than left as
  /// the draft. Both keep the order, but only a parked tab can be found again from
  /// everywhere a cashier looks for it: the floor tile, the Open orders list, and
  /// the prompt that asks whether the next delivery call is one already waiting. A
  /// draft is in none of those, so the second call would open a duplicate bag. The
  /// order keeps its lines and its number, and tapping its table recalls it.
  ///
  /// A no-op on an empty counter and on one that was just paid or parked, because
  /// [PosSession.hold] does nothing to an order with no lines.
  ///
  /// [confirmPark] is set by the Park button alone, which is the one way out that a
  /// cashier expects to be told about; the floor says so above the plan.
  void _toFloor({bool confirmPark = false}) {
    final session = _session;
    // Read before the hold: holding starts a fresh blank order, so afterwards there
    // is no longer anything to name.
    final parked = confirmPark && (session?.hasLines ?? false);
    final table = session?.current.tableLabel;
    // Hold refuses an empty cart, and a seated claim is stored held so the LAN
    // floor colours it. Leaving with nothing rung must drop that claim, or the
    // table stays busy after the waiter backed out.
    if (session != null && !session.hasLines) {
      session.newOrder();
    } else {
      session?.hold();
    }
    _publishActivity();
    if (!mounted) return;
    // Cleared on every way onto the floor, so a line about one service's parked tab
    // cannot still be up when the cashier walks back on for the next.
    _justParkedClear?.cancel();
    _justParked = parked ? (table: table) : null;
    if (parked) {
      // Long enough to read on the way past, then gone: the table tile turning
      // occupied is the lasting record, not this.
      _justParkedClear = Timer(const Duration(seconds: 4), () {
        if (mounted) setState(() => _justParked = null);
      });
    }
    setState(() => _onCounter = false);
  }

  /// Start a fresh order of [type] and open the counter on it. The takeaway, to-go
  /// and delivery buttons on the floor home.
  void _startOrder(PosSession session, OrderType type) {
    setState(() {
      session.startFresh(type);
      _onCounter = true;
    });
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
  /// A strip and not a dialog, deliberately: a modal at sign-in is a modal that gets
  /// dismissed without being read. It sits above the navigator rather than on one
  /// screen, so it is read on the floor the cashier lands on as well as on the sell
  /// screen, and it takes its own space instead of covering the till. It is
  /// dismissible; the refusals that are not live on the floor and on the counter.
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
                        : 'No shift is open. Selling is blocked until you open one.'),
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

  /// Persistent strip while a new store order is waiting — stays until View or
  /// the cashier opens Store orders (sound keeps going with it).
  Widget _storeOrderAlertBar(BuildContext context) {
    final n = _storeAlertNewCount;
    final no = _storeAlertOrderNo;
    final label = n > 1
        ? tr(context, '{n} new store orders waiting').replaceAll('{n}', '$n')
        : (no != null && no.isNotEmpty
            ? '${tr(context, 'New store order')} #$no'
            : tr(context, 'New store order'));
    return Material(
      key: const Key('store-order-alert-bar'),
      color: AppColors.primary,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Row(children: [
            const Icon(Icons.storefront, size: 20, color: Colors.white),
            const SizedBox(width: 10),
            Expanded(
              child: Text(label, style: const TextStyle(color: Colors.white)),
            ),
            TextButton(
              key: const Key('store-order-alert-bar-view'),
              style: TextButton.styleFrom(foregroundColor: Colors.white),
              onPressed: () {
                final session = _session;
                final below = _navigator.currentContext;
                if (session == null || below == null) return;
                _ackStoreOrderAlert();
                _openStoreOrders(below, session);
              },
              child: Text(tr(context, 'View orders')),
            ),
            TextButton(
              key: const Key('store-order-alert-bar-dismiss'),
              style: TextButton.styleFrom(foregroundColor: Colors.white),
              onPressed: _ackStoreOrderAlert,
              child: Text(tr(context, 'Later')),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _storeMirrorHintBar(BuildContext context) {
    return Material(
      key: const Key('store-mirror-hint-bar'),
      color: AppColors.warning,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Row(children: [
            const Icon(Icons.link_off, size: 20, color: Colors.white),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                tr(context,
                    'Turn on Dishflow mirror in Settings to receive store orders.'),
                style: const TextStyle(color: Colors.white),
              ),
            ),
            TextButton(
              key: const Key('store-mirror-hint-dismiss'),
              style: TextButton.styleFrom(foregroundColor: Colors.white),
              onPressed: () => setState(() => _storeMirrorHint = false),
              child: Text(tr(context, 'Later')),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _storePollErrorBar(BuildContext context, String error) {
    return Material(
      key: const Key('store-poll-error-bar'),
      color: AppColors.error,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Row(children: [
            const Icon(Icons.cloud_off, size: 20, color: Colors.white),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                '${tr(context, 'Could not load store orders')}: $error',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white, fontSize: 12.5),
              ),
            ),
            TextButton(
              style: TextButton.styleFrom(foregroundColor: Colors.white),
              onPressed: () => setState(() => _storePollError = null),
              child: Text(tr(context, 'Later')),
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
    _stopStoreOrderWatch();
    setState(() {
      _session = null;
      _firstSaleHelp = false;
      // The next cashier starts where a service starts, on the floor.
      _onCounter = false;
      // The room and the seating belong to the waiter who was on the till, not to
      // whoever picks it up next.
      _floorSection = null;
      _floorSeatAs = null;
      // The nudge belongs to the cashier who was told it, not to the sign-in screen
      // the next one is looking at.
      _nudge = null;
    });
    _publishActivity();
  }

  void _startStoreOrderWatch() {
    if (!widget.settings.receivesStoreOrderAlerts) {
      _stopStoreOrderWatch();
      if (mounted) {
        setState(() {
          _storeMirrorHint = false;
          _storePollError = null;
        });
      }
      return;
    }
    _storeOrderPoll?.cancel();
    _storeWatch.reset();
    _storeOrderCount = 0;
    _storeAlertVisible = false;
    _storeAlertOrderNo = null;
    _storeAlertNewCount = 0;
    _storeMirrorHint = false;
    _storePollError = null;
    TillAlertSound.stop();
    // Poll often enough that a bag on the phone is heard within ~10s.
    _storeOrderPoll =
        Timer.periodic(const Duration(seconds: 10), (_) {
      unawaited(_pollStoreOrders());
    });
    unawaited(_pollStoreOrders());
  }

  /// Start or stop the ecommerce alert poller when station type / sign-in changes.
  void _syncStoreOrderWatchForStation() {
    if (_session == null) {
      _stopStoreOrderWatch();
      return;
    }
    if (widget.settings.receivesStoreOrderAlerts) {
      _startStoreOrderWatch();
    } else {
      _stopStoreOrderWatch();
      if (mounted) {
        setState(() {
          _storeMirrorHint = false;
          _storePollError = null;
          _storeOrderCount = 0;
        });
      }
    }
  }

  void _stopStoreOrderWatch() {
    _storeOrderPoll?.cancel();
    _storeOrderPoll = null;
    _storeWatch.reset();
    TillAlertSound.stop();
    _storeAlertVisible = false;
    _storeOrderCount = 0;
    _storeAlertOrderNo = null;
    _storeAlertNewCount = 0;
    _storeMirrorHint = false;
    _storePollError = null;
  }

  void _ackStoreOrderAlert() {
    TillAlertSound.stop();
    if (!mounted) return;
    setState(() {
      _storeAlertVisible = false;
      _storeAlertOrderNo = null;
      _storeAlertNewCount = 0;
    });
  }

  Future<void> _pollStoreOrders() async {
    if (!mounted || _session == null) return;
    if (!widget.settings.receivesStoreOrderAlerts) {
      _stopStoreOrderWatch();
      return;
    }
    final s = widget.settings;
    if (!s.dishflowMirrorReady) {
      if (!_storeMirrorHint) {
        setState(() => _storeMirrorHint = true);
      }
      return;
    }
    if (_storeMirrorHint) {
      setState(() => _storeMirrorHint = false);
    }
    try {
      final list = await EcommerceOrdersClient().listActive(
        projectId: s.dishflowProjectId!,
        apiKey: s.dishflowApiKey!,
        branchId: s.dishflowBranchId,
      );
      if (!mounted || _session == null) return;
      if (_storePollError != null) {
        setState(() => _storePollError = null);
      }
      final ids = list.map((o) => o.id).toSet();
      final neu = _storeWatch.observe(ids);
      final countChanged = _storeOrderCount != list.length;
      if (countChanged) {
        setState(() => _storeOrderCount = list.length);
      }
      if (ids.isEmpty) {
        TillAlertSound.stop();
        if (_storeAlertVisible) {
          setState(() {
            _storeAlertVisible = false;
            _storeAlertOrderNo = null;
            _storeAlertNewCount = 0;
          });
        }
        return;
      }
      if (neu.isEmpty) return;
      final first = list.firstWhere(
        (o) => neu.contains(o.id),
        orElse: () => list.first,
      );
      final orderNo = first.orderNumber;
      setState(() {
        _storeOrderCount = list.length;
        _storeAlertVisible = true;
        _storeAlertNewCount = neu.length;
        _storeAlertOrderNo = orderNo;
      });
      unawaited(TillAlertSound.start());
      unawaited(_showStoreOrderDialog(orderNo, neu.length));
    } catch (e) {
      // Keep selling; surface the reason so a wrong project/key is not invisible.
      if (!mounted) return;
      final msg = e.toString();
      if (_storePollError != msg) {
        setState(() => _storePollError = msg);
      }
      widget.audit.record(
        _session?.cashierId ?? 'system',
        'store.orders.poll.failed',
        detail: msg,
      );
    }
  }

  Future<void> _showStoreOrderDialog(String? orderNo, int count) async {
    if (_storeAlertDialogOpen) return;
    final navCtx = _navigator.currentContext;
    if (navCtx == null || !navCtx.mounted) return;
    _storeAlertDialogOpen = true;
    try {
      final go = await showDialog<bool>(
        context: navCtx,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          key: const Key('store-order-alert-dialog'),
          icon: const Icon(Icons.storefront, color: AppColors.primary, size: 36),
          title: Text(tr(ctx, 'New store order')),
          content: Text(
            count > 1
                ? tr(ctx, '{n} new store orders waiting')
                    .replaceAll('{n}', '$count')
                : (orderNo != null && orderNo.isNotEmpty
                    ? '${tr(ctx, 'Order')} #$orderNo'
                    : tr(ctx, 'A customer order is waiting to be claimed.')),
          ),
          actions: [
            TextButton(
              key: const Key('store-order-alert-later'),
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(tr(ctx, 'Later')),
            ),
            FilledButton(
              key: const Key('store-order-alert-view'),
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(tr(ctx, 'View orders')),
            ),
          ],
        ),
      );
      if (!mounted) return;
      if (go == true) {
        final session = _session;
        final below = _navigator.currentContext;
        if (session != null && below != null) {
          _ackStoreOrderAlert();
          _openStoreOrders(below, session);
        }
      } else {
        // Acknowledge the beep; the top strip stays until they open Store orders.
        TillAlertSound.stop();
      }
    } finally {
      _storeAlertDialogOpen = false;
    }
  }

  /// Tells the update gate whether a customer is standing at the counter. Lines on
  /// screen is the honest signal: the order is already on disk, but replacing the
  /// binary underneath a half-rung sale is exactly what the gate exists to stop.
  void _publishActivity() {
    // Every order change is somebody working the till, whatever input it came
    // through, so it holds the idle lock off exactly as a touch does.
    _lastTouch = widget.nowFn();
    widget.activity?.saleInProgress = _session?.hasLines ?? false;
  }

  /// Lock the till once nobody has touched it for the shop's idle window.
  ///
  /// Locking is the sign-out the till already knows: the draft on the counter
  /// is durable and lands back on screen at the next sign-in, so nothing is
  /// lost, and the PIN screen is the lock. Ridden on the 30-second background
  /// tick rather than its own timer, so the wait is the setting give or take
  /// half a minute, which is what an idle lock needs to be.
  void _lockIfIdle() {
    final session = _session;
    if (session == null) return;
    final minutes = widget.settings.idleLockMinutes;
    if (minutes <= 0) return;
    if (widget.nowFn().difference(_lastTouch).inMinutes < minutes) return;
    widget.audit
        .record(session.cashierId, 'till.locked', detail: 'idle ${minutes}m');
    // Whatever is stacked over home comes down first: a lock screen underneath
    // an open settings page or dialog would not be locking anything.
    _navigator.currentState?.popUntil((r) => r.isFirst);
    _signOut();
  }

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
      serverNameOf: (id) => widget.users.byId(id)?.name,
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
      {required String title, String? reason, String? approvedBy}) async {
    if (lines.isEmpty) return;
    final bytes = _receiptBuilder().buildDeletion(
      order,
      lines,
      title: title,
      at: DateTime.now(),
      actor: _session?.cashierId,
      reason: reason,
      approvedBy: approvedBy,
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
    _session?.markBillPrinted();
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

  /// Print the detail slip for a payment that leaves the bill part paid: a share, a
  /// guest's check, a selection of items.
  ///
  /// Spooled like every other slip, so a dead printer costs a held job and never a
  /// refused payment, and never awaited by the screen that took the money. Cash
  /// taken as a part payment goes in the drawer like any other cash, so this slip
  /// carries the drawer kick, but only when no sale receipt is printing for the same
  /// money: a check kicks the drawer on its own receipt.
  Future<void> _printPartialPayment(PartialPayment payment) async {
    final order = payment.order;
    try {
      final cashIds = widget.catalogue
          .paymentMethods()
          .where((m) => m.isCash)
          .map((m) => m.id)
          .toSet();
      final isCash = payment.tenders.isEmpty ||
          payment.tenders.any((t) => cashIds.contains(t.methodId));
      final kick =
          isCash && !payment.alsoReceipted && widget.settings.openDrawerOnSale;
      final bytes = _receiptBuilder(openDrawer: kick).buildPartialPayment(payment,
          at: DateTime.now(), actor: _session?.cashierId ?? order.cashierId);
      // Several shares land against the same order, so the timestamp keeps each one
      // out of the spool's dedupe rather than folding the second guest into the first.
      await _receiptPrinter.send(bytes,
          reference: 'part-${order.uuid}-${DateTime.now().microsecondsSinceEpoch}');
    } on PrinterUnavailable {
      // Held in the spool; the background flush prints it when the printer is back.
    } catch (e) {
      // Same reason the sale receipt builds inside its try: a character the printer
      // cannot carry must leave a record, not an error over a taken payment.
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
        odooProductId: line.odooProductId,
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

  /// Which named printer gets the customer-facing slip for [order].
  ///
  /// Delivery bags use the configured delivery-receipt printer when that name
  /// exists in the registry; everything else (and delivery when that printer is
  /// missing) stays on the main receipt printer.
  String _customerSlipPrinterName(Order order) {
    if (!order.type.isDelivery) return PosApp.receiptPrinter;
    final preferred = widget.settings.deliveryReceiptPrinter.trim();
    if (preferred.isNotEmpty && widget.printers[preferred] != null) {
      return preferred;
    }
    return PosApp.receiptPrinter;
  }

  /// Send bytes to [printerName], falling back to the receipt spool so a missing
  /// delivery printer never loses the bag slip.
  Future<void> _sendCustomerSlip(
    Uint8List bytes, {
    required String printerName,
    required String reference,
  }) async {
    if (printerName == PosApp.receiptPrinter) {
      await _receiptPrinter.send(bytes, reference: reference);
      return;
    }
    try {
      await RegistryPrinter(widget.printers, printerName).send(bytes);
    } on PrinterUnavailable {
      await _receiptPrinter.send(bytes, reference: reference);
    }
  }

  /// Unpaid bag / driver slip after kitchen for a delivery order — address and
  /// totals on the delivery-receipt printer so the kitchen ticket is not the
  /// only paper that comes out.
  Future<void> _printDeliveryBagSlip(Order order) async {
    if (!order.type.isDelivery) return;
    try {
      final bytes = _receiptBuilder().buildBill(order);
      final name = _customerSlipPrinterName(order);
      await _sendCustomerSlip(bytes,
          printerName: name,
          reference:
              'delivery-bag-${order.uuid}-${DateTime.now().microsecondsSinceEpoch}');
    } on PrinterUnavailable {
      // Spool / offline — same as a sale receipt.
    } catch (e) {
      widget.audit.record(order.cashierId, 'receipt.failed',
          detail: 'delivery-bag ${order.uuid}: $e');
    }
  }

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
      final printerName = _customerSlipPrinterName(order);
      for (var i = 0; i < s.receiptCopies; i++) {
        try {
          await _sendCustomerSlip(
            build(openDrawer: wantDrawer && i == 0),
            printerName: printerName,
            reference: i == 0 ? base : '$base-c$i',
          );
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
        deviceRoleChosen:
            widget.settings.deviceRole != DeviceRole.unset,
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
        title: 'Dishflow',
        // Held because this shell sits ABOVE the navigator it builds, so its own
        // context cannot reach one. The shift nudge and the tab recalled from a
        // list that has already closed itself both run from up here.
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
          final storeAlert = _storeAlertVisible;
          final mirrorHint = _storeMirrorHint;
          final pollError = _storePollError;
          Widget content = navigator ?? const SizedBox.shrink();
          if (nudge != null ||
              storeAlert ||
              mirrorHint ||
              pollError != null) {
            content = Column(children: [
              if (nudge != null) _shiftNudgeBar(context, nudge),
              if (storeAlert) _storeOrderAlertBar(context),
              if (!storeAlert && mirrorHint) _storeMirrorHintBar(context),
              if (!storeAlert && !mirrorHint && pollError != null)
                _storePollErrorBar(context, pollError),
              Expanded(child: navigator ?? const SizedBox.shrink()),
            ]);
          }
          // Above the navigator so every touch on any screen, dialog or sheet
          // stamps the idle clock. A plain field write: repainting the app on
          // every tap would be a heavy price for a timestamp.
          return Listener(
            behavior: HitTestBehavior.translucent,
            onPointerDown: (_) => _lastTouch = widget.nowFn(),
            child: content,
          );
        },
        locale: locale,
        supportedLocales: kSupportedLocales,
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        // A restaurant till sits on its floor plan: signed in, that is home, and the
        // counter is what an order opens onto. A device that is only a kitchen board
        // or only a customer display has neither.
        home: widget.config.displayMode
            ? _displayOnly()
            : widget.config.kdsMode
                ? _kitchenOnly()
                : session == null
                    ? LoginScreen(
                        auth: widget.auth,
                        users: widget.users,
                        onSignedIn: _signedIn,
                        provisioningPin: _provisioningPin,
                        managersOnly: widget.loginManagersOnly,
                        fingerprints: widget.fingerprints,
                        fingerprintStore: widget.fingerprintStore,
                      )
                    : _home(session),
      ),
    );
  }

  /// What a signed-in cashier is looking at, with the walkthrough over it.
  ///
  /// The floor unless an order has been started or recalled. The coach is stacked
  /// on whichever it is rather than on the counter alone: the floor is home now, so
  /// help pinned to the sell screen would go unread on a till that has not opened
  /// an order yet.
  Widget _home(PosSession session) {
    final screen = _onCounter ? _selling(session) : _floorHome(session);
    // One coach at a time, and setting the till up comes before the first sale: two
    // scrims over each other is a cashier with no way out.
    if (!_firstSignInHelp && !_firstSaleHelp) return screen;
    return Stack(
      fit: StackFit.expand,
      children: [
        screen,
        // Builder, so the panels are written in the language the app is in.
        Builder(
          builder: (context) => _firstSignInHelp
              ? WizardOverlay(
                  steps: _firstSignInSteps(context, _setupChecklist()),
                  onClosed: (outcome) =>
                      _closeFirstSignInHelp(outcome, session.cashierId),
                )
              : WizardOverlay(
                  steps: _firstSaleSteps,
                  onClosed: (outcome) =>
                      _closeFirstSaleHelp(outcome, session.cashierId),
                ),
        ),
      ],
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

  /// Adopt the branch Odoo binds this till's login to, answering whether
  /// anything changed.
  ///
  /// The server's word beats the picker's: the ids a manager typed on the
  /// device hold only until the next sign-in, so pointing every till of a
  /// branch at the right place is done once on the branch record in Odoo
  /// rather than by hand on each device, and changing one on the till does
  /// not survive the shift change. Odoo staying silent changes nothing.
  Future<bool> _adoptOdooBranch() async {
    try {
      final bound = await OdooPuller(
        call: widget.odoo.catalogueCall,
        userId: () => widget.odoo.uid,
      ).boundSite();
      if (bound == null) return false;
      final s = widget.settings;
      var changed = false;
      if (s.odooBranchId != bound.branchId) {
        s.odooBranchId = bound.branchId;
        changed = true;
      }
      if (s.odooCompanyId != bound.companyId) {
        s.odooCompanyId = bound.companyId;
        changed = true;
      }
      if (bound.warehouseId != null && s.odooWarehouseId != bound.warehouseId) {
        s.odooWarehouseId = bound.warehouseId;
        changed = true;
      }
      if (changed) {
        widget.audit.record('system', 'site.bound',
            detail: '${bound.name} branch=${bound.branchId} co=${bound.companyId}');
      }
      return changed;
    } catch (_) {
      // Odoo has no say today; the till keeps the ids it has.
      return false;
    }
  }

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

  /// What the menu editor can link a local item or category to.
  ///
  /// Deliberately allowed to throw: the picker turns the failure into "the server
  /// did not answer, type the id instead", which is the truth and leaves the manager
  /// a way through. Swallowing it into an empty list would read as "your Odoo has no
  /// products", which is a different and much more alarming statement.
  Future<List<OdooRef>> _searchOdooProducts(String term) =>
      OdooPuller(call: widget.odoo.catalogueCall).searchProducts(term);

  Future<List<OdooRef>> _searchOdooCategories(String term) =>
      OdooPuller(call: widget.odoo.catalogueCall).searchCategories(term);

  /// Category allow-list for the table this bill sits on (empty = unrestricted).
  List<int> _sectionAllowedCategories(Order order) {
    final label = order.tableLabel;
    if (label == null || label.isEmpty) return const [];
    final section = widget.tables.sectionFor(label);
    if (section == null || section.isEmpty) return const [];
    final cfg = widget.settings.sectionConfig(section);
    if (!cfg.isStaffSection) return cfg.allowedCategoryIds;
    final table = widget.tables.byName(label);
    final assigneeId =
        table == null ? null : widget.assignments?.byTable()[table.id];
    final employeeName = assigneeId == null
        ? ''
        : (widget.users.byId(assigneeId)?.name ?? '');
    return cfg.getCategoriesForEmployee(employeeName);
  }

  List<int> _sectionAllowedPayments(Order order) {
    final label = order.tableLabel;
    if (label == null || label.isEmpty) return const [];
    final section = widget.tables.sectionFor(label);
    if (section == null || section.isEmpty) return const [];
    return widget.settings.sectionConfig(section).allowedPaymentMethodIds;
  }

  /// The counter, opened onto one order. Reached from the floor home by seating a
  /// table, by the table-less buttons, by recalling a parked tab, or by reopening a
  /// paid sale to correct it. Never the resting screen.
  Widget _selling(PosSession session) => Builder(
        // Builder, so navigation targets the Navigator inside this MaterialApp.
        builder: (context) => SellScreen(
          session: session,
          formatAmount: PosApp.money,
          staleness: widget.catalogue.stalenessAt(DateTime.now().toUtc()),
          // When the menu came down, said plainly beside the online badge. The
          // background loop now pulls every half hour, so this is usually within the
          // hour, and when it is not the cashier can see that rather than assume.
          pricesAt: widget.catalogue.refreshedAt,
          catalogueChanged: widget.sync.catalogueRevision,
          // No per-sale push: orders are held and sent as one batch at shift
          // close, so the shared Odoo login is not hit per order.
          online: widget.sync.online,
          pendingToSync: () => widget.sync.pendingToSync,
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
          // Void always collects a manager PIN (never skipped by role) so the
          // approving manager is named on the audit trail and the deletion slip.
          authorizeVoidManager: () async {
            final who =
                await _authorizeManager(context, requirePin: true);
            return who?.name;
          },
          // Whose table a parked tab is sitting on, for the ways onto a bill that do
          // not go through the floor: merging one table into another.
          authorizeTabTable: (tab) => _authorizeTabTable(context, tab),
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
          // Lets the payment sheet hide methods the shop switched off in Settings.
          settings: widget.settings,
          // Floor section (and staff) allow-lists for this table's bill.
          allowedCategoryIds: _sectionAllowedCategories(session.current),
          allowedPaymentMethodIds: _sectionAllowedPayments(session.current),
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
          // The way off the counter: back to the floor home, where the next
          // order is started by a table or one of the table-less buttons.
          onNewOrder: _toFloor,
          // No open shift, no sale. Read per build so opening one on the shift
          // screen and coming straight back lifts the block with no restart.
          shiftOpen: () => widget.shifts.currentOpenShift() != null,
          onOpenShift: () => _openShift(context, session),
          onChanged: _publishActivity,
          onSignOut: _signOut,
          drawer: _buildDrawer(context, session),
          onOpenOrders: () => _openOrders(context, session),
          // The table asked for the bill. Paper only: nothing is settled, nothing
          // is pushed, and the order stays exactly as it is.
          onPrintBill: (order) => unawaited(_printBill(order)),
          // A payment that leaves the tab part paid gets its own detail slip:
          // what it covered and what is still owed, which no other paper says.
          onPartialPayment: (payment) =>
              unawaited(_printPartialPayment(payment)),
          // Holding parks the order and returns to the floor, where the table it
          // was parked on now reads as occupied. It does NOT fire the kitchen:
          // food reaches the kitchen only via the explicit Send to kitchen
          // button, so a cashier can park a tab that is still being built
          // without the line cooking it. The floor says it was parked, so the
          // confirmation is on the screen the cashier lands on rather than over
          // the row of buttons they tap next.
          //
          // Dishflow delivery: after park (Hold or auto after kitchen), reopen
          // the waiting list for that subtype so the next call is one tap away.
          onHold: () {
            final type = session.current.type;
            final delivery = type.isDelivery;
            _toFloor(confirmPark: true);
            if (delivery) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (!mounted) return;
                unawaited(_reopenDeliveryWaiting(context, type));
              });
            }
          },
          // Fire the kitchen ticket but keep the order on the counter. The
          // result is handed back so the screen can say what really happened.
          // Delivery also prints the unpaid bag slip on the delivery-receipt
          // printer — kitchen alone was leaving the driver with no paper.
          onSendToKitchen: () async {
            final order = session.current;
            final result = await _fireKitchen(order);
            if (order.type.isDelivery) {
              unawaited(_printDeliveryBagSlip(order));
            }
            return result;
          },
          // Re-fire every line (a lost or re-requested ticket), ignoring the
          // already-printed flag.
          onResendToKitchen: () =>
              _fireKitchen(session.current, only: session.current.lines, resend: true),
          onLineVoided: (line, reason, {approvedBy}) {
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
                title: 'ITEM VOIDED',
                reason: reason,
                approvedBy: approvedBy));
          },
          onPaid: (order) {
            _publishActivity();
            final sale = order as Order;
            // The money is booked, so the cashier goes back to the floor now,
            // ahead of the paper: the kitchen fire and the receipt below are
            // unawaited and own their own failures, and a till that waited on a
            // printer to release the screen would be a till that stops selling
            // when the printer does. A split check is the exception, because it
            // leaves the rest of the table open and still being settled.
            if (!session.hasLines) _toFloor();
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
      );

  /// The app shell's navigation, carried by the floor home and by the counter
  /// alike; everything a cashier or manager reaches occasionally lives here so
  /// neither screen is buried under buttons. Grouped by how often a cashier needs
  /// it: service first, then the money and staff admin, then the device itself.
  Widget _buildDrawer(BuildContext rootContext, PosSession session) {
    final isManager = widget.auth.signedIn?.isManager ?? false;
    final scheme = Theme.of(rootContext).colorScheme;

    Widget tile({
      required Key key,
      required IconData icon,
      required String label,
      Widget? trailing,
      required VoidCallback onTap,
    }) =>
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
          child: ListTile(
            key: key,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            leading: Icon(icon, color: scheme.onSurfaceVariant),
            title: Text(label,
                style:
                    const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
            trailing: trailing,
            onTap: onTap,
          ),
        );

    Widget section(String label) => Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 4),
          child: Text(label.toUpperCase(),
              style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.1,
                  color: scheme.onSurfaceVariant)),
        );

    return Drawer(
      child: SafeArea(
        child: ListView(children: [
          // Who holds the till right now, over the shop's colour: the first thing
          // a manager glancing at an unattended screen wants to know.
          Container(
            margin: const EdgeInsets.all(12),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  scheme.primary,
                  scheme.primary.withValues(alpha: 0.75),
                ],
              ),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Row(children: [
              CircleAvatar(
                radius: 22,
                backgroundColor: scheme.onPrimary.withValues(alpha: 0.2),
                child: Text(
                  _initialsOf(widget.auth.signedIn?.name ?? session.cashierId),
                  style: TextStyle(
                      color: scheme.onPrimary,
                      fontWeight: FontWeight.w800,
                      fontSize: 15),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(widget.auth.signedIn?.name ?? session.cashierId,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: scheme.onPrimary,
                            fontSize: 16,
                            fontWeight: FontWeight.w700)),
                    Text(
                        isManager
                            ? tr(rootContext, 'Manager')
                            : tr(rootContext, 'Cashier'),
                        style: TextStyle(
                            color: scheme.onPrimary.withValues(alpha: 0.85),
                            fontSize: 12)),
                  ],
                ),
              ),
              Icon(Icons.storefront,
                  color: scheme.onPrimary.withValues(alpha: 0.6)),
            ]),
          ),
          section(tr(rootContext, 'Service')),
          tile(
            key: const Key('nav-tables'),
            icon: Icons.table_bar,
            label: tr(rootContext, 'Tables'),
            onTap: () {
              Navigator.pop(rootContext);
              _toFloor();
            },
          ),
          tile(
            key: const Key('nav-open-orders'),
            icon: Icons.table_restaurant,
            label: tr(rootContext, 'Open orders'),
            trailing: session.heldCount > 0
                ? Chip(
                    visualDensity: VisualDensity.compact,
                    label: Text('${session.heldCount}'))
                : null,
            onTap: () {
              Navigator.pop(rootContext);
              _openOrders(rootContext, session);
            },
          ),
          tile(
            key: const Key('nav-store-orders'),
            icon: Icons.storefront_outlined,
            label: tr(rootContext, 'Store orders'),
            trailing: _storeOrderCount > 0
                ? Chip(
                    visualDensity: VisualDensity.compact,
                    label: Text('$_storeOrderCount'))
                : null,
            onTap: () {
              Navigator.pop(rootContext);
              _ackStoreOrderAlert();
              _openStoreOrders(rootContext, session);
            },
          ),
          tile(
            key: const Key('nav-history'),
            icon: Icons.receipt_long,
            label: tr(rootContext, 'Order history'),
            onTap: () {
              Navigator.pop(rootContext);
              _openHistory(rootContext);
            },
          ),
          tile(
            key: const Key('nav-kitchen'),
            icon: Icons.soup_kitchen,
            label: tr(rootContext, 'Kitchen display'),
            onTap: () {
              Navigator.pop(rootContext);
              _openKitchen(rootContext);
            },
          ),
          section(tr(rootContext, 'Money & staff')),
          tile(
            key: const Key('nav-report'),
            icon: Icons.bar_chart,
            label: tr(rootContext, 'Reports'),
            onTap: () async {
              Navigator.pop(rootContext);
              if (await _authorize(Permission.viewReports, rootContext)) {
                if (rootContext.mounted) _openReports(rootContext);
              }
            },
          ),
          tile(
            key: const Key('nav-shift'),
            icon: Icons.point_of_sale,
            label: tr(rootContext, 'Shift / cash-up'),
            onTap: () {
              Navigator.pop(rootContext);
              _openShift(rootContext, session);
            },
          ),
          tile(
            key: const Key('nav-attendance'),
            icon: Icons.how_to_reg_outlined,
            label: tr(rootContext, 'Attendance'),
            onTap: () {
              Navigator.pop(rootContext);
              _openAttendance(rootContext);
            },
          ),
          tile(
            key: const Key('nav-nosale'),
            icon: Icons.money_off,
            label: tr(rootContext, 'No sale (open drawer)'),
            onTap: () {
              Navigator.pop(rootContext);
              unawaited(_openDrawerNoSale(rootContext));
            },
          ),
          if (isManager)
            tile(
              key: const Key('nav-staff'),
              icon: Icons.badge_outlined,
              label: tr(rootContext, 'Staff'),
              onTap: () {
                Navigator.pop(rootContext);
                _openRoster(rootContext);
              },
            ),
          if (isManager)
            tile(
              key: const Key('nav-audit'),
              icon: Icons.fact_check_outlined,
              label: tr(rootContext, 'Audit log'),
              onTap: () {
                Navigator.pop(rootContext);
                Navigator.of(rootContext).push(MaterialPageRoute<void>(
                  builder: (_) => AuditLogScreen(audit: widget.audit),
                ));
              },
            ),
          section(tr(rootContext, 'This till')),
          tile(
            key: const Key('nav-settings'),
            icon: Icons.settings,
            label: tr(rootContext, 'Settings'),
            onTap: () {
              Navigator.pop(rootContext);
              _openSettingsHub(rootContext);
            },
          ),
          tile(
            key: const Key('nav-support'),
            icon: Icons.support_agent,
            label: tr(rootContext, 'Support & printers'),
            onTap: () {
              Navigator.pop(rootContext);
              _openDiagnostics(rootContext);
            },
          ),
          const SizedBox(height: 12),
        ]),
      ),
    );
  }

  /// Up to two initials from a display name, for the drawer's profile avatar.
  static String _initialsOf(String name) {
    final parts = name.trim().split(RegExp(r'\s+'));
    if (parts.isEmpty || parts.first.isEmpty) return '?';
    final first = parts.first.characters.first.toUpperCase();
    if (parts.length == 1) return first;
    return first + parts.last.characters.first.toUpperCase();
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
      builder: (_) => AttendanceScreen(
            users: widget.users,
            attendance: widget.attendance,
            auth: widget.auth,
          ),
    ));
  }

  void _openOrders(BuildContext context, PosSession session) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (sheetContext) => OpenOrdersScreen(
        orders: widget.orders.held(),
        formatAmount: PosApp.money,
        // The same gate the floor puts on a table tap. Reachable from the floor
        // drawer with no shift open, a recall from here used to land on the counter's
        // refusal with no way forward; the list itself stays readable, because
        // looking at what is parked is not selling.
        shiftOpen: () => widget.shifts.currentOpenShift() != null,
        onOpenShift: () => _openShift(sheetContext, session),
        // Through the same door as the floor, so table security cannot be walked
        // around by resuming the tab from the list instead of the plan. The list
        // closes itself on the tap, so the question about whose tab it is is asked
        // on the screen underneath, one microtask later.
        onRecall: (order) => scheduleMicrotask(() {
          final below = _navigator.currentContext;
          if (below != null) unawaited(_resumeTab(below, session, order));
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
          // A discarded tab is finished work, so it ends where every finished order
          // ends: on the floor, with that table free again.
          _toFloor();
        },
      ),
    ));
  }

  void _openStoreOrders(BuildContext context, PosSession session) {
    _ackStoreOrderAlert();
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => EcommerceOrdersScreen(
        settings: widget.settings,
        session: session,
        catalogue: widget.catalogue,
        formatAmount: PosApp.money,
        cashierName: widget.auth.signedIn?.name,
        onOpened: () {
          setState(() => _onCounter = true);
        },
      ),
    ));
  }

  void _openHistory(BuildContext context) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (historyContext) => OrderHistoryScreen(
        orders: widget.orders.recentAnywhere(limit: 1000),
        thisDeviceId: widget.deviceId,
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
      withdrawPush: (uuid) {
        if (widget.sync.state == SyncState.working) return false;
        // Odoo queue is the gate: if that sale is already on the wire, refuse.
        if (!widget.outboxStore.withdrawPending('order.push', uuid)) {
          return false;
        }
        // Mirror row may not exist (mirror off); pull it when it does.
        widget.outboxStore.withdrawPending(DishflowMirror.kind, uuid);
        return true;
      },
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
    // Mirror may already be in Firestore; PATCH status cancelled on the same doc.
    // A later re-pay enqueues status sale again.
    unawaited(DishflowMirror.enqueueCancelIfEnabled(
      outbox: widget.outbox,
      settings: widget.settings,
      order: order,
    ));
    widget.audit.record(session.cashierId, 'order.amended',
        detail: '${order.uuid}|${PosApp.money(oldTotal)}');
    _amending[order.uuid] = before;
    session.recall(order.uuid);
    _publishActivity();
    // Back to the counter, past the detail and the history list, so the reopened
    // order is on screen rather than behind two of them.
    if (context.mounted) Navigator.of(context).popUntil((r) => r.isFirst);
    _toCounter();
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
          DishflowMirror.enqueueIfEnabled(
            outbox: widget.outbox,
            settings: widget.settings,
            order: refund,
          );
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
        // Which tenders are cash, from Odoo rather than from their names: a
        // journal called "Cash drawer" is still cash.
        cashTenderIds: {
          for (final m in widget.catalogue.paymentMethods())
            if (m.isCash) m.id,
        },
        allOrders: widget.orders.recent(limit: 1000),
        // Flash sums every till: LAN replicas already sit in SQLite as paid/synced.
        shopOrders: widget.orders.recentAnywhere(limit: 2000),
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
        onPrintFlash: _printFlashReport,
        // What every exported report is headed with, so a downloaded file says
        // which shop it came from and who ran it.
        shopName: widget.settings.shopName ?? widget.config.shopName,
        ranBy: _session?.cashierId ?? '',
        drivers: widget.delivery?.drivers() ?? const [],
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
        fingerprints: widget.fingerprints,
        fingerprintStore: widget.fingerprintStore,
      ),
    ));
  }

  /// The floor plan. Tapping a table recalls the order parked on it, or starts a
  /// fresh dine-in seated at it, then drops back to the sell screen.
  /// Which tables read as occupied right now, and their running total + age, from
  /// the held orders plus the one on screen. Shared by the floor plan and the table
  /// picker so both colour tables identically.
  ({Set<String> occupied, Map<String, TableFloorInfo> info})
      _floorOccupancy(PosSession session) {
    // Every parked order in the shop, not just this till's. A table busy on the bar
    // till has to read as busy here, or two cashiers seat the same table and the
    // second guest's food goes to a bill nobody is holding.
    final byTable = <String, List<Order>>{};
    void add(Order o) {
      final label = o.tableLabel;
      if (label == null || label.isEmpty) return;
      final list = byTable.putIfAbsent(label, () => []);
      if (list.any((e) => e.uuid == o.uuid)) return;
      list.add(o);
    }

    for (final o in widget.orders.occupyingAnywhere()) {
      add(o);
    }
    // The order on screen also occupies its table, or opening the floor and
    // tapping it would start a second order on the same table.
    add(session.current);
    return (
      occupied: byTable.keys.toSet(),
      info: {
        for (final e in byTable.entries) e.key: TableFloorInfo.fromTabs(e.value),
      },
    );
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
        sectionsAtSide: widget.settings.floorSectionsSide,
        // The same rule as the floor home, or seating from the counter would be the
        // way around it: a waiter refused a tile could otherwise pick it here.
        assignments: widget.assignments?.byTable() ?? const {},
        staff: [
          for (final u in widget.users.all())
            (id: u.id, name: u.name, active: u.active),
        ],
        myCashierId: session.cashierId,
        mayOpenAnyTable: widget.assignments == null ||
            widget.settings.roleCan(
                widget.auth.signedIn?.role ?? 'cashier', Permission.openAnyTable),
        authorizeForeignTable: () =>
            _authorize(Permission.openAnyTable, routeContext),
        // Picking is only about which table; what is being seated was decided on
        // the order already on screen.
        onOpenTable: (t, _) => Navigator.of(routeContext).pop(t.name),
      ),
    ));
  }

  /// Resume one of the parked deliveries, start a new one, or back out.
  ///
  /// Which Dishflow delivery subtype to start when the floor has more than one.
  Future<OrderType?> _pickDeliverySubtype(
          BuildContext context, List<OrderType> types) =>
      showDialog<OrderType>(
        context: context,
        barrierColor: const Color(0x99000000),
        builder: (ctx) => Dialog(
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                  child: Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: Text(tr(ctx, 'Delivery'),
                        style: const TextStyle(
                            fontWeight: FontWeight.w800, fontSize: 16)),
                  ),
                ),
                for (final t in types)
                  ListTile(
                    key: Key('pick-delivery-${t.name}'),
                    leading: const Icon(Icons.delivery_dining),
                    title: Text(tr(ctx, t.label)),
                    onTap: () => Navigator.pop(ctx, t),
                  ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        ),
      );

  /// Full screen of parked bags for [type]: resume one, start new, or back out.
  ///
  /// Dishflow shows suspended deliveries as a panel after the subtype pick; we
  /// use a dedicated route so the cashier gets a real screen, not a sheet.
  Future<Object?> _pickParkedDelivery(
      BuildContext context, OrderType type, List<Order> parked) {
    final session = _session;
    return Navigator.of(context)
        .push<Object?>(MaterialPageRoute(
          builder: (_) => DeliveryWaitingScreen(
            type: type,
            parked: parked,
            formatAmount: PosApp.money,
            drivers: widget.delivery?.drivers() ?? const [],
            onAssignDriver: session == null
                ? null
                : (order, driver) {
                    session.assignDriverTo(order, driver);
                  },
            onSetStatus: session == null
                ? null
                : (order, status) {
                    session.setDeliveryStatus(order, status);
                  },
          ),
        ))
        .then((v) => v ?? 'cancel');
  }

  /// After a delivery bag is parked (Hold or kitchen auto-suspend), land back on
  /// that subtype's waiting list — Dishflow's post-suspend panel.
  Future<void> _reopenDeliveryWaiting(BuildContext context, OrderType type) async {
    final session = _session;
    if (session == null || !mounted) return;
    final parked =
        widget.orders.held().where((o) => o.type == type).toList();
    final resume = await _pickParkedDelivery(context, type, parked);
    if (resume == 'cancel' || !mounted) return;
    setState(() {
      if (resume is Order) {
        session.recall(resume.uuid);
      } else {
        session.startFresh(type);
      }
      _onCounter = true;
    });
  }

  /// The kinds of sale the signed-in role may open here: what the shop offers at
  /// all, narrowed by what this role may ring. Unrestricted until a manager says
  /// otherwise on either.
  Set<OrderType> get _allowedOrderTypes => widget.settings
      .availableOrderTypesFor(widget.auth.signedIn?.role ?? 'cashier');

  /// What the floor says about the bill that was just parked, or null when there is
  /// nothing to say. Names the table when there was one, because "on table 5" is
  /// what a waiter checks the tile against.
  String? _parkedNotice(BuildContext context) {
    final parked = _justParked;
    if (parked == null) return null;
    final table = parked.table;
    if (table == null || table.isEmpty) {
      return tr(context, 'Order parked. Recall it from Open orders.');
    }
    return '${tr(context, 'Order parked on table')} $table';
  }

  /// The till's home screen: the room, drawn as the manager laid it out.
  ///
  /// A restaurant works off its floor, so this is what a cashier lands on and what
  /// every finished order comes back to. Nothing on it is a route: it is rebuilt
  /// with the shell, which is how a tab settled on another till shows up here
  /// without anybody refreshing anything.
  Widget _floorHome(PosSession session) => Builder(
        // Builder, so navigation targets the Navigator inside this MaterialApp.
        builder: (floorContext) {
          final occ = _floorOccupancy(session);
          final allowed = _allowedOrderTypes;
          return TableFloorScreen(
            // The same drawer the counter carries. The floor is home now, so support,
            // reprints, reports and the shift screen have to be reachable from it.
            drawer: _buildDrawer(floorContext, session),
            // No open shift, no order. Read per build so opening one and coming
            // straight back lifts the block with no restart, exactly as the counter
            // reads it.
            shiftOpen: () => widget.shifts.currentOpenShift() != null,
            onOpenShift: () => _openShift(floorContext, session),
            // End shift → End of Day close (not sign-out). Sign-out stays in the drawer.
            onEndShift: () => _openShift(floorContext, session, startClose: true),
            onSignOut: _signOut,
            // The confirmation for the bill that was just parked, said up here where
            // it cannot cover the button row along the bottom.
            parkedNotice: _parkedNotice(floorContext),
            // Read as the floor is built, so a close that arrives over the fabric shows
            // the next time a waiter looks at the plan rather than at the next restart.
            dayNotice: _dayCloseNotice(floorContext)?.text,
            blockNewOrders: _dayCloseNotice(floorContext)?.blocking ?? false,
            store: widget.tables,
            occupiedLabels: occ.occupied,
            occupiedInfo: occ.info,
            formatAmount: PosApp.money,
            // The floor's own rules, on the screen a manager already opens to lay the
            // room out.
            settings: widget.settings,
            catalogue: widget.catalogue,
            onTransferTables: () => unawaited(_transferTables(floorContext)),
            onEditPreorders: () => unawaited(_editPreorders(floorContext)),
            authorize: () => _authorize(Permission.openSettings, floorContext),
            // The book, so a table with guests due shortly says so on the plan.
            reservations: widget.reservations,
            // The rooms down the side, where the shop reads them fastest.
            sectionsAtSide: widget.settings.floorSectionsSide,
            // Who works which table, and who is standing here. Read per build, so a
            // manager moving a section on a handheld reaches this floor the next time
            // a waiter looks at it.
            assignments: widget.assignments?.byTable() ?? const {},
            staff: [
              // Everyone, so a waiter taken off the roster mid-shift is still named on
              // the tables they are holding; the picker offers only the active ones.
              for (final u in widget.users.all())
                (id: u.id, name: u.name, active: u.active),
            ],
            onDuty: [
              for (final e in widget.attendance.onNow())
                if (widget.users.byId(e.staffId) case final u?)
                  (id: u.id, name: u.name),
            ],
            onOpenAttendance: () => _openAttendance(floorContext),
            myCashierId: session.cashierId,
            // A role that may open anybody's table sees the names and no locks. Read
            // from the role rather than from the account being a manager, so a shop
            // that runs a head-waiter role can grant it without granting the rest.
            mayOpenAnyTable: widget.assignments == null ||
                widget.settings.roleCan(
                    widget.auth.signedIn?.role ?? 'cashier', Permission.openAnyTable),
            authorizeForeignTable: () =>
                _authorize(Permission.openAnyTable, floorContext),
            onAssign: widget.assignments == null
                ? null
                : (table, cashierId) => _assignTable(table, cashierId),
            authorizeAssign: () => _authorize(Permission.assignTables, floorContext),
            // The nudge only for whoever may act on it without being asked for a PIN.
            assignHint: widget.settings
                .roleCan(widget.auth.signedIn?.role ?? 'cashier', Permission.assignTables),
            // Kept in the shell, so a round trip to the counter comes back to the
            // room the waiter was working and the seating they had chosen.
            section: _floorSection,
            onSectionChanged: (s) => _floorSection = s,
            seatAs: _floorSeatAs,
            onSeatAsChanged: (t) => _floorSeatAs = t,
            // What a table tap may open. A to-go is seated like a dine-in when the
            // shop takes them, and the waiter says which before tapping the table.
            seatTypes: [
              for (final t in OrderType.values)
                if (t.seatsAtTable && allowed.contains(t)) t,
            ],
            // The table-less ways to start an order, straight from the floor home.
            // Each starts a fresh order of that type and opens the counter on it. A
            // type this role may not ring has no button rather than a button that
            // refuses.
            onToGo: !allowed.contains(OrderType.toGo)
                ? null
                : () => _startOrder(session, OrderType.toGo),
            onTakeaway: !allowed.contains(OrderType.takeaway)
                ? null
                : () => _startOrder(session, OrderType.takeaway),
            onDelivery: ![
                      OrderType.deliveryFromCompany,
                      OrderType.storeDelivery,
                      OrderType.carDelivery,
                    ].any(allowed.contains)
                ? null
                : () async {
                    final deliveryTypes = [
                      OrderType.deliveryFromCompany,
                      OrderType.storeDelivery,
                      OrderType.carDelivery,
                    ].where(allowed.contains).toList();
                    final chosen = deliveryTypes.length == 1
                        ? deliveryTypes.first
                        : await _pickDeliverySubtype(floorContext, deliveryTypes);
                    if (chosen == null || !mounted) return;
                    // Always open the waiting screen for this subtype (Dishflow
                    // panel): resume a parked bag, start new, or back out.
                    final parked = widget.orders
                        .held()
                        .where((o) => o.type == chosen)
                        .toList();
                    final resume = await _pickParkedDelivery(
                        floorContext, chosen, parked);
                    if (resume == 'cancel' || !mounted) return;
                    setState(() {
                      if (resume is Order) {
                        session.recall(resume.uuid);
                      } else {
                        session.startFresh(chosen);
                      }
                      _onCounter = true;
                    });
                  },
            onOpenTable: (t, seatAs) async {
              // Tapping the table the current order is already seated at just returns
              // to it rather than parking it and starting a duplicate, unless more
              // than one bill already sits there and the waiter has to pick.
              if (session.current.tableLabel == t.name &&
                  session.current.lines.isNotEmpty) {
                final others = widget.orders.occupyingAnywhere().where(
                    (o) => o.tableLabel == t.name && o.uuid != session.current.uuid);
                if (others.isEmpty) {
                  _toCounter();
                  return;
                }
              }
              final tabs = [
                for (final o in widget.orders.occupyingAnywhere())
                  if (o.tableLabel == t.name) o,
              ];
              if (session.current.tableLabel == t.name &&
                  !tabs.any((o) => o.uuid == session.current.uuid) &&
                  (session.current.lines.isNotEmpty ||
                      session.current.tableLabel != null)) {
                tabs.add(session.current);
              }
              final local = [
                for (final o in tabs)
                  if (o.deviceId == widget.deviceId) o,
              ];
              if (local.isEmpty && tabs.isNotEmpty) {
                final tab = tabs.first;
                final signed = widget.auth.signedIn;
                final me = session.cashierId;
                final isOpener =
                    tab.cashierId == me || tab.cashierId == signed?.id;
                final isManager = signed?.isManager ?? false;
                final canTake = widget.lan != null &&
                    (widget.settings.lanAllowTakeover ||
                        isOpener ||
                        isManager);
                if (canTake) {
                  unawaited(_takeOverTab(floorContext, session, tab,
                      asOpener: isOpener, asManager: isManager));
                  return;
                }
                ScaffoldMessenger.of(floorContext).showSnackBar(SnackBar(
                  content: Text(tr(floorContext,
                      'This table is open on another device. Settle it there.')),
                ));
                return;
              }
              if (local.isNotEmpty) {
                Order? chosen;
                if (local.length == 1) {
                  chosen = local.first;
                } else {
                  final pick = await _pickTableTab(floorContext, local);
                  if (!floorContext.mounted) return;
                  if (pick == null) return;
                  if (pick == 'new') {
                    if (!allowed.contains(seatAs)) {
                      ScaffoldMessenger.of(floorContext).showSnackBar(SnackBar(
                        content: Text(tr(floorContext,
                            'This role does not open dine-in orders.')),
                      ));
                      return;
                    }
                    setState(() {
                      session.openLinkedTab(t.name);
                      _onCounter = true;
                    });
                    return;
                  }
                  chosen = pick as Order;
                }
                unawaited(_resumeTab(floorContext, session, chosen));
                return;
              }
              if (!allowed.contains(seatAs)) {
                ScaffoldMessenger.of(floorContext).showSnackBar(SnackBar(
                  content: Text(
                      tr(floorContext, 'This role does not open dine-in orders.')),
                ));
                return;
              }
              final cfg = widget.settings.sectionConfig(t.section);
              var type = seatAs;
              if (cfg.defaultOrderType != null &&
                  allowed.contains(cfg.defaultOrderType)) {
                type = cfg.defaultOrderType!;
              }
              String? openedBy;
              if (widget.settings.askCashierOnOpen ||
                  widget.users.active().length > 1) {
                if (!floorContext.mounted) return;
                openedBy = await _pickOpenerWithPin(floorContext);
                if (openedBy == null) return;
              }
              final dineIn = type == OrderType.dineIn;
              final askGuests =
                  cfg.requireGuestCount ?? widget.settings.askGuestCount;
              int? covers;
              if (dineIn && askGuests) {
                if (!floorContext.mounted) return;
                covers = await _askGuestCount(floorContext, t.seats);
                if (covers == null) return;
              } else if (dineIn && cfg.requireGuestCount == false) {
                covers = 1;
              }
              if (!mounted) return;
              setState(() {
                session.startFresh(type);
                session.claimSeat(t.name);
                final seated = covers ?? t.seats;
                if (dineIn && seated > 0) session.setGuestCount(seated);
                if (dineIn) _addPreorders(session, t, guests: seated);
                if (openedBy != null) session.rebindCashier(openedBy);
                _onCounter = true;
              });
              if (openedBy != null) _assignTable(t, openedBy);
            },
          );
        },
      );

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

  void _announceShiftOpen(PosSession session) => widget.lan?.announceShiftOpen(
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

  /// Which bill to resume when more than one sits on the same table, or a new
  /// check on that table. Null is backing out.
  Future<Object?> _pickTableTab(BuildContext context, List<Order> tabs) {
    return showModalBottomSheet<Object>(
      context: context,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final o in tabs)
              ListTile(
                key: Key('table-tab-${o.uuid}'),
                title: Text(
                  o.orderNo ??
                      '${tr(ctx, 'Tab')} ${o.uuid.substring(0, 6).toUpperCase()}',
                ),
                subtitle: Text(
                  '${PosApp.money(o.total)} · ${o.lines.length} ${tr(ctx, 'item(s)')}',
                ),
                onTap: () => Navigator.pop(ctx, o),
              ),
            ListTile(
              key: const Key('table-tab-new'),
              leading: const Icon(Icons.add),
              title: Text(tr(ctx, 'New bill on this table')),
              onTap: () => Navigator.pop(ctx, 'new'),
            ),
          ],
        ),
      ),
    );
  }

  /// Bring a parked tab back to the counter, asking whose it is first when the shop
  /// has said tabs belong to the cashier who opened them.
  ///
  /// One door for every way a tab is resumed, so the answer cannot be walked around
  /// by opening it from the other screen. A resumed tab lands on the counter, from
  /// the floor tile and from the Open orders list alike.
  Future<void> _resumeTab(BuildContext context, PosSession session, Order tab) async {
    if (!await _authorizeTab(context, tab)) return;
    if (!mounted) return;
    setState(() {
      session.recall(tab.uuid);
      _onCounter = true;
    });
    _publishActivity();
  }

  /// Whether the table a parked tab is sitting on is one this person may work.
  ///
  /// The floor already refuses the tile, but a parked tab is also reachable from the
  /// Open orders list, and a rule that only holds on one screen is not a rule. Asked
  /// through the same permission, so a manager passes without being prompted and a
  /// waiter is told whose section they are reaching into before the PIN box appears.
  ///
  /// Free on a tab with no table (takeaway, delivery) and on a table name the floor
  /// plan does not know: nobody has been given a table that was never drawn.
  Future<bool> _authorizeTabTable(BuildContext context, Order tab) async {
    final store = widget.assignments;
    final label = tab.tableLabel;
    if (store == null || label == null || label.isEmpty) return true;
    final table = widget.tables.byName(label);
    if (table == null) return true;
    final owner = store.cashierFor(table.id);
    if (owner == null || owner == _session?.cashierId) return true;
    final who = widget.users.byId(owner)?.name ?? owner;
    if (!widget.settings
        .roleCan(widget.auth.signedIn?.role ?? 'cashier', Permission.openAnyTable)) {
      showToast(context, '${tr(context, 'This table belongs to')} $who',
          kind: ToastKind.error);
    }
    final ok = await _authorize(Permission.openAnyTable, context);
    widget.audit.record(_session?.cashierId ?? 'unknown',
        ok ? 'table.foreign_opened' : 'table.foreign_refused',
        detail: '$label|$owner');
    return ok;
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
    if (!await _authorizeTabTable(context, tab)) return false;
    if (!widget.settings.tableSecurity) return true;
    final who = _session?.cashierId;
    if (who == null || tab.cashierId == who) return true;
    // The table question above may have put a dialog up and taken it down again, so
    // the screen this prompt belongs to has to still be there before it is asked.
    if (!context.mounted) return false;
    final owner = widget.users.byId(tab.cashierId);
    final pin = await _promptPin(
      context,
      tr(context, 'This tab belongs to another cashier'),
      tr(context, 'Enter their PIN, or a manager PIN.'),
      subject: owner?.name ?? tab.cashierId,
    );
    if (pin == null || pin.isEmpty) return false;
    final ok = await widget.auth.authorizeCashier(tab.cashierId, pin) ||
        (await widget.auth.authorizeManager(pin)) != null;
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
  ///
  /// Touch-first: dots + on-screen pad (no OS soft keyboard), same as the lock
  /// screen. A restaurant till is a fingertip, not a keyboard.
  Future<String?> _promptPin(BuildContext context, String title, String message,
      {required String subject}) {
    var pin = '';
    return showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) {
          final scheme = Theme.of(ctx).colorScheme;
          return AlertDialog(
            title: Text(title),
            content: SizedBox(
              width: 300,
              child: SingleChildScrollView(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Text('$subject. $message'),
                  const SizedBox(height: 10),
                  Container(
                    key: const Key('tab-pin'),
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 12),
                    decoration: BoxDecoration(
                      color:
                          scheme.surfaceContainerHighest.withValues(alpha: 0.5),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: scheme.outlineVariant),
                    ),
                    child: Text(
                      pin.isEmpty ? '····' : '•' * pin.length,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 26,
                        letterSpacing: 8,
                        fontWeight: FontWeight.w700,
                        color: pin.isEmpty
                            ? scheme.onSurfaceVariant
                            : scheme.primary,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  NumericKeypad(
                    decimal: false,
                    compact: true,
                    onKey: (k) {
                      if (pin.length >= 6) return;
                      setLocal(() => pin += k);
                    },
                    onBackspace: () => setLocal(() => pin =
                        pin.isEmpty ? pin : pin.substring(0, pin.length - 1)),
                    onClear: () => setLocal(() => pin = ''),
                  ),
                ]),
              ),
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: Text(tr(ctx, 'Cancel'))),
              FilledButton(
                key: const Key('tab-pin-ok'),
                onPressed: pin.isEmpty ? null : () => Navigator.pop(ctx, pin),
                child: Text(tr(ctx, 'Open tab')),
              ),
            ],
          );
        },
      ),
    );
  }

  /// Move every tab one cashier is holding to another one.
  ///
  /// The end of a waiter's shift with four tables still sitting: without this the
  /// tabs stay locked to somebody who has gone home and land on their flash. Only
  /// parked tabs move, never a paid sale, so who took the money is never rewritten.
  /// Edit what a table opens with, from the screen a manager already opens to lay the
  /// room out. Gated like any other setting: these lines land on every bill.
  Future<void> _editPreorders(BuildContext context) async {
    if (!await _authorize(Permission.openSettings, context)) return;
    if (!context.mounted) return;
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => TablePreorderScreen(
        settings: widget.settings,
        tables: widget.tables,
        catalogue: widget.catalogue,
      ),
    ));
    if (mounted) setState(() {});
  }

  /// Put the lines a table opens with on a bill that has just been seated.
  ///
  /// Only on a fresh seating, never on a recall: a tab picked back up already has its
  /// cover charge, and adding it again on every visit to the table is how a guest ends
  /// up paying for the water four times. They are ordinary lines from here on, so a
  /// waiter takes one off with the void they already have.
  ///
  /// A line naming a product the catalogue no longer has is skipped rather than
  /// guessed at: a deleted product must not stop a table being seated.
  void _addPreorders(PosSession session, PosTable table, {required int guests}) {
    // A table typed in by hand rather than drawn on the plan is in no room, so it
    // follows no room's list: guessing a section for it would put the cover charge on
    // a bill nobody set it for.
    final onFloor = widget.tables.byId(table.id) ?? widget.tables.byName(table.name);
    if (onFloor == null) return;
    final lines = widget.settings
        .preordersFor(tableId: onFloor.id, section: onFloor.section);
    if (lines.isEmpty) return;
    var added = 0;
    for (final line in lines) {
      final product = widget.catalogue.byId(line.productId);
      if (product == null || !product.active) continue;
      session.addProduct(product, qty: line.quantityFor(guests));
      added++;
    }
    if (added > 0) {
      widget.audit.record(_session?.cashierId ?? 'system', 'table.preorder',
          detail: '${table.name}|$added line(s)');
    }
  }

  /// Give one table to a waiter, or hand it back to nobody with a null cashier.
  ///
  /// Audited either way: which waiter had which table is what a shop reconstructs a
  /// disputed bill from, and the row itself only ever holds the current answer.
  void _assignTable(PosTable table, String? cashierId) {
    final store = widget.assignments;
    if (store == null) return;
    final by = _session?.cashierId ?? 'system';
    if (cashierId == null) {
      store.clear(table.id);
      widget.audit.record(by, 'table.unassigned', detail: table.name);
    } else {
      store.assign(table.id, cashierId, by: by);
      widget.audit
          .record(by, 'table.assigned', detail: '${table.name}|$cashierId');
    }
    // The floor reads the assignments off this build, so the shell is what has to
    // rebuild: the screen's own setState would redraw the same map it was handed and
    // leave the manager looking at the name they just replaced.
    if (mounted) setState(() {});
  }

  /// Hand the whole room back at the end of a shift.
  ///
  /// Called as the Z lands, because a table still assigned to whoever went home is a
  /// table the next service cannot open. Best effort and never in the way: the shift
  /// is already closed by the time this runs, so nothing here can hold up a cash-up.
  void _clearAssignments(PosSession session) {
    final store = widget.assignments;
    if (store == null || store.isEmpty) return;
    final cleared = store.clearAll();
    widget.audit.record(session.cashierId, 'tables.unassigned_all',
        detail: '$cleared table(s)');
  }

  Future<void> _transferTables(BuildContext context) async {
    if (await _authorizeManager(context) == null) return;
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
      // Floor ownership follows the tabs, or the next waiter still sees the old
      // name on the tile after the bills have moved.
      final label = tab.tableLabel;
      if (label != null && widget.assignments != null) {
        final table = widget.tables.byName(label);
        if (table != null) _assignTable(table, to);
      }
    }
    widget.audit.record(_session?.cashierId ?? 'system', 'tables.transferred',
        detail: '$from->$to|${moved.length} tab(s)');
    if (!context.mounted) return;
    setState(() {});
    showToast(context, '${tr(context, 'Tabs moved')}: ${moved.length}',
        kind: ToastKind.success);
  }

  /// Staff offered when opening a table: only people on the clock. The manager
  /// unlocks the till; cashiers appear here after Attendance → Clock in.
  List<String> _openerCandidates() {
    final onDuty = widget.attendance.onNow().map((e) => e.staffId).toSet();
    final active = widget.users.active();
    final real = active.where((u) => u.id != BootstrapCashier.id).toList();
    final pool = real.isEmpty ? active : real;
    return pool.where((u) => onDuty.contains(u.id)).map((u) => u.id).toList();
  }

  /// Pick who opens the table: fingerprint when the reader is up, else PIN.
  ///
  /// Manager PIN is not a substitute here: attribution must match who is
  /// actually opening. Managers elevate elsewhere (resume lock, voids, etc.).
  Future<String?> _pickOpenerWithPin(BuildContext context) async {
    final ids = _openerCandidates();
    if (ids.isEmpty) {
      if (context.mounted) {
        showToast(
          context,
          tr(context, 'Clock in from Attendance before opening a table'),
          kind: ToastKind.error,
        );
      }
      return null;
    }

    final fp = widget.fingerprints;
    if (fp != null) {
      final result = await showFingerprintOrPin(
        context,
        fingerprints: fp,
        title: tr(context, 'Who is opening this table?'),
        message: tr(context, 'Fingerprint or this person\'s PIN'),
        prepareTemplates: () async {
          await FingerprintAgentLauncher().ensureRunning();
          await widget.fingerprintStore?.pushToAgent();
        },
      );
      if (result == null || !context.mounted) return null;
      if (result.isFingerprint) {
        final uid = result.matchedUserId!;
        if (!ids.contains(uid)) {
          showToast(
            context,
            tr(context, 'That person is not clocked in'),
            kind: ToastKind.error,
          );
          return null;
        }
        return uid;
      }
      // PIN path: pick who, then verify with the PIN they already typed.
      final picked = await _pickOpenerDropdown(
        context,
        tr(context, 'Who is opening this table?'),
        ids,
      );
      if (picked == null || !context.mounted) return null;
      final pin = result.pin ?? '';
      if (pin.isEmpty) {
        final user = widget.users.byId(picked);
        final typed = await _promptPin(
          context,
          tr(context, 'Confirm with PIN'),
          tr(context, 'Enter this person\'s PIN'),
          subject: user?.name ?? picked,
        );
        if (typed == null || typed.isEmpty) return null;
        final ok = await widget.auth.authorizeCashier(picked, typed);
        if (!ok) {
          if (context.mounted) {
            showToast(context, tr(context, 'Incorrect PIN'),
                kind: ToastKind.error);
          }
          return null;
        }
        return picked;
      }
      final ok = await widget.auth.authorizeCashier(picked, pin);
      if (!ok) {
        if (context.mounted) {
          showToast(context, tr(context, 'Incorrect PIN'),
              kind: ToastKind.error);
        }
        return null;
      }
      return picked;
    }

    final picked = await _pickOpenerDropdown(
      context,
      tr(context, 'Who is opening this table?'),
      ids,
    );
    if (picked == null || !context.mounted) return null;
    final user = widget.users.byId(picked);
    final pin = await _promptPin(
      context,
      tr(context, 'Confirm with PIN'),
      tr(context, 'Enter this person\'s PIN'),
      subject: user?.name ?? picked,
    );
    if (pin == null || pin.isEmpty) return null;
    final ok = await widget.auth.authorizeCashier(picked, pin);
    if (!ok) {
      if (context.mounted) {
        showToast(context, tr(context, 'Incorrect PIN'), kind: ToastKind.error);
      }
      return null;
    }
    return picked;
  }

  /// Dropdown of who may open the table (on-duty staff).
  Future<String?> _pickOpenerDropdown(
      BuildContext context, String title, List<String> ids) {
    final byId = {for (final u in widget.users.active()) u.id: u.name};
    String? selected = ids.length == 1 ? ids.first : null;
    return showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: Text(title),
          content: DropdownButtonFormField<String>(
            key: const Key('opener-dropdown'),
            value: selected,
            isExpanded: true,
            decoration: InputDecoration(
              labelText: tr(ctx, 'Select user'),
              border: const OutlineInputBorder(),
            ),
            items: [
              for (final id in ids)
                DropdownMenuItem<String>(
                  value: id,
                  child: Text(byId[id] ?? id),
                ),
            ],
            onChanged: (v) => setLocal(() => selected = v),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(tr(ctx, 'Cancel')),
            ),
            FilledButton(
              key: const Key('opener-ok'),
              onPressed:
                  selected == null ? null : () => Navigator.pop(ctx, selected),
              child: Text(tr(ctx, 'OK')),
            ),
          ],
        ),
      ),
    );
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
  /// opened. The opener may take their own tab; anyone else needs manager approval
  /// (or shop-wide takeovers switched on).
  Future<void> _takeOverTab(
    BuildContext context,
    PosSession session,
    Order tab, {
    bool asOpener = false,
    bool asManager = false,
  }) async {
    final lan = widget.lan;
    if (lan == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr(ctx, 'Take over this tab?')),
        content: Text(tr(
            ctx,
            'It is open on another device. That device is asked first. If it '
                'does not answer, this till takes the tab so you can settle it.')),
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
    if (!asOpener) {
      if (!(widget.auth.signedIn?.isManager ?? false)) {
        if (await _authorizeManager(context) == null) return;
      }
    }
    final result = await lan.claim(
      tab,
      cashier: session.cashierId,
      asManager: asManager ||
          (widget.auth.signedIn?.isManager ?? false) ||
          !asOpener,
    );
    if (!context.mounted) return;
    if (result.order == null) {
      showToast(
          context,
          tr(
              context,
              result.refusal == LanClaimRefusal.ownerUnreachable
                  ? 'That device did not answer and this till has no copy of the tab.'
                  : 'That device would not hand the tab over.'),
          kind: ToastKind.error);
      return;
    }
    setState(() {
      session.recall(tab.uuid);
      _onCounter = true;
    });
    _publishActivity();
  }

  /// How many are sitting at the table just tapped, picked from a list of every
  /// number the table takes. Returns null when the waiter backs out, which
  /// aborts the seating rather than opening a tab nobody asked for.
  ///
  /// One to the table's own seat count, not a handful of round numbers: a waiter
  /// seating five at a six-top was picking 6 and the covers on the bill were wrong
  /// from the first tap. A table whose seat count was never set falls back to eight,
  /// which is a guess only for a floor plan that never said.
  Future<int?> _askGuestCount(BuildContext context, int seats) {
    // Bounded so a banquet table cannot produce a list the till cannot draw; the
    // menu scrolls above that anyway.
    final max = seats > 0 ? (seats > 40 ? 40 : seats) : 8;
    return showDialog<int>(
      context: context,
      builder: (ctx) {
        var otherMode = false;
        final otherCtrl = TextEditingController();
        return StatefulBuilder(
          builder: (ctx, setSt) {
            Widget square({
              required Key key,
              required String label,
              required VoidCallback onTap,
              double fontSize = 22,
            }) {
              return Material(
                color: Colors.transparent,
                child: InkWell(
                  key: key,
                  onTap: onTap,
                  borderRadius: BorderRadius.circular(14),
                  child: Ink(
                    decoration: BoxDecoration(
                      color: AppColors.primary.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: AppColors.primary.withValues(alpha: 0.55),
                        width: 1.5,
                      ),
                    ),
                    child: Center(
                      child: Text(
                        label,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: fontSize,
                          fontWeight: FontWeight.w800,
                          color: AppColors.brandNavy,
                        ),
                      ),
                    ),
                  ),
                ),
              );
            }

            if (otherMode) {
              return AlertDialog(
                key: const Key('guest-count-other'),
                title: Text(tr(ctx, 'How many guests?')),
                content: TextField(
                  key: const Key('guests-other-input'),
                  controller: otherCtrl,
                  autofocus: true,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: tr(ctx, 'Number of guests'),
                    border: const OutlineInputBorder(),
                  ),
                  onSubmitted: (v) {
                    final n = int.tryParse(v.trim());
                    if (n != null && n > 0) Navigator.pop(ctx, n);
                  },
                ),
                actions: [
                  TextButton(
                    onPressed: () => setSt(() => otherMode = false),
                    child: Text(tr(ctx, 'Back')),
                  ),
                  FilledButton(
                    key: const Key('guests-other-ok'),
                    onPressed: () {
                      final n = int.tryParse(otherCtrl.text.trim());
                      if (n != null && n > 0) Navigator.pop(ctx, n);
                    },
                    child: Text(tr(ctx, 'OK')),
                  ),
                ],
              );
            }

            return AlertDialog(
              key: const Key('guest-count-prompt'),
              title: Text(tr(ctx, 'How many guests?')),
              content: SizedBox(
                key: const Key('guest-count-dropdown'),
                width: 360,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 400),
                  child: GridView.builder(
                    shrinkWrap: true,
                    // Seat numbers + Other.
                    itemCount: max + 1,
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 4,
                      mainAxisSpacing: 10,
                      crossAxisSpacing: 10,
                      childAspectRatio: 1,
                    ),
                    itemBuilder: (_, i) {
                      if (i == max) {
                        return square(
                          key: const Key('guests-other'),
                          label: tr(ctx, 'Other'),
                          fontSize: 14,
                          onTap: () => setSt(() => otherMode = true),
                        );
                      }
                      final n = i + 1;
                      return square(
                        key: Key('guests-$n'),
                        label: '$n',
                        onTap: () => Navigator.pop(ctx, n),
                      );
                    },
                  ),
                ),
              ),
              actions: [
                TextButton(
                  key: const Key('guests-cancel'),
                  onPressed: () => Navigator.pop(ctx),
                  child: Text(tr(ctx, 'Cancel')),
                ),
              ],
            );
          },
        );
      },
    );
  }

  /// The settings hub: one door onto everything a manager configures on the device.
  void _openSettingsHub(BuildContext context) {
    void refresh() {
      setState(() {});
      _syncStoreOrderWatchForStation();
    }
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
        title: 'This device type',
        subtitle: widget.settings.stationType == StationType.delivery
            ? 'Delivery station — store-order alerts on'
            : 'Counter — store-order alerts off',
        icon: Icons.devices,
        keyValue: 'set-station-type',
        group: 'Hardware',
        onTap: () => pushGated(
            Permission.openSettings,
            StationSettingsScreen(
              settings: widget.settings,
              onChanged: refresh,
            )),
      ),
      SettingsEntry(
        title: 'Fingerprint setup',
        subtitle: 'Auto-install libraries / see errors on this PC',
        icon: Icons.fingerprint,
        keyValue: 'set-fingerprint-diag',
        group: 'Hardware',
        onTap: () => pushGated(
            Permission.openSettings, const FingerprintDiagScreen()),
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
      SettingsEntry(
        title: 'Dishflow owner mirror',
        subtitle: 'Show paid sales in owner Flash when online',
        icon: Icons.cloud_upload_outlined,
        keyValue: 'set-dishflow',
        group: 'Server',
        onTap: () => pushGated(
            Permission.openSettings,
            DishflowMirrorSettingsScreen(
              settings: widget.settings,
              sender: widget.dishflow?.sender,
              onChanged: () {
                widget.dishflow?.apply(widget.settings);
                widget.settings.publishShopBundle();
                refresh();
              },
            )),
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
        title: 'Menu',
        subtitle: 'Items, categories and the choices a cashier is asked',
        icon: Icons.restaurant_menu,
        keyValue: 'set-menu',
        group: 'Shop',
        // The menu is what the shop sells, so it sits behind the same gate as the
        // rest of the shop's configuration. Everything it writes is local and works
        // with the line down; only the "find it in Odoo" pick list needs a server,
        // and that degrades to typing the id.
        onTap: () => pushGated(
            Permission.openSettings,
            MenuEditorScreen(
              catalogue: widget.catalogue,
              onChanged: refresh,
              categoryColors: widget.settings.categoryColors,
              onSetCategoryColor: widget.settings.setCategoryColor,
              autoAddAllowed: {
                for (final c in widget.catalogue.categories())
                  c.id: widget.settings.isAutoAddAllowed(c.id),
              },
              onSetCategoryAutoAdd: widget.settings.setAutoAddAllowed,
              searchOdooProducts: _searchOdooProducts,
              searchOdooCategories: _searchOdooCategories,
              localProductBookingId: widget.settings.odooLocalProductId,
            )),
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
        title: 'SQL console',
        subtitle: 'Inspect and edit the local SQLite tables',
        icon: Icons.storage_outlined,
        keyValue: 'set-sql',
        group: 'Shop',
        onTap: () => pushGated(
            Permission.openSettings,
            SqlConsoleScreen(
              db: widget.outboxStore.db,
              audit: widget.audit,
              cashierId: _session?.cashierId,
            )),
      ),
      SettingsEntry(
        title: 'Staff',
        subtitle: 'Add employees, set role and PIN',
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
          if (ok != null && context.mounted) {
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
        onJoinPrimary: widget.lan == null
            ? null
            : (peer, pin, {onProgress}) async {
                // Never call tr(context) after an await here: a deactivated
                // element makes Localizations.localeOf throw a null-check
                // FlutterError, which we were surfacing as a join failure.
                void report(String label, double p) {
                  try {
                    onProgress?.call(label, p);
                  } catch (_) {}
                }

                Future<String?> runStep(
                  String name,
                  double fraction,
                  FutureOr<void> Function() body,
                ) async {
                  report(name, fraction);
                  try {
                    await body();
                    return null;
                  } catch (e, st) {
                    return '$name: $e\n$st';
                  }
                }

                final lan = widget.lan;
                if (lan == null) {
                  return 'LAN is not running. Turn on Share on this network and restart.';
                }

                // Pairing is applied only after the snapshot lands, so a failed
                // join cannot leave Secondary + a half-copied shop key stuck on.
                String? pendingKey;
                try {
                  report('Connecting to primary...', 0.05);
                  final payload = await lan.joinWithPrimary(peer, pin);
                  final key = payload['shop_key'];
                  if (key is! String || key.isEmpty) {
                    return 'Primary answered without a shop key.';
                  }
                  pendingKey = key;

                  // Drop this till's old open floor / prints / fingerprints so
                  // stale tabs (and dead device owners) cannot survive the join.
                  var err = await runStep('Clearing old local data...', 0.12, () {
                    widget.orders.clearOpenForJoin();
                    widget.assignments?.clearAll(announce: false);
                    widget.fingerprintStore?.replaceAllForJoin(const []);
                  });
                  if (err != null) return err;

                  err = await runStep('Section settings...', 0.20, () {
                    final configs = payload['section_configs'];
                    if (configs is! Map) return;
                    widget.settings.applySectionConfigSnapshot({
                      for (final e in configs.entries)
                        if (e.value is Map)
                          '${e.key}':
                              (e.value as Map).cast<String, dynamic>(),
                    });
                  });
                  if (err != null) return err;

                  err = await runStep('Shop settings...', 0.28, () {
                    final bundle = payload['shop_bundle'];
                    if (bundle is! Map) return;
                    widget.settings
                        .applyShopBundle(bundle.cast<String, dynamic>());
                    widget.dishflow?.apply(widget.settings);
                  });
                  if (err != null) return err;

                  err = await runStep('Staff roster...', 0.36, () {
                    final roster = payload['users'];
                    if (roster is! List || roster.isEmpty) return;
                    widget.users.replaceAll([
                      for (final raw in roster)
                        if (raw is Map)
                          Cashier.fromMap(raw.cast<String, dynamic>()),
                    ]);
                    _provisioningPin = null;
                  });
                  if (err != null) return err;

                  err = await runStep('Fingerprints...', 0.40, () async {
                    final fps = payload['fingerprints'];
                    final store = widget.fingerprintStore;
                    if (store == null) return;
                    final entries = <Map<String, dynamic>>[
                      if (fps is List)
                        for (final raw in fps)
                          if (raw is Map) raw.cast<String, dynamic>(),
                    ];
                    store.replaceAllForJoin(entries);
                    await FingerprintAgentLauncher().ensureRunning();
                    await store.pushToAgent();
                  });
                  if (err != null) return err;

                  err = await runStep('Printers...', 0.44, () {
                    final printersPayload = payload['printers'];
                    if (printersPayload is! Map) return;
                    // Kitchen / bar stations come from the primary; this till's
                    // receipt (and delivery) printer stay local so each counter
                    // keeps its own roll and cash drawer.
                    widget.printers.applySharedStationsFromMap(
                      printersPayload.cast<String, Object?>(),
                    );
                  });
                  if (err != null) return err;

                  err = await runStep('Odoo connection...', 0.52, () {
                    final odooRaw = payload['odoo_endpoint'];
                    if (odooRaw is! Map) return;
                    final endpoint =
                        OdooEndpoint.fromMap(odooRaw.cast<String, dynamic>());
                    if (endpoint.isComplete) {
                      widget.endpoints.save(endpoint);
                      widget.odoo.configure(endpoint);
                    }
                  });
                  if (err != null) return err;

                  err = await runStep('Menu and categories...', 0.62, () {
                    final catalogueRaw = payload['catalogue'];
                    if (catalogueRaw is! Map) return;
                    widget.catalogue
                        .applyLanSnapshot(catalogueRaw.cast<String, dynamic>());
                  });
                  if (err != null) return err;

                  err = await runStep('Floor plan...', 0.72, () {
                    final tablesRaw = payload['tables'];
                    if (tablesRaw is! List) {
                      widget.tables.replaceAllForJoin(const []);
                      return;
                    }
                    final tables = <PosTable>[];
                    for (final raw in tablesRaw) {
                      if (raw is! Map) continue;
                      try {
                        tables.add(
                            PosTable.fromMap(raw.cast<String, dynamic>()));
                      } catch (_) {}
                    }
                    widget.tables.replaceAllForJoin(tables);
                  });
                  if (err != null) return err;

                  err = await runStep('Open tables...', 0.80, () {
                    final openRaw = payload['open_orders'];
                    if (openRaw is! List) return;
                    for (final raw in openRaw) {
                      if (raw is! Map) continue;
                      try {
                        widget.orders.save(
                          Order.fromMap(raw.cast<String, dynamic>()),
                          announce: false,
                        );
                      } catch (_) {}
                    }
                  });
                  if (err != null) return err;

                  err = await runStep('Staff attendance...', 0.88, () {
                    final attendanceRaw = payload['attendance_open'];
                    if (attendanceRaw is! List) return;
                    widget.attendance.applyOpenSnapshot(attendanceRaw);
                  });
                  if (err != null) return err;

                  report('Refreshing menu from server...', 0.94);
                  if (widget.endpoints.isConfigured) {
                    try {
                      await widget.sync.refresh(force: true)
                          .timeout(const Duration(seconds: 45));
                    } catch (_) {
                      // Catalogue from the join snapshot is already applied.
                    }
                  }

                  report('Saving shop link...', 0.97);
                  widget.settings.lanShopKey = pendingKey;
                  widget.settings.deviceRole = DeviceRole.secondary;
                  widget.settings.lanRolePromptDismissed = true;

                  report('Done', 1.0);
                  refresh();
                  unawaited(_reconcileLan());
                  if (mounted) setState(() {});
                  return null;
                } catch (e, st) {
                  return 'Join failed: $e\n$st';
                }
              },
        onChanged: () {
          refresh();
          unawaited(_reconcileLan());
        },
      );

  /// Gate a privileged action behind manager approval. Returns the approving
  /// manager. A manager already signed in passes as themselves unless
  /// [requirePin] is set (voids always ask so the approving PIN is on the slip).
  ///
  /// When a ZK reader is connected, fingerprint is offered first; PIN remains
  /// the fallback for every permission path.
  Future<Cashier?> _authorizeManager(BuildContext context,
      {bool requirePin = false}) async {
    final signedIn = widget.auth.signedIn;
    if (!requirePin && (signedIn?.isManager ?? false)) return signedIn;

    final fp = widget.fingerprints;
    if (fp != null) {
      final result = await showFingerprintOrPin(
        context,
        fingerprints: fp,
        title: tr(context, 'Manager approval'),
        message: tr(context, 'Fingerprint or manager PIN'),
        askTotp: widget.auth.managersUseSecondFactor,
        prepareTemplates: widget.fingerprintStore?.pushToAgent,
      );
      if (result == null) return null;
      if (result.isFingerprint) {
        return widget.auth
            .authorizeManagerByFingerprint(result.matchedUserId!);
      }
      return widget.auth
          .authorizeManager(result.pin!, code: result.totpCode);
    }

    var pin = '';
    var code = '';
    // Only a shop that has enrolled an authenticator is shown the second field, so
    // nothing changes for a till that does not use one.
    final second = widget.auth.managersUseSecondFactor;
    final entered = await showDialog<(String, String)>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) {
          final scheme = Theme.of(ctx).colorScheme;
          return AlertDialog(
            title: Text(tr(ctx, 'Manager approval')),
            content: SizedBox(
              width: 300,
              child: SingleChildScrollView(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                Container(
                  key: const Key('manager-pin'),
                  width: double.infinity,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: scheme.outlineVariant),
                  ),
                  child: Text(
                    pin.isEmpty ? '····' : '•' * pin.length,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 26,
                      letterSpacing: 8,
                      fontWeight: FontWeight.w700,
                      color: pin.isEmpty
                          ? scheme.onSurfaceVariant
                          : scheme.primary,
                    ),
                  ),
                ),
                if (second) ...[
                  const SizedBox(height: 10),
                  TextField(
                    key: const Key('manager-code'),
                    keyboardType: TextInputType.number,
                    onChanged: (v) => setLocal(() => code = v.trim()),
                    decoration: InputDecoration(
                        labelText: tr(ctx, 'Authenticator code'),
                        helperText: tr(ctx, 'Only if this manager set one up'),
                        border: const OutlineInputBorder()),
                  ),
                ],
                const SizedBox(height: 8),
                NumericKeypad(
                  decimal: false,
                  compact: true,
                  onKey: (k) {
                    if (pin.length >= 6) return;
                    setLocal(() => pin += k);
                  },
                  onBackspace: () => setLocal(() =>
                      pin = pin.isEmpty ? pin : pin.substring(0, pin.length - 1)),
                  onClear: () => setLocal(() => pin = ''),
                ),
              ]),
              ),
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: Text(tr(ctx, 'Cancel'))),
              FilledButton(
                key: const Key('manager-ok'),
                onPressed: pin.isEmpty
                    ? null
                    : () => Navigator.pop(ctx, (pin, code)),
                child: Text(tr(ctx, 'Approve')),
              ),
            ],
          );
        },
      ),
    );
    if (entered == null || entered.$1.isEmpty) return null;
    final who =
        await widget.auth.authorizeManager(entered.$1, code: entered.$2);
    if (who == null && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(tr(context, 'Manager approval failed'))));
    }
    return who;
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
    if (approved == null) {
      widget.audit.record(cashier?.id ?? 'unknown', 'permission.denied', detail: p.key);
      return false;
    }
    return true;
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
    // Number the bill before the first kitchen ticket, so the pass and the
    // receipt quote the same sequential order number guests and staff can search for.
    final session = _session;
    if (session != null) {
      session.ensureOrderNo(order);
      widget.orders.save(order, announce: false);
    } else if (order.orderNo == null) {
      order.orderNo = widget.settings.nextOrderNumber(widget.deviceId,
          atLeast: () {
            var floor = 0;
            for (final o in widget.orders.recentAnywhere(limit: 2000)) {
              final n = int.tryParse(o.displayNo);
              if (n != null && n > floor) floor = n;
            }
            return floor;
          }());
      widget.orders.save(order, announce: false);
    }
    // The ticket says which part of the floor the plate is going to, resolved from
    // the floor plan on this device.
    final builder = KitchenTicketBuilder(
      sectionOf: widget.tables.sectionFor,
      categoryNameOf: (id) => widget.catalogue.categoryById(id)?.name,
      serverNameOf: (id) => widget.users.byId(id)?.name,
    );
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
    final bytes = KitchenTicketBuilder(
      sectionOf: widget.tables.sectionFor,
      categoryNameOf: (id) => widget.catalogue.categoryById(id)?.name,
      serverNameOf: (id) => widget.users.byId(id)?.name,
    ).buildVoid(order, line, reason);
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
        // Where the branch, point of sale and warehouse ids are kept, so the same
        // screen that points the till at a server also says which shop it is.
        settings: widget.settings,
        // Rewire the live sender the moment settings are saved, so a till just
        // pointed at a server drains its queue without a restart.
        onSaved: widget.odoo.configure,
        check: widget.checkServer,
        // So the three ids are picked from what Odoo actually has rather than
        // guessed. Read through the same call_kw the catalogue uses, and only ever
        // from this screen.
        loadChoices: () =>
            OdooPuller(call: widget.odoo.catalogueCall).siteChoices(),
        sessionPartners: widget.catalogue.customers(limit: 500),
      ),
    ));
  }

  /// Opens the shift screen, and answers when the cashier comes back off it, so a
  /// caller whose own gate depends on the drawer can re-read it. Most callers just
  /// send them there and have nothing to wait for.
  /// Ask who is working this session and put them on the clock. Shown right after a
  /// shift is opened. Whoever opened it is on the clock and stays; the rest are
  /// ticked if already clocked in, so ticking adds them and unticking clocks them
  /// out, except the opener who cannot clock themselves out here.
  Future<void> _pickSessionStaff(BuildContext context, PosSession session) async {
    final users = widget.users.active();
    if (users.isEmpty) return;
    if (!widget.attendance.isClockedIn(session.cashierId)) {
      widget.attendance.clockIn(session.cashierId);
    }
    final chosen = {
      for (final u in users)
        if (widget.attendance.isClockedIn(u.id)) u.id,
    };
    if (!context.mounted) return;
    final result = await showDialog<Set<String>>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          key: const Key('session-staff'),
          title: Text(tr(ctx, 'Who is working this session?')),
          content: SizedBox(
            width: 320,
            child: ListView(shrinkWrap: true, children: [
              for (final u in users)
                CheckboxListTile(
                  key: Key('session-staff-${u.id}'),
                  title: Text(u.name),
                  value: chosen.contains(u.id),
                  onChanged: (v) => setD(() =>
                      v == true ? chosen.add(u.id) : chosen.remove(u.id)),
                ),
            ]),
          ),
          actions: [
            FilledButton(
              key: const Key('session-staff-done'),
              onPressed: () => Navigator.pop(ctx, chosen),
              child: Text(tr(ctx, 'Done')),
            ),
          ],
        ),
      ),
    );
    if (result == null) return;
    for (final u in users) {
      final present = result.contains(u.id);
      final on = widget.attendance.isClockedIn(u.id);
      if (present && !on) widget.attendance.clockIn(u.id);
      if (!present && on && u.id != session.cashierId) {
        widget.attendance.clockOut(u.id);
      }
    }
  }

  Future<void> _openShift(BuildContext context, PosSession session,
      {bool startClose = false}) {
    // Which tenders count as drawer cash, read from the synced catalogue so the
    // X/Z drawer total reconciles cash and leaves card sales out.
    final cashMethodIds = widget.catalogue
        .paymentMethods()
        .where((m) => m.isCash)
        .map((m) => m.id)
        .toSet();
    return Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => ShiftScreen(
        store: widget.shifts,
        cashierId: session.cashierId,
        startCloseOnOpen: startClose,
        // Right after the shift opens, ask who is working this session so sales and
        // tables can be attributed to whoever is actually on the floor. Opt-in.
        onShiftOpened: () {
          _announceShiftOpen(session);
          if (widget.settings.askSessionStaff) {
            unawaited(_pickSessionStaff(context, session));
          }
        },
        cashMethodIds: cashMethodIds,
        formatAmount: PosApp.money,
        onPrintReport: _printShiftReport,
        // Read at the moment the Z is attempted, not only when the screen was
        // built: a tab can be settled while the shift screen is open.
        openWork: () => _openWork(context),
        // Dishflow session-close: jump back to the floor to settle parked tabs.
        onNavigateToFloor: () {
          Navigator.of(context).pop();
          _toFloor();
        },
        pendingSyncCount: () {
          final shift = widget.shifts.currentOpenShift() ??
              widget.shifts.latestShift();
          if (shift == null) return widget.sync.pendingSales;
          return widget.orders.awaitingSyncInShift(shift).length;
        },
        sessionPartnerName: () {
          final name = widget.settings.odooSessionPartnerName;
          if (name != null && name.isNotEmpty) return name;
          final id = widget.settings.odooSessionPartnerId;
          return id == null ? null : '#$id';
        },
        // Dishflow: arm consolidated merge. Session customer comes from the branch
        // in Odoo (Session close tab); we pull it live if this till has not cached it.
        onPrepareCloseSync: () async {
          final shift = widget.shifts.currentOpenShift();
          if (shift == null) return null;
          // Tickets in THIS open shift only — not the whole outbox backlog.
          if (widget.orders.awaitingSyncInShift(shift).isEmpty) return null;
          widget.settings.mergeBatchIntoOneSaleOrder = true;
          await _ensureSessionPartnerFromBranch();
          if (widget.settings.odooSessionPartnerId == null &&
              widget.settings.odooBranchId == null) {
            return tr(context,
                'Consolidated close needs a branch with a session invoice customer. '
                'Pick the branch under Server settings, and set the customer on '
                'Offline POS ▸ Branches ▸ Session close in Odoo.');
          }
          return null;
        },
        // The allowance the counted drawer is held to, zero unless the shop set one.
        cashVarianceTolerance: widget.settings.cashVarianceTolerance,
        // A refused Z is worth knowing about the morning after: it says a till was
        // left with work on it or a drawer that did not add up.
        onCloseBlocked: (reason) =>
            widget.audit.record(session.cashierId, reason),
        // Gated BEFORE the shift closes, since the close is irreversible: the
        // cashier's role may allow it outright, otherwise a manager approves.
        authorizeClose: () => _authorize(Permission.closeShift, context),
        // A copy of the day for whoever is not in the building. Queued and left
        // to the background lane, so the cash-up is over before the first packet
        // is sent and a mail server that is down changes nothing about closing.
        onZClosed: (closed, rows) {
          // The room goes back to nobody as the shift ends: a table still assigned to
          // whoever went home is one the next service cannot open. Before the report,
          // so a mail server that misbehaves cannot leave the room shared out.
          _clearAssignments(session);
          _emailZReport(closed, rows);
        },
        // Closing the shift is when the day's orders are pushed to Odoo in one
        // batch. Returns a message for the cashier: how it went, or that the
        // orders are safe and will sync once the connection is back.
        onCloseSync: () async {
          _announceDayClose(session);
          final shift = widget.shifts.latestShift();
          if (shift == null) return 'No shift to sync.';
          // Same window the Z used: paid tickets created between open and close.
          final shiftOrders = widget.orders.awaitingSyncInShift(shift);
          if (shiftOrders.isEmpty) {
            final existing = widget.sync.lastOdooOrderRef ??
                await _resolveOdooSaleName(null);
            if (existing != null && existing.isNotEmpty) {
              return 'No new orders in this shift.\nLast Odoo order: $existing';
            }
            return 'No orders in this shift to sync.';
          }
          widget.settings.mergeBatchIntoOneSaleOrder = true;
          await _ensureSessionPartnerFromBranch();
          final partner = widget.settings.odooSessionPartnerName ??
              (widget.settings.odooSessionPartnerId == null
                  ? null
                  : '#${widget.settings.odooSessionPartnerId}');
          final result = await widget.sync.flushClosedShift(
            orderUuids: {for (final o in shiftOrders) o.uuid},
            enqueueOrders: () async {
              // Fresh wire payloads so delivery / tip / service fee are not
              // stale zeros left from an older enqueue.
              for (final o in shiftOrders) {
                await widget.outbox.enqueue(
                    'order.push', o.uuid, o.toServerPayload());
              }
            },
          );
          if (result.merged) {
            var odooRef = result.odooRef ?? widget.sync.lastOdooOrderRef;
            if (odooRef == null ||
                odooRef.isEmpty ||
                odooRef.startsWith('#')) {
              final resolved = await _resolveOdooSaleName(odooRef);
              if (resolved != null) odooRef = resolved;
            }
            if (odooRef != null && odooRef.isNotEmpty) {
              widget.sync.lastOdooOrderRef = odooRef;
              return 'Synced ${result.orderCount} order(s) from this shift '
                  'to Odoo as one sale order'
                  '${partner != null ? ' under $partner' : ''}.\n'
                  'Odoo order: $odooRef';
            }
            return 'Sent ${result.orderCount} order(s) from this shift'
                '${partner != null ? ' under $partner' : ''}, '
                'but Odoo did not return the sale number yet.\n'
                'Check Sales orders for today under the session customer.';
          }
          final why = result.skipReason ?? widget.sync.lastError;
          return 'Could not book this shift as one sale order'
              '${why != null && why.isNotEmpty ? ': $why' : '.'}\n'
              '${result.orderCount} order(s) stay on this till — '
              'will retry in the background, or use Support ▸ Sync now.';
        },
      ),
    ))
        // Coming back from a shift opened or closed changes whether the till may
        // sell, so the screen underneath is rebuilt rather than left stale.
        .then((_) {
      if (mounted) {
        setState(() {});
        _nudgeShift();
      }
    });
  }

  /// Turn an Odoo id (`#42`) or a missing ref into the sale order name (`S04741`)
  /// for the green box on Session closed. Searches by id, shift uuid, then the
  /// session partner's newest sale today.
  Future<String?> _resolveOdooSaleName(String? ref) async {
    try {
      if (ref != null && ref.startsWith('#')) {
        final id = int.tryParse(ref.substring(1));
        if (id != null) {
          final rows = await widget.odoo.catalogueCall(
            'sale.order',
            'read',
            [
              [id],
              ['name']
            ],
            {},
          );
          if (rows is List && rows.isNotEmpty && rows.first is Map) {
            final name = (rows.first as Map)['name']?.toString();
            if (name != null && name.isNotEmpty) return name;
          }
        }
      }
      final shiftUuid = widget.shifts.latestShift()?.uuid;
      if (shiftUuid != null && shiftUuid.isNotEmpty) {
        for (final field in ['offline_uuid', 'client_order_ref']) {
          final found = await widget.odoo.catalogueCall(
            'sale.order',
            'search_read',
            [
              [
                [field, '=', shiftUuid]
              ]
            ],
            {
              'fields': ['name'],
              'limit': 1,
              'order': 'id desc',
            },
          );
          if (found is List && found.isNotEmpty && found.first is Map) {
            final name = (found.first as Map)['name']?.toString();
            if (name != null && name.isNotEmpty) return name;
          }
        }
      }
      final partnerId = widget.settings.odooSessionPartnerId;
      if (partnerId != null) {
        final day = DateTime.now().toUtc();
        final start =
            DateTime.utc(day.year, day.month, day.day).toIso8601String();
        final found = await widget.odoo.catalogueCall(
          'sale.order',
          'search_read',
          [
            [
              ['partner_id', '=', partnerId],
              ['date_order', '>=', start],
            ]
          ],
          {
            'fields': ['name'],
            'limit': 1,
            'order': 'id desc',
          },
        );
        if (found is List && found.isNotEmpty && found.first is Map) {
          final name = (found.first as Map)['name']?.toString();
          if (name != null && name.isNotEmpty) return name;
        }
      }
    } catch (_) {
      // Close screen still shows the sync message; a missing name is not a failed close.
    }
    return null;
  }

  /// Load the branch's Session-close customer onto this till if missing.
  ///
  /// Tries the cached site choices first, then a live `branch.simple` read so a
  /// customer set only in Odoo still reaches the consolidated payload.
  Future<void> _ensureSessionPartnerFromBranch() async {
    if (widget.settings.odooSessionPartnerId != null) return;
    final branchId = widget.settings.odooBranchId;
    if (branchId == null) return;

    for (final b in widget.settings.odooSiteChoices.branches) {
      if (b.id == branchId && b.sessionPartnerId != null) {
        widget.settings.odooSessionPartnerId = b.sessionPartnerId;
        widget.settings.odooSessionPartnerName = b.sessionPartnerName;
        return;
      }
    }

    try {
      final raw = await widget.odoo.catalogueCall(
        'branch.simple',
        'search_read',
        [
          [
            ['id', '=', branchId]
          ],
          ['session_partner_id', 'consolidate_session_invoice', 'name'],
        ],
        {'limit': 1},
      );
      if (raw is! List || raw.isEmpty || raw.first is! Map) return;
      final row = (raw.first as Map).cast<String, dynamic>();
      final partner = row['session_partner_id'];
      int? partnerId;
      String? partnerName;
      if (partner is List && partner.isNotEmpty && partner.first is int) {
        partnerId = partner.first as int;
        if (partner.length > 1 && partner[1] is String) {
          partnerName = partner[1] as String;
        }
      } else if (partner is int) {
        partnerId = partner;
      }
      if (partnerId == null) return;
      widget.settings.odooSessionPartnerId = partnerId;
      widget.settings.odooSessionPartnerName = partnerName;
      widget.settings.mergeBatchIntoOneSaleOrder =
          row['consolidate_session_invoice'] == true ||
              widget.settings.mergeBatchIntoOneSaleOrder;
    } catch (_) {
      // Offline or old module without the fields: close still proceeds with
      // branch_id on the payload so the server can resolve the partner.
    }
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
  ///
  /// Empty seat claims (held, no lines) are discarded here: they keep a table
  /// colour busy on the floor while End of Day sees "1 unfinished" with nothing
  /// to settle. Paid sales waiting to sync may still have kitchen timers; the
  /// money is already in, so those timers never block a Z.
  OpenWork _openWork(BuildContext context) {
    for (final o in widget.orders.held()) {
      if (o.lines.isEmpty) widget.orders.delete(o.uuid);
    }
    final held = widget.orders.held();
    final session = _session;
    final withTimers = <String, Order>{
      for (final o in held) o.uuid: o,
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

  /// Print an X, Z, or generic report to the receipt printer (spooled if down).
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
      final label = r.$1.trim();
      final value = r.$2.trim();
      if (label.isEmpty && value.isEmpty) continue;
      // Section banners from Flash ("— Payments —") print centred.
      if (label.startsWith('—') || (label.isNotEmpty && value.isEmpty)) {
        p.align(EscPosAlign.center)
          ..bold(true)
          ..line(label)
          ..bold(false)
          ..align(EscPosAlign.left);
        continue;
      }
      p.row(label, value);
    }
    final bytes = (p..feed(2)..cut()).build();
    if (widget.printers[PosApp.receiptPrinter] == null) {
      throw StateError('No receipt printer configured');
    }
    try {
      await _receiptPrinter.send(
          bytes, reference: 'report-$title-${now.millisecondsSinceEpoch}');
    } on PrinterUnavailable {
      // Held in the spool — tell the UI so Flash does not claim a paper that
      // never came out.
      throw StateError('Printer offline — job held');
    }
  }

  /// Dishflow-layout Flash slip (Control / Summary / Delivery) — same fields
  /// and section order as the Dishflow thermal builders.
  Future<void> _printFlashReport(FlashReportData data, FlashKind kind) async {
    if (widget.printers[PosApp.receiptPrinter] == null) {
      throw StateError('No receipt printer configured');
    }
    final shop = widget.settings.shopName ?? widget.config.shopName;
    final cashLabels = <String>{
      for (final m in widget.catalogue.paymentMethods())
        if (m.isCash) (m.name).trim().toLowerCase(),
    };
    final bytes = FlashThermalEscPos.build(
      data: data,
      kind: flashThermalKindFor(kind),
      shopName: shop,
      columns: widget.settings.receiptColumns,
      categoryNameOf: (id) =>
          id == null ? 'Other' : (widget.catalogue.categoryById(id)?.name ?? 'Other'),
      isCashPayment: (label) {
        final s = label.trim().toLowerCase();
        if (s.contains('cash') || s == 'نقدي' || s == 'كاش') return true;
        return cashLabels.contains(s);
      },
    );
    final now = DateTime.now();
    try {
      await _receiptPrinter.send(bytes,
          reference: 'flash-${data.title}-${now.millisecondsSinceEpoch}');
    } on PrinterUnavailable {
      throw StateError('Printer offline — job held');
    }
  }

  /// A throwaway order for the receipt-designer and printers-screen test print.
  /// Never saved or synced.
  ///
  /// Carries an Arabic line as well as a Latin one, because whether Arabic comes out
  /// legible depends on the printer and on which character table the shop picked, and
  /// nobody can answer that from this screen. A test print that was Latin only said
  /// the printer worked while the receipts it printed were unreadable.
  Order _sampleOrder() => Order(
        deviceId: widget.deviceId,
        cashierId: _session?.cashierId ?? 'sample',
        lines: [
          OrderLine(productId: 0, name: 'Sample item', quantity: 1, unitPrice: 10),
          OrderLine(productId: 0, name: 'صنف تجريبي', quantity: 1, unitPrice: 10),
        ],
      )..payments = [const OrderPayment(methodId: 0, amount: 20, label: 'Cash')];

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
        onOpenSql: () {
          Navigator.of(context).push(MaterialPageRoute<void>(
            builder: (_) => SqlConsoleScreen(
              db: widget.outboxStore.db,
              audit: widget.audit,
              cashierId: _session?.cashierId,
            ),
          ));
        },
      ),
    ));
  }
}
