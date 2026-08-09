import 'dart:async';

import 'package:flutter/material.dart';

import '../core/audit/audit_log.dart';
import '../core/auth/auth_service.dart';
import '../core/auth/user_store.dart';
import '../core/config/till_config.dart';
import '../core/db/catalogue_store.dart';
import '../core/db/order_store.dart';
import '../core/db/sqlite_outbox_store.dart';
import '../core/onboarding/wizard_id.dart';
import '../core/onboarding/wizard_store.dart';
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
import '../features/auth/login_screen.dart';
import '../features/onboarding/wizard_overlay.dart';
import '../features/sell/sell_screen.dart';
import '../features/settings/server_settings_screen.dart';
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
  Future<void> _printReceipt(Order order) async {
    try {
      final bytes = ReceiptBuilder(
        shopName: widget.config.shopName,
        taxId: widget.config.taxId,
        footer: widget.config.receiptFooter,
        formatAmount: PosApp.money,
      ).build(order);
      await _receiptPrinter.send(bytes, reference: order.uuid);
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
          SellScreen(
            session: session,
            formatAmount: PosApp.money,
            staleness: widget.catalogue.stalenessAt(DateTime.now().toUtc()),
            catalogueChanged: widget.sync.catalogueRevision,
            onChanged: _publishActivity,
            onSignOut: _signOut,
            onPaid: (order) {
              _publishActivity();
              unawaited(_printReceipt(order as Order));
            },
          ),
          Positioned(
            top: 8,
            right: 8,
            child: Builder(
              // Builder, so the push targets the Navigator inside this MaterialApp.
              builder: (context) => Row(children: [
                IconButton(
                  key: const Key('open-settings'),
                  tooltip: 'Server settings',
                  icon: const Icon(Icons.settings),
                  onPressed: () => _openSettings(context),
                ),
                IconButton(
                  key: const Key('open-diagnostics'),
                  tooltip: 'Support',
                  icon: const Icon(Icons.support_agent),
                  onPressed: () => _openDiagnostics(context),
                ),
              ]),
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
