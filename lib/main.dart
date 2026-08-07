import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'app/pos_session.dart';
import 'core/audit/audit_log.dart';
import 'core/db/catalogue_store.dart';
import 'core/db/database.dart';
import 'core/db/order_store.dart';
import 'core/db/sqlite_outbox_store.dart';
import 'core/printing/receipt_builder.dart';
import 'core/sync/outbox.dart';
import 'core/sync/sync_service.dart';
import 'features/sell/sell_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final dir = await getApplicationSupportDirectory();
  final db = Db.open('${dir.path}${Platform.pathSeparator}pos.db');

  final catalogue = CatalogueStore(db);
  final orders = OrderStore(db);
  final outboxStore = SqliteOutboxStore(db);
  final audit = AuditLog(db);

  // Senders are registered once the device is enrolled and authenticated. Until
  // then the outbox simply accumulates, which is the correct offline behaviour.
  final outbox = Outbox(store: outboxStore, senders: {});

  final sync = SyncService(outbox: outbox, catalogue: catalogue)..start();

  runApp(PosApp(
    session: PosSession(
      catalogue: catalogue,
      orders: orders,
      outbox: outbox,
      audit: audit,
      // Replaced by the enrolled device id and the signed-in cashier once the
      // auth flow is wired.
      deviceId: 'till-1',
      cashierId: 'cashier',
    ),
    sync: sync,
  ));
}

class PosApp extends StatelessWidget {
  const PosApp({super.key, required this.session, required this.sync});

  final PosSession session;
  final SyncService sync;

  static String money(double v) => v.toStringAsFixed(2);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'offlinePOS',
      theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
      home: SellScreen(
        session: session,
        formatAmount: money,
        staleness: session.catalogue.stalenessAt(DateTime.now().toUtc()),
        onPaid: (order) {
          // The receipt is built as printer bytes, never rasterised. Handing them
          // to a transport is all that is left.
          ReceiptBuilder(shopName: 'OFFLINE POS', formatAmount: money).build(order);
        },
      ),
    );
  }
}
