import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import '../core/i18n/l10n.dart';

import '../core/audit/audit_log.dart';
import '../core/auth/auth_service.dart';
import '../core/auth/user_store.dart';
import '../core/config/till_config.dart';
import '../core/db/catalogue_store.dart';
import '../core/db/customer_store.dart';
import '../core/db/order_store.dart';
import '../core/db/settings_store.dart';
import '../core/db/shift_store.dart';
import '../core/db/sqlite_outbox_store.dart';
import '../core/db/table_store.dart';
import '../core/onboarding/wizard_id.dart';
import '../core/onboarding/wizard_store.dart';
import '../core/printing/escpos.dart';
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
import '../features/customers/customer_management_screen.dart';
import '../features/kitchen/kitchen_display_screen.dart';
import '../features/onboarding/wizard_overlay.dart';
import '../features/orders/open_orders_screen.dart';
import '../features/orders/order_history_screen.dart';
import '../features/orders/refund_screen.dart';
import '../features/reports/reports_hub_screen.dart';
import '../features/sell/sell_screen.dart';
import '../features/settings/appearance_settings_screen.dart';
import '../features/settings/discount_settings_screen.dart';
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

  /// The floor plan and the on-device settings a manager edits on the device.
  final TableStore tables;
  final SettingsStore settings;

  /// Customers created on the till (separate from the read-only Odoo partners).
  final CustomerStore customers;

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
      final bytes = ReceiptBuilder(
        shopName: s.shopName ?? widget.config.shopName,
        taxId: s.receiptShowTax ? (s.taxId ?? widget.config.taxId) : null,
        footer: s.receiptFooter ?? widget.config.receiptFooter,
        header: s.getString('receipt_header'),
        showCashier: s.getBool('receipt_show_cashier', fallback: true),
        showOrderType: s.getBool('receipt_show_ordertype', fallback: true),
        showTax: s.receiptShowTax,
        openDrawer: isCash && !reprint,
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
    // Rebuilds the whole app when the language changes; MaterialApp derives the
    // Arabic right-to-left direction from the locale via the localization delegates.
    return ValueListenableBuilder<Locale>(
      valueListenable: _locale,
      builder: (context, locale, _) => MaterialApp(
        title: 'offlinePOS',
        // Tuned for a touch screen: comfortable spacing and buttons/inputs tall
        // enough to tap reliably with a finger.
        theme: ThemeData(
          colorSchemeSeed: Colors.teal,
          useMaterial3: true,
          visualDensity: VisualDensity.comfortable,
          filledButtonTheme: FilledButtonThemeData(
              style: FilledButton.styleFrom(minimumSize: const Size(0, 48))),
          outlinedButtonTheme: OutlinedButtonThemeData(
              style: OutlinedButton.styleFrom(minimumSize: const Size(0, 48))),
          chipTheme: const ChipThemeData(
              padding: EdgeInsets.symmetric(horizontal: 10, vertical: 8)),
          listTileTheme: const ListTileThemeData(minVerticalPadding: 10),
        ),
        locale: locale,
        supportedLocales: kSupportedLocales,
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: session == null
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
              categoryColors: widget.settings.categoryColors,
              quickComments: widget.settings.quickComments,
              discountReasons: widget.settings.discountReasons,
              discountPercents: widget.settings.discountPercents,
              maxDiscountPercent: widget.settings.maxDiscountPercent,
              authorize: () => _authorizeManager(context),
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
              // Fire the kitchen ticket but keep the order on the counter.
              onSendToKitchen: () => unawaited(_fireKitchen(session.current)),
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
            onTap: () {
              Navigator.pop(rootContext);
              _openReports(rootContext);
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

  void _openOrders(BuildContext context, PosSession session) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (sheetContext) => OpenOrdersScreen(
        orders: widget.orders.held(),
        formatAmount: PosApp.money,
        onRecall: (order) => setState(() => session.recall(order.uuid)),
        // Discarding a parked order is money not taken, so it is manager-gated and
        // audited, then the list is popped so the change is visible.
        onCancel: (order) async {
          if (!await _authorizeManager(sheetContext)) return;
          widget.orders.delete(order.uuid);
          widget.audit.record(session.cashierId, 'order.cancelled', detail: order.uuid);
          if (sheetContext.mounted) Navigator.of(sheetContext).pop();
          setState(() {});
        },
      ),
    ));
  }

  void _openHistory(BuildContext context) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => OrderHistoryScreen(
        orders: widget.orders.recent(limit: 1000),
        formatAmount: PosApp.money,
        onReprint: (order) => _printReceipt(order, reprint: true),
        onRefund: (order) => _openRefund(context, order),
      ),
    ));
  }

  /// Refund a past sale: pick the lines, then record, queue and print the reversal.
  Future<void> _openRefund(BuildContext context, Order original) async {
    // A refund returns money, so it needs manager approval before the flow opens.
    if (!await _authorizeManager(context)) return;
    if (!context.mounted) return;
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => RefundScreen(
        original: original,
        formatAmount: PosApp.money,
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
      ),
    ));
  }

  /// The floor plan. Tapping a table recalls the order parked on it, or starts a
  /// fresh dine-in seated at it, then drops back to the sell screen.
  void _openFloor(BuildContext context, PosSession session) {
    final held = widget.orders.held();
    final occupied = held.map((o) => o.tableLabel).whereType<String>().toSet();
    // Running total + open-since per occupied table, for the floor tiles.
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
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => TableFloorScreen(
        store: widget.tables,
        occupiedLabels: occupied,
        occupiedInfo: info,
        formatAmount: PosApp.money,
        onOpenTable: (t) {
          // Tapping the table the current order is already seated at just returns
          // to it rather than parking it and starting a duplicate.
          if (session.current.tableLabel == t.name &&
              session.current.lines.isNotEmpty) {
            Navigator.of(context).pop();
            return;
          }
          final held =
              widget.orders.held().where((o) => o.tableLabel == t.name).toList();
          setState(() {
            if (held.isNotEmpty) {
              session.recall(held.first.uuid);
            } else {
              session.newOrder();
              session.setOrderType(OrderType.dineIn);
              session.setTable(t.name);
              if (t.seats > 0) session.setGuestCount(t.seats);
            }
          });
          Navigator.of(context).pop();
        },
      ),
    ));
  }

  /// The settings hub: one door onto everything a manager configures on the device.
  void _openSettingsHub(BuildContext context) {
    final isManager = widget.auth.signedIn?.isManager ?? false;
    void refresh() => setState(() {});
    void push(Widget screen) => Navigator.of(context)
        .push(MaterialPageRoute<void>(builder: (_) => screen));
    // Sensitive config (server credentials, printers, shop identity) is manager-only
    // so a cashier cannot repoint the till or rewrite the receipt; a manager passes
    // straight through.
    Future<void> pushGated(Widget screen) async {
      if (!await _authorizeManager(context)) return;
      push(screen);
    }
    final entries = <SettingsEntry>[
      SettingsEntry(
        title: _locale.isArabic ? 'Language: العربية' : 'Language: English',
        subtitle: 'Switch English / العربية',
        icon: Icons.language,
        keyValue: 'set-language',
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
        onTap: () => pushGated(ShopSettingsScreen(settings: widget.settings, onChanged: refresh)),
      ),
      SettingsEntry(
        title: 'Receipt designer',
        subtitle: 'Header, footer, what prints',
        icon: Icons.receipt_long,
        keyValue: 'set-receipt',
        onTap: () => push(ReceiptDesignerScreen(
            settings: widget.settings,
            onChanged: refresh,
            onTestPrint: () => _printReceipt(_sampleOrder(), reprint: true))),
      ),
      SettingsEntry(
        title: 'Printers & kitchen routing',
        icon: Icons.print,
        keyValue: 'set-printers',
        onTap: () => pushGated(PrintersScreen(
            printers: widget.printers,
            settings: widget.settings,
            categories: widget.catalogue.categories(),
            onChanged: refresh)),
      ),
      SettingsEntry(
        title: 'Category colours',
        icon: Icons.palette,
        keyValue: 'set-appearance',
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
        onTap: () => push(CustomerManagementScreen(store: widget.customers, onChanged: refresh)),
      ),
      SettingsEntry(
        title: 'Quick notes',
        icon: Icons.sticky_note_2_outlined,
        keyValue: 'set-notes',
        onTap: () => push(QuickCommentsScreen(settings: widget.settings, onChanged: refresh)),
      ),
      SettingsEntry(
        title: 'Discounts',
        subtitle: 'Percentages, cap, reasons',
        icon: Icons.percent,
        keyValue: 'set-discounts',
        onTap: () => push(DiscountSettingsScreen(settings: widget.settings, onChanged: refresh)),
      ),
      SettingsEntry(
        title: 'Server (Odoo)',
        subtitle: 'Where sales sync at shift close',
        icon: Icons.dns,
        keyValue: 'set-server',
        onTap: () async {
          final ok = await _authorizeManager(context);
          if (ok && context.mounted) _openSettings(context);
        },
      ),
      if (isManager)
        SettingsEntry(
          title: 'Staff',
          icon: Icons.badge_outlined,
          keyValue: 'set-staff',
          onTap: () => _openRoster(context),
        ),
    ];
    push(SettingsHubScreen(entries: entries));
  }

  /// Gate a privileged action behind manager approval. A manager already signed in
  /// passes straight through; anyone else must enter a manager PIN.
  Future<bool> _authorizeManager(BuildContext context) async {
    if (widget.auth.signedIn?.isManager ?? false) return true;
    final ctrl = TextEditingController();
    final pin = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr(ctx, 'Manager approval')),
        content: TextField(
          key: const Key('manager-pin'),
          controller: ctrl,
          autofocus: true,
          obscureText: true,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(
              labelText: tr(ctx, 'Manager PIN'), border: const OutlineInputBorder()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr(ctx, 'Cancel'))),
          FilledButton(
            key: const Key('manager-ok'),
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: Text(tr(ctx, 'Approve')),
          ),
        ],
      ),
    );
    if (pin == null || pin.isEmpty) return false;
    final ok = await widget.auth.authorizeManager(pin);
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(tr(context, 'Manager approval failed'))));
    }
    return ok;
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
    // Route each line to its category's station, so a multi-station kitchen sends
    // hot food and bar drinks to different printers. Unmapped categories fall to
    // the single default kitchen.
    final routed = routeToStations(lines,
        categoryToStation: widget.settings.categoryStations);
    for (final entry in routed.entries) {
      final bytes = builder.build(order, only: entry.value, station: entry.key);
      final ok = await _sendToStation(entry.key, bytes, 'kot-${order.uuid}');
      // Only mark a line fired if its ticket reached a printer or the spool. A
      // truly lost ticket leaves its lines un-fired so a later re-fire retries them
      // rather than silently dropping food off the pass.
      if (ok) {
        for (final l in entry.value) {
          l.printedToKitchen = true;
        }
      }
    }
    widget.orders.save(order);
  }

  Future<void> _fireVoid(Order order, OrderLine line, String reason) async {
    final bytes = KitchenTicketBuilder().buildVoid(order, line, reason);
    await _sendToStation('kitchen', bytes, 'void-${order.uuid}-${line.uuid}');
  }

  /// Send a kitchen ticket to [station]. Returns true if it reached a printer or was
  /// safely spooled for retry, false if it was lost outright (so the caller can keep
  /// the lines un-fired and retry later).
  Future<bool> _sendToStation(String station, List<int> bytes, String reference) async {
    final payload = Uint8List.fromList(bytes);
    try {
      await RegistryPrinter(widget.printers, station).send(payload);
      return true;
    } on PrinterUnavailable {
      // No station printer: fall back to the receipt printer, spooled if that is
      // down too, so the ticket is not simply lost.
      try {
        await _receiptPrinter.send(payload, reference: reference);
        return true;
      } on PrinterUnavailable {
        // Held in the spool; the background flush will retry it.
        return true;
      } catch (e) {
        widget.audit.record(_session?.cashierId ?? 'system', 'kitchen.failed',
            detail: '$reference: $e');
        return false;
      }
    } catch (e) {
      widget.audit.record(_session?.cashierId ?? 'system', 'kitchen.failed',
          detail: '$reference: $e');
      return false;
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
        onPrintReport: _printShiftReport,
        // Closing the shift is when the day's orders are pushed to Odoo in one
        // batch. Returns a message for the cashier: how it went, or that the
        // orders are safe and will sync once the connection is back.
        onCloseSync: () async {
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
      ),
    ));
  }
}
