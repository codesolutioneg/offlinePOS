import 'package:flutter/material.dart';

import '../core/audit/audit_log.dart';
import '../core/auth/auth_service.dart';
import '../core/auth/user_store.dart';
import '../core/db/catalogue_store.dart';
import '../core/db/order_store.dart';
import '../core/printing/receipt_builder.dart';
import '../core/sync/outbox.dart';
import '../core/sync/sync_service.dart';
import '../features/auth/login_screen.dart';
import '../features/sell/sell_screen.dart';
import 'pos_session.dart';

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
    required this.deviceId,
    this.shopName = 'OFFLINE POS',
  });

  final AuthService auth;
  final UserStore users;
  final CatalogueStore catalogue;
  final OrderStore orders;
  final Outbox outbox;
  final AuditLog audit;
  final SyncService sync;
  final String deviceId;
  final String shopName;

  static String money(double v) => v.toStringAsFixed(2);

  @override
  State<PosApp> createState() => _PosAppState();
}

class _PosAppState extends State<PosApp> {
  PosSession? _session;

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
    });
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
            )
          : SellScreen(
              session: session,
              formatAmount: PosApp.money,
              staleness: widget.catalogue.stalenessAt(DateTime.now().toUtc()),
              onPaid: (order) {
                // Built as printer bytes, never rasterised. Handing them to a
                // transport is all that remains.
                ReceiptBuilder(
                  shopName: widget.shopName,
                  formatAmount: PosApp.money,
                ).build(order);
              },
            ),
    );
  }
}
