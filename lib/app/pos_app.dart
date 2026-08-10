import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../core/audit/audit_log.dart';
import '../core/auth/auth_service.dart';
import '../core/auth/user_store.dart';
import '../core/config/till_config.dart';
import '../core/db/catalogue_store.dart';
import '../core/db/order_store.dart';
import '../core/db/shift_store.dart';
import '../core/db/sqlite_outbox_store.dart';
import '../core/onboarding/wizard_id.dart';
import '../core/onboarding/wizard_store.dart';
import '../core/printing/kitchen_ticket.dart';
import '../core/printing/printer_registry.dart';
import '../core/printing/printer_transport.dart';
import '../core/printing/receipt_builder.dart';
import '../core/printing/registry_printer.dart';
import '../core/printing/spool_store.dart';
import '../core/sync/odoo_endpoint.dart';
import '../core/sync/odoo_wiring.dart';
import '../core/sync/outbox.dart';
import '../core/sync/sync_service.dart';
import '../core/updates/update_service.dart';
import '../domain/order.dart';
import '../features/admin/roster_screen.dart';
import '../features/auth/login_screen.dart';
import '../features/onboarding/wizard_overlay.dart';
import '../features/orders/open_orders_screen.dart';
import '../features/orders/order_history_screen.dart';
import '../features/reports/sales_report_screen.dart';
import '../features/sell/sell_screen.dart';
import '../features/settings/server_settings_screen.dart';
import '../features/shift/shift_screen.dart';
import '../features/support/diagnostics_screen.dart';
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
    this.config = const TillConfig(),
    this.receiptSpool,
    this.activity,
    this.provisioningPin,
    this.updates,
  });

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

  /// The name receipts are routed by. Part of the on-disk contract: the printers
  /// table and the held-receipt queue are both keyed on it.
  static const String receiptPrinter = 'receipt';

  static String money(double v) => v.toStringAsFixed(2);

  @override
  State<PosApp> createState() => _PosAppState();
}

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
  PosSession? _session;
  bool _firstSaleHelp = false;
  String? _printError;
  Timer? _background;

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
  }

  @override
  void dispose() {
    _background?.cancel();
    super.dispose();
  }

  Future<void> _catchUp() async {
    if (_receiptPrinter.hasSpooled) await _receiptPrinter.flush();
    if (mounted) setState(() {});
    // An update is the least important thing this app does, so it runs last and
    // its own gate decides whether anything actually happens.
    await widget.updates?.check();
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
      );
      _firstSaleHelp = widget.wizards.shouldShow(WizardId.firstSale, cashier.id);
    });
    // Support asks who is on the till before anything else.
    widget.sync.cashierId = cashier.id;
    _publishActivity();
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
  Future<void> _printReceipt(Order order, {bool reprint = false}) async {
    try {
      final bytes = ReceiptBuilder(
        shopName: widget.config.shopName,
        taxId: widget.config.taxId,
        footer: widget.config.receiptFooter,
        formatAmount: PosApp.money,
      ).build(order, reprint: reprint);
      // A reprint uses a distinct reference so it does not collide with the
      // original in the spool's dedupe.
      await _receiptPrinter.send(bytes,
          reference: reprint ? 'reprint-${order.uuid}' : order.uuid);
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

  @override
  Widget build(BuildContext context) {
    final session = _session;
    return MaterialApp(
      title: 'offlinePOS',
      theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
      home: session == null
          ? LoginScreen(
              auth: widget.auth,
              users: widget.users,
              onSignedIn: _signedIn,
              provisioningPin: widget.provisioningPin,
            )
          : _selling(session),
    );
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
              onChanged: _publishActivity,
              onSignOut: _signOut,
              drawer: _buildDrawer(context, session),
              onOpenOrders: () => _openOrders(context, session),
              onHold: () {
                // Holding a table is what sends its food to the kitchen, so the
                // ticket fires here, then the order is parked.
                unawaited(_fireKitchen(session.current));
                session.hold();
                _publishActivity();
              },
              onLineVoided: (line, reason) =>
                  unawaited(_fireVoid(session.current, line, reason)),
              onPaid: (order) {
                _publishActivity();
                // A straight counter sale never held, so its lines reach the
                // kitchen here; a dine-in order already fired on hold and reprints
                // nothing. The sale is NOT pushed to Odoo now: it waits on the till
                // for the shift-close batch.
                unawaited(_fireKitchen(order as Order).then((_) => _printReceipt(order)));
              },
            ),
          ),
          if (_firstSaleHelp)
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
            key: const Key('nav-open-orders'),
            leading: const Icon(Icons.table_restaurant),
            title: const Text('Open orders'),
            trailing: session.heldCount > 0 ? Chip(label: Text('${session.heldCount}')) : null,
            onTap: () {
              Navigator.pop(rootContext);
              _openOrders(rootContext, session);
            },
          ),
          ListTile(
            key: const Key('nav-history'),
            leading: const Icon(Icons.receipt_long),
            title: const Text('Order history'),
            onTap: () {
              Navigator.pop(rootContext);
              _openHistory(rootContext);
            },
          ),
          ListTile(
            key: const Key('nav-report'),
            leading: const Icon(Icons.bar_chart),
            title: const Text('Sales report'),
            onTap: () {
              Navigator.pop(rootContext);
              _openReport(rootContext);
            },
          ),
          ListTile(
            key: const Key('nav-shift'),
            leading: const Icon(Icons.point_of_sale),
            title: const Text('Shift / cash-up'),
            onTap: () {
              Navigator.pop(rootContext);
              _openShift(rootContext, session);
            },
          ),
          const Divider(),
          if (isManager)
            ListTile(
              key: const Key('nav-staff'),
              leading: const Icon(Icons.badge_outlined),
              title: const Text('Staff'),
              onTap: () {
                Navigator.pop(rootContext);
                _openRoster(rootContext);
              },
            ),
          ListTile(
            key: const Key('nav-settings'),
            leading: const Icon(Icons.settings),
            title: const Text('Server settings'),
            onTap: () {
              Navigator.pop(rootContext);
              _openSettings(rootContext);
            },
          ),
          ListTile(
            key: const Key('nav-support'),
            leading: const Icon(Icons.support_agent),
            title: const Text('Support & printers'),
            onTap: () {
              Navigator.pop(rootContext);
              _openDiagnostics(rootContext);
            },
          ),
        ]),
      ),
    );
  }

  void _openOrders(BuildContext context, PosSession session) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => OpenOrdersScreen(
        orders: widget.orders.held(),
        formatAmount: PosApp.money,
        onRecall: (order) => setState(() => session.recall(order.uuid)),
      ),
    ));
  }

  void _openHistory(BuildContext context) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => OrderHistoryScreen(
        orders: widget.orders.recent(limit: 100),
        formatAmount: PosApp.money,
        onReprint: (order) => _printReceipt(order, reprint: true),
      ),
    ));
  }

  void _openReport(BuildContext context) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => SalesReportScreen(
        orders: widget.orders.recent(limit: 500),
        formatAmount: PosApp.money,
      ),
    ));
  }

  void _openRoster(BuildContext context) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => RosterScreen(
        users: widget.users,
        auth: widget.auth,
        onChanged: () => setState(() {}),
      ),
    ));
  }

  // ── kitchen tickets ──────────────────────────────────────────────

  /// Fire a kitchen ticket for the lines not yet sent. Best-effort and never on the
  /// path of a tap: a kitchen printer that is off must not stop the sale. When no
  /// kitchen printer answers, the ticket falls back to the receipt printer so a
  /// slip still comes out that staff can carry to the pass.
  Future<void> _fireKitchen(Order order, {List<OrderLine>? only}) async {
    final lines = only ?? order.lines.where((l) => !l.printedToKitchen).toList();
    if (lines.isEmpty) return;
    final builder = KitchenTicketBuilder();
    for (final entry in routeToStations(lines).entries) {
      final bytes = builder.build(order, only: entry.value, station: entry.key);
      await _sendToStation(entry.key, bytes, 'kot-${order.uuid}');
    }
    for (final l in lines) {
      l.printedToKitchen = true;
    }
    widget.orders.save(order);
  }

  Future<void> _fireVoid(Order order, OrderLine line, String reason) async {
    final bytes = KitchenTicketBuilder().buildVoid(order, line, reason);
    await _sendToStation('kitchen', bytes, 'void-${order.uuid}-${line.uuid}');
  }

  Future<void> _sendToStation(String station, List<int> bytes, String reference) async {
    final payload = Uint8List.fromList(bytes);
    try {
      await RegistryPrinter(widget.printers, station).send(payload);
    } on PrinterUnavailable {
      // No station printer: fall back to the receipt printer, spooled if that is
      // down too, so the ticket is not simply lost.
      try {
        await _receiptPrinter.send(payload, reference: reference);
      } on PrinterUnavailable {
        // Held in the spool; the background flush will retry it.
      } catch (e) {
        widget.audit.record(_session?.cashierId ?? 'system', 'kitchen.failed',
            detail: '$reference: $e');
      }
    } catch (e) {
      widget.audit.record(_session?.cashierId ?? 'system', 'kitchen.failed',
          detail: '$reference: $e');
    }
  }

  void _openSettings(BuildContext context) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => ServerSettingsScreen(
        store: widget.endpoints,
        // Rewire the live sender the moment settings are saved, so a till just
        // pointed at a server drains its queue without a restart.
        onSaved: widget.odoo.configure,
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
        // Closing the shift is when the day's orders are pushed to Odoo in one
        // batch. Returns a message for the cashier: how it went, or that the
        // orders are safe and will sync once the connection is back.
        onCloseSync: () async {
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
      ),
    ));
  }
}
