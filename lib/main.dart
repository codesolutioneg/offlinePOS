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
import 'core/db/db_key.dart';
import 'core/db/secure_key_store.dart';
import 'core/db/device_store.dart';
import 'core/db/attendance_store.dart';
import 'core/db/customer_store.dart';
import 'core/db/delivery_store.dart';
import 'core/db/order_store.dart';
import 'core/db/settings_store.dart';
import 'core/db/table_assignment_store.dart';
import 'core/db/table_store.dart';
import 'core/db/print_job_store.dart';
import 'core/db/reservation_store.dart';
import 'core/db/printer_store.dart';
import 'core/db/shift_store.dart';
import 'core/db/sqlite_outbox_store.dart';
import 'core/diagnostics/startup_failure_app.dart';
import 'core/diagnostics/startup_log.dart';
import 'core/diagnostics/startup_probe.dart';
import 'core/diagnostics/startup_unwind.dart';
import 'core/email/email_outbox.dart';
import 'core/email/email_service.dart';
import 'core/export/db_backup.dart';
import 'core/lan/lan_cart_board.dart';
import 'core/lan/lan_credential.dart';
import 'core/lan/lan_wiring.dart';
import 'core/onboarding/wizard_store.dart';
import 'core/printing/printer_discovery.dart';
import 'core/printing/printer_registry.dart';
import 'core/sync/batch_push.dart';
import 'core/sync/http_post.dart';
import 'core/sync/outbox.dart';
import 'core/sync/odoo_endpoint.dart';
import 'core/sync/odoo_puller.dart';
import 'core/sync/odoo_wiring.dart';
import 'core/sync/retry_arming.dart';
import 'core/sync/server_probe.dart';
import 'core/sync/sync_service.dart';
import 'core/updates/update_gate.dart';
import 'core/updates/update_service.dart';
import 'core/updates/update_storage.dart';
import 'core/updates/update_transport.dart';
import 'core/updates/windows_installer.dart';

/// The version this build reports to support and compares update manifests
/// against.
///
/// Supplied by the build so it cannot drift from what was actually shipped: CI
/// reads the version out of pubspec.yaml and passes it with the CI build number as
/// metadata (`--dart-define=APP_VERSION=1.1.0+42`), alongside the matching
/// `--build-name` / `--build-number` that stamp the exe. The comparison ignores
/// everything after the '+', so the build number tells two builds of one release
/// apart without either counting as newer. The default marks a build nobody
/// stamped, which is a local run.
const String appVersion = String.fromEnvironment('APP_VERSION', defaultValue: '0.0.0-dev');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final log = StartupLog.forThisLaunch()..begin(appVersion);
  // What to undo if a later step throws. A failure screen with the sync timer
  // still running behind it is a till that says it is shut while it goes on
  // talking to the server, and it would hold the database open against the next
  // launch.
  final unwind = StartupUnwind();
  try {
    await _openTheTill(log, unwind);
  } catch (error, stack) {
    log.failed(error, stack);
    unwind.run(log);
    // The window is only shown once a frame has been rendered, so a startup that
    // threw would otherwise leave a live process and an empty screen: no window,
    // no error, nothing to report. Say what happened, in language the person at
    // the counter can act on, and put the report where they can be asked for it.
    runApp(StartupFailureApp(
      error: error,
      logPath: log.path,
      reportPath: log.copyForSupport(),
    ));
  }
}

/// Everything the till needs before it can show its first screen.
///
/// Anything started here that outlives a throw is registered on [unwind], so a
/// launch that fails part way leaves nothing running behind the failure screen.
Future<void> _openTheTill(StartupLog log, StartupUnwind unwind) async {
  log.step('read the build configuration');
  final config = TillConfig.fromEnvironment();

  log.step('resolve the application support directory');
  final dir = await getApplicationSupportDirectory();
  // Encrypted at rest with SQLCipher. The key is generated once and kept in the
  // platform keychain via SecureKeyStore, never in a file beside the data. If the
  // keychain is ever wiped, an existing database becomes unreadable rather than
  // silently reset: a till must be synced before a wipe, which is why enrolment
  // happens online. See docs/SECURITY.md.
  final dbPath = '${dir.path}${Platform.pathSeparator}pos.db';
  // Written before the first thing that can fail, so the report answers the
  // questions support would otherwise have to ask the operator to go and look up.
  log.facts(StartupProbe.facts(version: appVersion, databasePath: dbPath));

  log.step('read the database key from the platform keychain');
  // Told whether there is anything to lose: with a database already on disk a
  // missing key is retried and then refused, never replaced. See DbKey.
  final dbKey = await DbKey(SecureKeyStore())
      .getOrCreate(databaseExists: File(dbPath).existsSync());

  // The path, never the key. A key the keychain no longer has and a file another
  // instance still holds are the two failures that strand a launch here, and both
  // are named by this being the last line in the log.
  log.step('open and migrate the encrypted database at $dbPath');
  final db = Db.open(dbPath, encryptionKey: dbKey);
  // Deliberately not closed on a failed launch. SyncService.start fires one pass
  // that is not awaited, and stop() only cancels the timer, so disposing the
  // handle here could pull it out from under a read still in flight. The failure
  // screen is a terminal state and the process releases the file when it exits.

  final catalogue = CatalogueStore(db);
  final users = UserStore(db);
  final audit = AuditLog(db);
  final outboxStore = SqliteOutboxStore(db);
  final devices = DeviceStore(db);

  // Generated on this device on first launch. A constant would make every till in
  // a shop file its sales under the same id.
  log.step('read this device id');
  final deviceId = devices.deviceId();

  final settings = SettingsStore(db);

  // Whether this device shares state with the others in the shop. Off unless it was
  // asked for: the device's own switch decides, and the build's dart-define is only
  // what it falls back to, so a shop that adds a second till flips a setting rather
  // than waiting for a new binary. Off means nothing below is built at all, and a
  // till behaves exactly as it did before the fabric existed: no event, no socket.
  final lanOn = settings.lanEnabled(fallback: config.lanDefault);

  // Assembled further down, after the stores it writes through. The stores reach it
  // through this holder rather than the other way round, because a store announces
  // from inside its own write transaction.
  LanNode? lan;

  final orders = OrderStore(
    db,
    // Scoped to this till whether or not the fabric is on. A device that shared for
    // a week and was then taken off the LAN still has the other tills' orders on
    // disk, and only the till that rang a sale may ever recall, report or book it.
    ownDeviceId: deviceId,
    publish: lanOn ? (kind, uuid, payload) => lan?.publish(kind, uuid, payload) : null,
    // Whether the counter is put on the shop network for a customer-facing display
    // to show. Off unless a shop has one, and then it is the only thing the fabric
    // writes while an order is being rung.
    publishesCart: lanOn ? () => LanCartBoard(settings).publishing : null,
    // A change that committed but could not be announced is a shop whose devices
    // have quietly stopped agreeing. The sale is already safe, so this is the only
    // way support finds out.
    onAnnounceFailed: (uuid, error) =>
        audit.record('system', 'lan.publish.failed', detail: '$uuid: $error'),
  );
  final tables = TableStore(
    db,
    publish: lanOn ? (kind, uuid, payload) => lan?.publish(kind, uuid, payload) : null,
  );
  // Bookings, shared for the same reason the floor plan is: one taken at the
  // counter has to reach the handheld the waiter is holding.
  final reservations = ReservationStore(
    db,
    publish: lanOn ? (kind, uuid, payload) => lan?.publish(kind, uuid, payload) : null,
  );
  // Who works which table. Shared because the manager hands the room out on one
  // device and the waiters read it on the others; a handheld that never heard the
  // assignment would refuse its own waiter their own tables.
  final assignments = TableAssignmentStore(
    db,
    publish: lanOn ? (kind, uuid, payload) => lan?.publish(kind, uuid, payload) : null,
  );
  // What the kitchen shouted, told to every device: an item off the menu is a fact
  // about the shop, so the 86 board is shared the same way a parked tab is.
  settings.publish =
      lanOn ? (kind, uuid, payload) => lan?.publish(kind, uuid, payload) : null;

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
  log.step('ensure the bootstrap cashier');
  final provisioningPin = await BootstrapCashier.ensure(auth, users);

  // One transport for every Odoo call: the login, the order push, the catalogue
  // pull and the reachability probe below. Certificate-pinned when this build was
  // given pins for the server, plain platform trust when it was not, so a shop
  // without pins keeps syncing exactly as it did.
  final post = odooPost(config.syncCertificatePins);

  // The catalogue pull rides the same authenticated Odoo session as the order
  // push. Built here, before any endpoint is configured, but it reads the live
  // sender at call time, so a server entered later still refreshes the menu.
  final odoo = OdooWiring(
    outbox: outbox,
    post: post,
    // Once the server books a sale, mark it synced so the history badge is honest.
    onOrderBooked: orders.markSynced,
    // A server-rejected sale is money taken but never booked; record it so it is
    // not visible only as a diagnostics count.
    onOrderRejected: (uuid, reason) =>
        audit.record('system', 'order.rejected', detail: '$uuid: $reason'),
  );

  // The endpoint store is read here so the connectivity probe below can see the
  // live server, and again later to point the outbox at it.
  final endpoints = OdooEndpointStore(db);

  // A cheap, unauthenticated reachability check: version_info answers on any
  // running Odoo. It books nothing, so it is safe to run on the timer purely to
  // keep the online/offline badge honest. Orders are never pushed here.
  Future<bool> probeOnline() => serverIsReachable(endpoints.load(), post);

  // The same probe with the login question added, for the Test connection button on
  // the server screen. Button-driven only: it authenticates, and the badge must not.
  Future<ServerCheckResult> checkTheServer(OdooEndpoint e) => checkServer(e, post);

  log.step('start the sync service');
  final sync = SyncService(
    outbox: outbox,
    catalogue: catalogue,
    outboxStore: outboxStore,
    audit: audit,
    deviceId: deviceId,
    appVersion: appVersion,
    // The branch is read at the moment of each pull, so a till moved to another
    // branch has the right menu on its next refresh rather than its next restart.
    //
    // The warehouse, not the company. A branch here is an outlet, and an outlet is
    // a warehouse: that is what a sale already carries, what a requisition calls
    // the branch warehouse, and what this shop's twenty of them are named after.
    // The company is one row, so filtering a menu on it selected everything and
    // looked like the feature working.
    puller: OdooPuller(
      call: odoo.catalogueCall,
      branchId: () => settings.odooWarehouseId,
      // Read at the moment of each pull too: the till authenticates lazily, so the
      // user is often not known yet when this is built.
      userId: () => odoo.uid,
    ),
    probe: probeOnline,
    // Re-queue any paid sale that is not on the wire before a batch push. The
    // outbox is unique on (kind, uuid), so this never double-books.
    reconcile: () async {
      for (final o in orders.awaitingSync()) {
        await outbox.enqueue('order.push', o.uuid, o.toServerPayload());
      }
    },
    // The shop's option to have its night arrive as one sales order. Answers
    // false and costs nothing while the switch is off, which is where it stays
    // until jouma can take a batch: see docs/ODOO_SYNC.md.
    mergeBatch: BatchPush(
      outboxStore: outboxStore,
      send: odoo.pushPayload,
      enabled: () => settings.mergeBatchIntoOneSaleOrder,
      // The shift is the batch, and it already carries a uuid of its own. Read
      // after the close, so it is the shift that was just counted.
      batchUuid: () => ShiftStore(db).latestShift()?.uuid,
      onOrderBooked: orders.markSynced,
    ).run,
    // So a close that failed at midnight is still owed in the morning. start()
    // reads it back before the first tick.
    arming: SettingsRetryArming(settings),
  )..start();
  // Its timer is running from here, so a later failure has to switch it off:
  // otherwise the till goes on talking to the server behind a screen that says it
  // could not open.
  unwind.add(sync.stop);

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

  // Nothing is bound or announced here. The node is only assembled; PosApp starts it
  // behind the first frame, so no part of opening the till waits on a socket, a LAN
  // address or a peer.
  if (lanOn) {
    log.step('assemble the LAN node');
    // The first till to share invents the shop's key; the others are paired by
    // copying it across on the shop network screen. Until a device holds the same
    // key it is turned away, so switching sharing on does not open this till's tabs
    // to whatever else is on the subnet.
    settings.lanShopKey ??= LanCredential.newKey();
    lan = LanNode.build(
      db: db,
      deviceId: deviceId,
      // Read at the moment of the request, so a manager who rotates the key has
      // rotated it for the next one instead of at the next restart. Inventing one
      // again if it is ever cleared keeps the fabric refusing strangers: an empty
      // key is a key everybody knows.
      shopKey: () => settings.lanShopKey ??= LanCredential.newKey(),
      // Unnamed until a manager names it on the shop network screen. The id is what
      // the other devices show until then, which is honest: two devices that both
      // call themselves "Till" are worse than two ids.
      deviceName: settings.lanDeviceName ?? deviceId,
      orders: orders,
      tables: tables,
      settings: settings,
      reservations: reservations,
      assignments: assignments,
      audit: audit,
      port: config.lanPort,
      beaconPort: config.lanBeaconPort,
    );
  }

  // The last line of a launch that got everything it needed. If the log ends here
  // and there is still no window, the till started and the window is the problem,
  // not the startup.
  log.step('render the first frame');
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
    shifts: ShiftStore(db),
    deviceId: deviceId,
    config: config,
    activity: activity,
    provisioningPin: provisioningPin,
    updates: _updateService(config, sync, activity, dir),
    endpoints: endpoints,
    checkServer: checkTheServer,
    // One copy of the whole till, encrypted as it sits, for the day the machine
    // does not come back on.
    backup: () => backupDatabase(db),
    odoo: odoo,
    tables: tables,
    settings: settings,
    customers: CustomerStore(db),
    delivery: DeliveryStore(db),
    attendance: AttendanceStore(db),
    reservations: reservations,
    assignments: assignments,
    lan: lan,
    // The Z report by mail. Reads the settings on every attempt, so a password
    // corrected mid-evening is used by the next retry without a restart.
    emailer: EmailService(
      queue: EmailOutbox(db),
      config: () => settings.smtp,
      audit: audit,
    ),
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

  // One directory for the staged build and for the handoff script that installs
  // it. Both of them decide what this till ends up running, so both belong
  // somewhere only this app can write.
  final staging = Directory('${support.path}${Platform.pathSeparator}updates');

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
    storage: FileUpdateStorage(staging),
    // Null off Windows: there a verified build is staged and installed by hand,
    // which is the intended answer rather than a missing one.
    installer: platformUpdateInstaller(stagingDirectory: staging),
  );
}
