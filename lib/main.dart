import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'app/pos_app.dart';
import 'app/till_activity.dart';
import 'core/audit/audit_log.dart';
import 'core/auth/auth_service.dart';
import 'core/auth/bootstrap_cashier.dart';
import 'core/auth/pin_hasher.dart';
import 'core/auth/user_store.dart';
import 'core/config/till_config.dart';
import 'core/db/attempt_store.dart';
import 'core/db/catalogue_store.dart';
import 'core/db/database.dart';
import 'core/db/device_store.dart';
import 'core/db/order_store.dart';
import 'core/db/print_job_store.dart';
import 'core/db/printer_store.dart';
import 'core/db/sqlite_outbox_store.dart';
import 'core/onboarding/wizard_store.dart';
import 'core/printing/printer_discovery.dart';
import 'core/printing/printer_registry.dart';
import 'core/sync/outbox.dart';
import 'core/sync/odoo_endpoint.dart';
import 'core/sync/odoo_wiring.dart';
import 'core/sync/sync_service.dart';
import 'core/updates/update_gate.dart';
import 'core/updates/update_service.dart';
import 'core/updates/update_storage.dart';
import 'core/updates/update_transport.dart';

/// The version this build reports to support and compares update manifests
/// against. Supplied by the build so it cannot drift from what was actually
/// shipped: `--dart-define=APP_VERSION=$(grep version pubspec.yaml ...)`.
const String appVersion = String.fromEnvironment('APP_VERSION', defaultValue: '0.0.0-dev');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final config = TillConfig.fromEnvironment();

  final dir = await getApplicationSupportDirectory();
  // Not encrypted. `sqlite3` here is the plain build, not SQLCipher, so a key
  // would be accepted and ignored; docs/SECURITY.md carries this as an open
  // go-live blocker rather than a claim that it is done.
  final db = Db.open('${dir.path}${Platform.pathSeparator}pos.db');

  final catalogue = CatalogueStore(db);
  final orders = OrderStore(db);
  final users = UserStore(db);
  final audit = AuditLog(db);
  final outboxStore = SqliteOutboxStore(db);
  final devices = DeviceStore(db);

  // Generated on this device on first launch. A constant would make every till in
  // a shop file its sales under the same id.
  final deviceId = devices.deviceId();

  // Senders are registered once the device is enrolled and authenticated. Until
  // then the outbox simply accumulates, which is the correct offline behaviour:
  // a sale is never blocked on having somewhere to send it. The support screen
  // says so plainly rather than reporting the till as online.
  final outbox = Outbox(store: outboxStore, senders: {});

  final auth = AuthService(
    users: users,
    hasher: Argon2idPinHasher(),
    audit: audit,
    // On disk, so force-quitting between guesses does not reset the count.
    attempts: SqliteAttemptStore(db),
  );

  // Random, per device, shown once on the sign-in screen. Never a literal: see
  // BootstrapCashier for why.
  final provisioningPin = await BootstrapCashier.ensure(auth, users);

  final sync = SyncService(
    outbox: outbox,
    catalogue: catalogue,
    outboxStore: outboxStore,
    audit: audit,
    deviceId: deviceId,
    appVersion: appVersion,
  )..start();

  // Printers are resolved by name at print time, so a DHCP lease that moves
  // overnight costs one subnet sweep rather than a support call. Nothing is
  // configured on a fresh till: the receipt printer is named on the diagnostics
  // screen, and until then a sale still completes and the receipt spools.
  final printerStore = PrinterStore(db);
  late final PrinterRegistry printers;
  printers = PrinterRegistry.fromMap(
    printerStore.load(),
    discovery: PrinterDiscovery(),
    onChanged: () => printerStore.save(printers.toMap()),
  );

  // What a cashier is doing right now, read by the update gate so a build cannot
  // land on a till with a customer standing at it mid-order.
  final activity = TillActivity();

  // Point the outbox at an Odoo server if this till has been configured, so a
  // sale queued while unconfigured still goes out once a server is set. Selling
  // never depends on it; an unconfigured till simply accumulates.
  final endpoints = OdooEndpointStore(db);
  final odoo = OdooWiring(outbox: outbox);
  // A build may carry a default endpoint via --dart-define for a quick local test;
  // a saved one entered on the device wins over it.
  const envUrl = String.fromEnvironment('ODOO_URL');
  if (envUrl.isNotEmpty && !endpoints.isConfigured) {
    endpoints.save(OdooEndpoint(
      baseUrl: envUrl,
      db: const String.fromEnvironment('ODOO_DB'),
      login: const String.fromEnvironment('ODOO_LOGIN'),
      password: const String.fromEnvironment('ODOO_PASSWORD'),
    ));
  }
  final savedEndpoint = endpoints.load();
  if (savedEndpoint != null && savedEndpoint.isComplete) {
    odoo.configure(savedEndpoint);
  }

  runApp(PosApp(
    auth: auth,
    users: users,
    catalogue: catalogue,
    orders: orders,
    outbox: outbox,
    audit: audit,
    sync: sync,
    outboxStore: outboxStore,
    printers: printers,
    receiptSpool: SqlitePrintJobStore(db, printer: PosApp.receiptPrinter),
    wizards: WizardStore(db),
    deviceId: deviceId,
    config: config,
    activity: activity,
    provisioningPin: provisioningPin,
    updates: _updateService(config, sync, activity, dir),
    endpoints: endpoints,
    odoo: odoo,
  ));
}

/// The update channel, or null when this build has none configured.
///
/// Null is a real answer, not a fallback. An update path is only assembled when
/// the manifest url, the release public key and the certificate pins are all
/// present, because a partly configured channel filled in with defaults is how an
/// unsigned or unpinned auto-update gets shipped by accident. That is remote code
/// execution on every till, which docs/SECURITY.md names directly.
UpdateService? _updateService(
  TillConfig config,
  SyncService sync,
  TillActivity activity,
  Directory support,
) {
  if (!config.hasUpdateChannel) return null;

  final transport = PinnedUpdateTransport(
    certificateSha256: config.updateCertificatePins,
  );

  return UpdateService(
    manifestUrl: config.updateManifestUrl!,
    currentVersion: appVersion,
    verifier: config.updateVerifier,
    // Built from the same numbers the heartbeat reports, so the gate and support
    // never disagree about how much is waiting.
    readTill: () => TillState.fromDeviceStatus(
      sync.status(),
      localTime: DateTime.now(),
      saleInProgress: activity.saleInProgress,
      soleTill: config.soleTill,
    ),
    fetchText: transport.fetchText,
    fetchBytes: transport.fetchBytes,
    storage: FileUpdateStorage(
      Directory('${support.path}${Platform.pathSeparator}updates'),
    ),
  );
}
