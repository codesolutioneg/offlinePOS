import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'app/pos_app.dart';
import 'core/audit/audit_log.dart';
import 'core/auth/auth_service.dart';
import 'core/auth/pin_hasher.dart';
import 'core/auth/user_store.dart';
import 'core/db/catalogue_store.dart';
import 'core/db/database.dart';
import 'core/db/order_store.dart';
import 'core/db/sqlite_outbox_store.dart';
import 'core/sync/outbox.dart';
import 'core/sync/sync_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final dir = await getApplicationSupportDirectory();
  // TODO(security): supply the SQLCipher key from the platform keystore. Db.open
  // already accepts one; nothing reads it from secure storage yet.
  final db = Db.open('${dir.path}${Platform.pathSeparator}pos.db');

  final catalogue = CatalogueStore(db);
  final orders = OrderStore(db);
  final users = UserStore(db);
  final audit = AuditLog(db);
  final outboxStore = SqliteOutboxStore(db);

  // Senders are registered once the device is enrolled and authenticated. Until
  // then the outbox simply accumulates, which is the correct offline behaviour:
  // a sale is never blocked on having somewhere to send it.
  final outbox = Outbox(store: outboxStore, senders: {});

  final auth = AuthService(
    users: users,
    hasher: Argon2idPinHasher(),
    audit: audit,
  );

  // A fresh device has nobody who can sign in. Until enrolment is wired to the
  // server, seed one cashier so the till is usable.
  if (users.isEmpty) {
    await auth.enrol(id: 'cashier', name: 'Cashier', pin: '1234');
  }

  final sync = SyncService(outbox: outbox, catalogue: catalogue)..start();

  runApp(PosApp(
    auth: auth,
    users: users,
    catalogue: catalogue,
    orders: orders,
    outbox: outbox,
    audit: audit,
    sync: sync,
    deviceId: 'till-1',
  ));
}
