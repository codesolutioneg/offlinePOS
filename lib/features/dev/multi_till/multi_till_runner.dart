import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;

import '../../../app/pos_session.dart';
import '../../../core/audit/audit_log.dart';
import '../../../core/cloud/cloud_client.dart';
import '../../../core/cloud/cloud_sync_service.dart';
import '../../../core/cloud/cloud_sync_state.dart';
import '../../../core/cloud/report_lookups.dart';
import '../../../core/db/catalogue_store.dart';
import '../../../core/db/database.dart';
import '../../../core/db/order_store.dart';
import '../../../core/db/reservation_store.dart';
import '../../../core/db/settings_store.dart';
import '../../../core/db/shift_store.dart';
import '../../../core/db/sqlite_outbox_store.dart';
import '../../../core/db/table_assignment_store.dart';
import '../../../core/db/table_store.dart';
import '../../../core/lan/lan_applier.dart';
import '../../../core/lan/lan_event.dart';
import '../../../core/lan/lan_event_log.dart';
import '../../../core/sync/batch_push.dart';
import '../../../core/sync/odoo_endpoint.dart';
import '../../../core/sync/odoo_wiring.dart';
import '../../../core/sync/outbox.dart';
import '../../../domain/catalogue.dart';
import '../../../domain/order.dart';
import '../../../domain/shift.dart';

/// How big a multi-till run is, and where its sessions go.
class MultiTillConfig {
  const MultiTillConfig({
    this.tills = 6,
    this.cashiers = 2,
    this.sessions = 3,
    this.ordersPerSession = 10,
    this.sendToOdoo = true,
    this.cloudUrl,
    this.pairCode,
    this.pause = Duration.zero,
  });

  /// How long each cashier waits between two orders, so a run can be made long
  /// enough to pull the network out halfway through it.
  final Duration pause;

  /// Points of sale, each a till of its own.
  final int tills;

  /// Cashiers selling at once on each till.
  final int cashiers;

  /// Sessions each till opens, sells through and closes.
  final int sessions;

  /// Orders each till takes in one session, shared out between its cashiers.
  final int ordersPerSession;

  /// Close every session into Odoo the way a real close does.
  final bool sendToOdoo;

  /// The reports server and the branch code the tills pair with; no code, no upload.
  final String? cloudUrl;
  final String? pairCode;

  bool get uploads => (pairCode ?? '').trim().isNotEmpty && (cloudUrl ?? '').trim().isNotEmpty;
}

/// What the live till lends a run: its menu, its staff, its tax rules and its
/// Odoo connection. Nothing in the live till's own database is written.
class MultiTillDeps {
  const MultiTillDeps({
    required this.catalogue,
    required this.staff,
    required this.lookups,
    required this.appVersion,
    this.taxRateFor,
    this.serviceChargeFor,
    this.odooEndpoint,
    this.odooPost,
    this.sessionPartnerId,
    this.sessionPartnerName,
    this.cloudHttp,
  });

  final CatalogueStore catalogue;

  /// Who rings the sales, so the reports name real people.
  final List<String> staff;
  final ReportLookups Function() lookups;
  final String appVersion;
  final double? Function(int? categoryId, OrderType type)? taxRateFor;
  final double Function(OrderType type)? serviceChargeFor;
  final OdooEndpoint? odooEndpoint;
  final HttpPostFn? odooPost;
  final int? Function()? sessionPartnerId;
  final String? Function()? sessionPartnerName;

  /// The line to the reports server; the real network when null.
  final http.Client? cloudHttp;

  bool get hasOdoo => odooEndpoint != null && odooEndpoint!.isComplete;
}

/// One till's one session, as the report shows it.
class MultiTillSession {
  MultiTillSession({required this.till, required this.session});

  final int till;
  final int session;
  int orders = 0;
  double total = 0;
  String? odooRef;
  String? odooProblem;
  int uploaded = 0;
  String? cloudProblem;
  Duration took = Duration.zero;

  /// The shift this session closed, kept so a close that could not reach Odoo
  /// can be sent again under the same key once the line is back.
  Shift? closed;

  /// Odoo attempts this session took, the first close included.
  int odooTries = 0;

  bool get owesOdoo => closed != null && odooRef == null && odooProblem != null;
}

/// What a whole run did, and what it found wrong.
class MultiTillReport {
  MultiTillReport({required this.config, required this.started});

  final MultiTillConfig config;
  final DateTime started;
  DateTime? finished;
  final List<MultiTillSession> sessions = [];
  final List<String> problems = [];

  /// Every sale rung, by uuid, and the till that rang it.
  final Map<String, String> rung = {};

  /// Every sale handed to the reports server, by uuid, with the tills that sent it.
  /// One till sending a sale again after it changed is an update of the same
  /// record; two tills sending it is the duplicate the run is looking for.
  final Map<String, Set<String>> uploadedOrders = {};

  /// Copies of other tills' sales each till ended up holding over the LAN.
  final Map<int, int> replicated = {};

  double get total => sessions.fold(0.0, (s, x) => s + x.total);
  int get odooBooked => sessions.where((s) => s.odooRef != null).length;
  int get duplicateUploads => uploadedOrders.values.where((by) => by.length > 1).length;

  /// Sales sent by a till other than the one that rang them.
  int get uploadedByStranger => uploadedOrders.entries
      .where((e) => rung[e.key] != null && e.value.any((d) => d != rung[e.key]))
      .length;
  int get missingUploads => rung.keys.where((u) => !uploadedOrders.containsKey(u)).length;

  /// Sessions closed on the till that Odoo has not booked yet.
  int get owedToOdoo => sessions.where((s) => s.owesOdoo).length;
}

typedef MultiTillProgress = void Function(String step, int done, int total);

/// A finished run whose tills are still standing, so whatever the network kept
/// from Odoo or the reports site can be sent again the way a real till does once
/// the line comes back. Close it to let the tills go.
class MultiTillRun {
  MultiTillRun._(this.report, this._tills, this._lan);

  final MultiTillReport report;
  final List<_VirtualTill> _tills;
  final _VirtualLan? _lan;
  bool _retrying = false;
  bool _closed = false;

  /// When the first retry found something still owed, and when nothing was.
  DateTime? waitingSince;
  DateTime? caughtUpAt;
  int retries = 0;

  /// Nothing is owed to Odoo or the reports site.
  bool get settled {
    final c = report.config;
    if (c.sendToOdoo && report.owedToOdoo > 0) return false;
    if (!c.uploads) return true;
    return _tills.every((t) => t.cloud != null) && report.missingUploads == 0;
  }

  /// One pass of what a real till does when the line comes back: pair the tills
  /// that never could, send every close Odoo did not book under its own key, and
  /// hand the reports site whatever it is still missing.
  Future<void> retry() async {
    if (_retrying || _closed || settled) return;
    _retrying = true;
    waitingSince ??= DateTime.now();
    try {
      retries++;
      await Future.wait([for (final t in _tills) t.retry(report.config)]);
      await _lan?.settled();
      if (_closed) return;
      _check(report, _tills);
      if (settled) caughtUpAt = DateTime.now();
    } finally {
      _retrying = false;
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    for (final t in _tills) {
      t.close();
    }
  }
}

/// Rebuilds the run's problems from where the tills stand now, so a retry that
/// got through takes its problems off the list.
void _check(MultiTillReport report, List<_VirtualTill> tills) {
  final problems = report.problems..clear();
  final c = report.config;
  for (final t in tills) {
    if (c.uploads && t.cloud == null) {
      problems.add('${t.name} could not pair with the reports site: ${t.pairProblem ?? 'not tried'}');
    }
  }
  for (final s in report.sessions) {
    if (s.odooRef == null && s.odooProblem != null) problems.add('POS ${s.till} session ${s.session} did not reach Odoo: ${s.odooProblem}');
  }
  final all = report.rung.length;
  for (final t in tills) {
    final held = t.paidCount();
    report.replicated[t.index] = held - t.paidCount(own: true);
    if (held != all) {
      problems.add('${t.name} holds $held of the $all sales: the LAN did not deliver them all.');
    }
  }
  if (!c.uploads) return;
  for (final t in tills) {
    if (t.cloud != null && t.cloudProblem != null) {
      problems.add('${t.name} could not reach the reports site: ${t.cloudProblem}');
    }
  }
  if (report.duplicateUploads > 0) {
    problems.add('${report.duplicateUploads} sales were sent by more than one till.');
  }
  if (report.uploadedByStranger > 0) {
    problems.add('${report.uploadedByStranger} sales were sent by a till that did not ring them.');
  }
  final strangers = report.uploadedOrders.keys.where((u) => !report.rung.containsKey(u)).length;
  if (strangers > 0) problems.add('$strangers uploads were not sales of this run.');
  if (report.missingUploads > 0) {
    problems.add('${report.missingUploads} sales have not reached the reports site.');
  }
}

/// Runs several tills side by side the way a shop with that many points of sale
/// works: each on a database of its own, sharing sales over a LAN, every cashier
/// ringing real menu items, every session closed into Odoo and every sale sent to
/// the reports site by the till that took it.
///
/// The tills live in memory, so the live till is never touched, and they stay
/// up after the run for as long as its [MultiTillRun] is open: cut the network,
/// run, bring it back, and the run shows whether every till catches up. Their
/// sales are not lab orders: they are booked in Odoo and shown on the reports
/// site like any other, which is the point of the run.
class MultiTillRunner {
  MultiTillRunner({required this.deps, this.pace = const Duration(milliseconds: 25)});

  final MultiTillDeps deps;
  final Duration pace;

  /// A run whose tills are let go as soon as it ends.
  Future<MultiTillReport> run(MultiTillConfig config, {MultiTillProgress? onProgress}) async {
    final run = await start(config, onProgress: onProgress);
    run.close();
    return run.report;
  }

  /// A run whose tills stay up until the caller closes it, so it can retry.
  Future<MultiTillRun> start(MultiTillConfig config, {MultiTillProgress? onProgress}) async {
    final report = MultiTillReport(config: config, started: DateTime.now());
    final menu = deps.catalogue
        .products(limit: 1000)
        .where((p) => p.price > 0 && !p.soldByWeight)
        .toList();
    if (menu.isEmpty) {
      report.problems.add('The menu on this till has nothing to sell.');
      report.finished = DateTime.now();
      return MultiTillRun._(report, const [], null);
    }
    final snapshot = deps.catalogue.exportLanSnapshot();
    final numbers = _NumberDesk();
    final lan = _VirtualLan();
    final tills = [
      for (var i = 1; i <= config.tills; i++)
        _VirtualTill(
          index: i,
          deviceId: 'stress-pos-$i',
          snapshot: snapshot,
          deps: deps,
          lan: lan,
          numbers: numbers,
          report: report,
        ),
    ];
    final steps = config.sessions * config.tills + (config.uploads ? config.tills : 0);
    var done = 0;
    final run = MultiTillRun._(report, tills, lan);
    try {
      if (config.uploads) {
        for (final t in tills) {
          onProgress?.call('Pairing ${t.name}', done, steps);
          await t.tryPair(config);
          done++;
        }
      }
      for (var s = 1; s <= config.sessions; s++) {
        onProgress?.call('Session $s of ${config.sessions}', done, steps);
        await Future.wait([
          for (final t in tills)
            t
                .session(s, config, menu, config.pause > Duration.zero ? config.pause : pace)
                .then((r) => report.sessions.add(r))
                .whenComplete(() => onProgress?.call('Session $s of ${config.sessions}', ++done, steps)),
        ]);
      }
      await lan.settled();
      _check(report, tills);
    } catch (_) {
      run.close();
      rethrow;
    }
    report.sessions.sort((a, b) =>
        a.session != b.session ? a.session.compareTo(b.session) : a.till.compareTo(b.till));
    report.finished = DateTime.now();
    return run;
  }
}

/// The primary's order numbers: one counter for the whole shop.
class _NumberDesk {
  int _next = 0;
  String take() => '${++_next}';
}

/// The shop network: what one till publishes lands on every other till, through
/// the same applier and the same wire format the real fabric uses.
class _VirtualLan {
  final List<_VirtualTill> _tills = [];
  final List<Future<void>> _inFlight = [];

  void join(_VirtualTill till) => _tills.add(till);

  void publish(_VirtualTill from, LanEventKind kind, String uuid, Map<String, dynamic> payload) {
    final wire = jsonEncode(LanEvent(
      kind: kind,
      originDeviceId: from.deviceId,
      seq: ++from.seq,
      recordUuid: uuid,
      payload: payload,
      at: DateTime.now().toUtc(),
    ).toMap());
    for (final to in _tills) {
      if (identical(to, from)) continue;
      _inFlight.add(Future(() {
        if (to.closed) return;
        to.applier.apply(LanEvent.fromMap((jsonDecode(wire) as Map).cast<String, dynamic>()));
      }));
    }
  }

  Future<void> settled() async {
    while (_inFlight.isNotEmpty) {
      final batch = List.of(_inFlight);
      _inFlight.clear();
      await Future.wait(batch);
    }
  }
}

class _VirtualTill {
  _VirtualTill({
    required this.index,
    required this.deviceId,
    required Map<String, dynamic> snapshot,
    required this.deps,
    required this.lan,
    required this.numbers,
    required this.report,
  }) : db = Db.open(':memory:') {
    catalogue = CatalogueStore(db)..applyLanSnapshot(snapshot);
    settings = SettingsStore(db);
    orders = OrderStore(
      db,
      ownDeviceId: deviceId,
      publish: (kind, uuid, payload) => lan.publish(this, kind, uuid, payload),
    );
    shifts = ShiftStore(db);
    outboxStore = SqliteOutboxStore(db);
    outbox = Outbox(store: outboxStore, senders: {});
    audit = AuditLog(db);
    applier = LanApplier(
      deviceId: deviceId,
      orders: orders,
      tables: TableStore(db),
      settings: settings,
      reservations: ReservationStore(db),
      assignments: TableAssignmentStore(db),
      log: LanEventLog(db, deviceId: deviceId),
      shifts: shifts,
    );
    final endpoint = deps.odooEndpoint;
    if (endpoint != null && endpoint.isComplete) {
      odoo = OdooWiring(outbox: Outbox(store: outboxStore, senders: {}), post: deps.odooPost)
        ..configure(endpoint);
      batch = BatchPush(
        outboxStore: outboxStore,
        send: odoo!.pushPayload,
        enabled: () => true,
        batchUuid: () => shifts.latestShift()?.uuid,
        partnerId: deps.sessionPartnerId,
        partnerName: deps.sessionPartnerName,
        onOrderBooked: (uuid, [id, name]) => orders.markSynced(uuid, id),
      );
    }
    lan.join(this);
  }

  final int index;
  final String deviceId;
  final MultiTillDeps deps;
  final _VirtualLan lan;
  final _NumberDesk numbers;
  final MultiTillReport report;
  final Db db;
  late final CatalogueStore catalogue;
  late final SettingsStore settings;
  late final OrderStore orders;
  late final ShiftStore shifts;
  late final SqliteOutboxStore outboxStore;
  late final Outbox outbox;
  late final AuditLog audit;
  late final LanApplier applier;
  OdooWiring? odoo;
  BatchPush? batch;
  CloudSyncService? cloud;
  int seq = 0;
  bool closed = false;

  /// Sale records this till has handed the reports server so far.
  int sentOrders = 0;

  String get name => 'POS $index';

  /// Paid sales on this till's database: all of them, or only the ones it rang.
  int paidCount({bool own = false}) => db.raw.select(
        "SELECT COUNT(*) AS c FROM orders WHERE state IN ('paid', 'synced')"
        '${own ? ' AND device_id = ?' : ''}',
        [if (own) deviceId],
      ).first['c'] as int;

  /// Why pairing failed last time, and why the last upload did.
  String? pairProblem;
  String? cloudProblem;

  /// Pairs with the run's branch, noting why when it cannot.
  Future<void> tryPair(MultiTillConfig config) async {
    try {
      await pair(config.cloudUrl!.trim(), config.pairCode!.trim());
      pairProblem = null;
    } catch (e) {
      pairProblem = '$e';
    }
  }

  /// What a real till does when the line comes back: pair if it never could,
  /// send each close Odoo did not book under that close's own key, and upload
  /// whatever the reports site has not had yet.
  Future<void> retry(MultiTillConfig config) async {
    if (closed) return;
    if (config.uploads && cloud == null) await tryPair(config);
    for (final s in report.sessions.where((s) => s.till == index && s.owesOdoo)) {
      if (closed) return;
      await pushToOdoo(s);
    }
    if (closed) return;
    await upload();
  }

  Future<void> pair(String url, String code) async {
    final client = CloudClient(url, client: deps.cloudHttp);
    final paired = await client.pair(
      pairCode: code,
      deviceId: deviceId,
      deviceName: 'Stress $name',
      appVersion: deps.appVersion,
    );
    cloud = CloudSyncService(
      db: db,
      state: MemoryCloudSyncStateStore(),
      deviceId: deviceId,
      connection: () async => (url: url, token: paired.token),
      lookups: deps.lookups,
      clientFor: (base) => _CountingClient(base, this),
      audit: audit,
    );
  }

  Future<MultiTillSession> session(
      int number, MultiTillConfig config, List<Product> menu, Duration pace) async {
    final result = MultiTillSession(till: index, session: number);
    final watch = Stopwatch()..start();
    final random = Random(index * 1009 + number * 31);
    final staff = deps.staff.isEmpty ? const ['stress'] : deps.staff;
    final methods = catalogue.paymentMethods();
    final cash = methods.where((m) => m.isCash).firstOrNull ??
        methods.firstOrNull ??
        const PaymentMethod(id: 1, name: 'Cash', isCash: true);
    // A bank tender, never the pay-later one: that is the only tender with no
    // journal behind it, and a stress run must not leave customers owing.
    final card = methods.where((m) => !m.isCash && m.journalType == 'bank').firstOrNull ??
        methods.where((m) => !m.isCash && m.journalId != null).firstOrNull;

    shifts.openShift(openingFloat: 500, cashierId: staff[(index - 1) % staff.length]);
    final cashiers = config.cashiers.clamp(1, 8);
    var left = config.ordersPerSession;
    Future<void> work(int k) async {
      final cashierId = staff[(index + k) % staff.length];
      final s = PosSession(
        catalogue: catalogue,
        orders: orders,
        outbox: outbox,
        audit: audit,
        deviceId: deviceId,
        cashierId: cashierId,
        taxRateFor: deps.taxRateFor,
        serviceChargeFor: deps.serviceChargeFor,
        nextOrderNo: numbers.take,
        shiftOpenedAt: () => shifts.currentOpenShift()?.openedAt,
      );
      while (left > 0) {
        left--;
        s.setOrderType(random.nextInt(3) == 0 ? OrderType.dineIn : OrderType.takeaway);
        for (var i = 0, n = 1 + random.nextInt(4); i < n; i++) {
          s.addProduct(menu[random.nextInt(menu.length)], qty: (1 + random.nextInt(2)).toDouble());
        }
        final due = s.current.total;
        final byCard = card != null && random.nextInt(10) < 3;
        final paid = s.pay(
          payments: [OrderPayment(methodId: byCard ? card.id : cash.id, amount: due)],
          cashReceived: byCard ? null : due,
        );
        if (paid != null) {
          report.rung[paid.uuid] = deviceId;
          result
            ..orders += 1
            ..total += paid.total;
        }
        await Future<void>.delayed(pace);
      }
    }

    await Future.wait([for (var k = 0; k < cashiers; k++) work(k)]);
    final closedShift = shifts.closeOpenQuietly(
        cashMethodIds: {for (final m in methods) if (m.isCash) m.id});

    if (config.sendToOdoo && closedShift != null) {
      if (batch == null) {
        result.odooProblem = 'no Odoo server on this till';
      } else {
        result.closed = closedShift;
        await pushToOdoo(result);
      }
    }

    final before = sentOrders;
    if (await upload() == false) result.cloudProblem = cloudProblem;
    result.uploaded = sentOrders - before;
    result.took = watch.elapsed;
    return result;
  }

  /// Sends one closed session to Odoo as one sale order, keyed on its shift, so
  /// a second attempt after a lost answer books nothing twice.
  Future<void> pushToOdoo(MultiTillSession result) async {
    final push = batch;
    final shift = result.closed;
    if (push == null || shift == null) return;
    result.odooTries++;
    final mine = orders.awaitingSyncInShift(shift);
    if (mine.isEmpty && result.odooRef == null && result.odooTries > 1) {
      result.odooProblem = 'nothing left to send, yet Odoo never named the order';
      return;
    }
    for (final o in mine) {
      await outbox.enqueue('order.push', o.uuid, o.toServerPayload());
    }
    try {
      final ok = await push.run(onlyUuids: {for (final o in mine) o.uuid}, batchKey: shift.uuid);
      if (ok) {
        result
          ..odooRef = push.lastAck?['name']?.toString() ?? '#${push.lastAck?['id'] ?? '?'}'
          ..odooProblem = null;
      } else {
        result.odooProblem = push.lastSkipReason ?? 'not booked';
      }
    } catch (e) {
      result.odooProblem = '$e';
    }
  }

  /// Hands the reports site everything it has not had. Null when unpaired.
  Future<bool?> upload() async {
    final sync = cloud;
    if (sync == null) return null;
    await lan.settled();
    final outcome = await sync.runNow();
    final ok = outcome != CloudSyncOutcome.failed;
    cloudProblem = ok ? null : (sync.status().lastError ?? 'failed');
    return ok;
  }

  void close() {
    closed = true;
    db.close();
  }
}

/// The reports server's client, noting which till handed it which sale.
class _CountingClient extends CloudClient {
  _CountingClient(super.baseUrl, this.till) : super(client: till.deps.cloudHttp);

  final _VirtualTill till;

  @override
  Future<int> sync(String token, List<Map<String, Object?>> records) async {
    final stored = await super.sync(token, records);
    for (final r in records) {
      if (r['kind'] != 'order') continue;
      till.sentOrders++;
      till.report.uploadedOrders.putIfAbsent('${r['key']}', () => {}).add(till.deviceId);
    }
    return stored;
  }
}
