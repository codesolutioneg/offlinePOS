import 'dart:async';

import 'package:flutter/foundation.dart';

import '../audit/audit_log.dart';
import '../db/catalogue_store.dart';
import '../db/sqlite_outbox_store.dart';
import 'device_status.dart';
import 'odoo_puller.dart';
import 'outbox.dart';

enum SyncState { idle, working, offline }

/// Drives the round trip on a timer: drain the outbox, then refresh the catalogue.
///
/// Nothing here is ever awaited by a selling screen. The till's job is to take money;
/// this runs behind it and catches up when there is a line.
class SyncService {
  /// [outboxStore] is required rather than optional because every number this
  /// class reports about the till comes out of it. Passing null used to compile
  /// fine and made [status] answer zero to everything, which is worse than having
  /// no diagnostics at all: it sends support looking somewhere else while a week
  /// of takings sits on the device.
  SyncService({
    required Outbox outbox,
    required CatalogueStore catalogue,
    required SqliteOutboxStore outboxStore,
    required this.deviceId,
    required this.appVersion,
    OdooPuller? puller,
    AuditLog? audit,
    Future<bool> Function()? probe,
    this.catalogueMaxAge = const Duration(hours: 6),
    DateTime Function()? now,
  })  : _outbox = outbox,
        _catalogue = catalogue,
        _puller = puller,
        _outboxStore = outboxStore,
        _audit = audit,
        _probe = probe,
        _now = now ?? DateTime.now;

  final Outbox _outbox;
  final CatalogueStore _catalogue;
  final OdooPuller? _puller;
  final SqliteOutboxStore _outboxStore;
  final AuditLog? _audit;

  /// A cheap reachability check against the configured server. Injected so this
  /// stays testable without a socket. Null on a build with no way to probe, in
  /// which case a successful push is the only signal of being online.
  final Future<bool> Function()? _probe;

  final String deviceId;
  final String appVersion;
  final Duration catalogueMaxAge;
  final DateTime Function() _now;

  /// Whether the server is currently reachable. Drives the online/offline badge on
  /// the sell screen. Starts false: a till has not proven it can reach anything
  /// until it has, and claiming "online" before the first successful probe would
  /// be a lie a cashier acts on.
  final ValueNotifier<bool> online = ValueNotifier<bool>(false);

  /// Sales still on the till, for anything that has to decide whether losing this
  /// device would lose money. The update gate is the caller that matters.
  int get pendingSales => _outboxStore.pendingSalesCount;

  /// True when something is registered that can actually deliver.
  ///
  /// A till with no destination is not offline, and calling it offline is the
  /// wrong thing to tell support. It has nowhere to be online to, which is a
  /// configuration answer rather than a network one.
  bool get hasDestination => _outbox.hasSenders;

  /// Kinds that were queued with nothing registered to send them. Non-empty means
  /// the till is accumulating work it can never deliver.
  Set<String> get undeliverableKinds => _outbox.unhandledKinds;

  /// Who is signed in, folded into the heartbeat so support can see it.
  String? cashierId;

  Timer? _timer;
  SyncState _state = SyncState.idle;
  String? lastError;
  int sentThisRun = 0;

  /// Ticks every time the catalogue is refreshed from the server, so a screen
  /// showing the menu can reload itself instead of the cashier having to leave
  /// and re-enter it after the first sync.
  final ValueNotifier<int> catalogueRevision = ValueNotifier<int>(0);

  SyncState get state => _state;

  /// True when the catalogue has never been pulled or is older than the limit. The
  /// UI uses this to warn, not to block.
  bool get catalogueNeedsRefresh {
    final age = _catalogue.stalenessAt(_now().toUtc());
    return age == null || age > catalogueMaxAge;
  }

  /// The periodic loop deliberately does NOT push orders. Orders are held on the
  /// till and sent as one batch when the shift is closed (or by a manual sync),
  /// because the shop runs on a single shared Odoo login and a per-order push is
  /// not how the books are meant to be written. The timer only keeps the
  /// online/offline badge honest and the catalogue fresh, both of which are reads.
  void start({Duration every = const Duration(seconds: 20)}) {
    _timer?.cancel();
    _timer = Timer.periodic(every, (_) => refresh());
    // Probe once at startup so the badge is right before the first tick.
    unawaited(refresh());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// A snapshot of this till, for the heartbeat and the diagnostics screen.
  DeviceStatus status() => DeviceStatus(
        deviceId: deviceId,
        appVersion: appVersion,
        at: _now().toUtc(),
        pending: _outboxStore.pendingCount,
        dead: _outboxStore.deadCount,
        unsyncedAudit: _audit?.unsyncedCount ?? 0,
        oldestPendingAge: _outboxStore.oldestPendingAge(_now().toUtc()),
        catalogueRefreshedAt: _catalogue.refreshedAt,
        lastError: lastError,
        cashierId: cashierId,
      );

  Future<void> _queueAudit() async {
    final audit = _audit;
    if (audit == null) return;
    final entries = audit.unsynced();
    if (entries.isEmpty) return;
    for (final e in entries) {
      final id = e['id'];
      await _outbox.enqueue('audit.push', 'audit-$id', {
        for (final k in e.keys) k: e[k],
      });
    }
    // The outbox is durable and owns delivery from here, so the audit rows are
    // handed over rather than queued twice.
    audit.markSynced(entries.map((e) => e['id'] as int));
  }

  Future<void> _queueHeartbeat() async {
    // Keyed on the device, and the outbox is unique on (kind, uuid), so a new
    // heartbeat replaces the previous one instead of thousands piling up during an
    // outage. Support wants the latest state, not a history of staleness.
    await _outbox.enqueue('device.status', deviceId, status().toMap());
  }

  /// A read-only pass: check reachability and refresh the catalogue if it is stale.
  /// Never drains the outbox, so it never pushes an order. This is what the timer
  /// runs, keeping the badge and prices current without booking anything.
  Future<void> refresh() async {
    if (_state == SyncState.working) return;
    if (_probe != null) {
      online.value = await _probe();
      // No point pulling if nothing is reachable; the badge is already set.
      if (!online.value) return;
    }
    if (_puller == null || !catalogueNeedsRefresh) {
      if (_probe == null) online.value = true;
      return;
    }
    try {
      final pull = await _puller.pull();
      if (pull.isUsable) {
        _catalogue.replaceAll(
          categories: pull.categories,
          products: pull.products,
          groups: pull.groups,
          productGroupIds: pull.productGroupIds,
          paymentMethods: pull.paymentMethods,
          customers: pull.customers,
          refreshedAt: _now().toUtc(),
        );
        catalogueRevision.value++;
      }
      lastError = null;
      // A successful read proves reachability even when no probe was injected.
      online.value = true;
    } catch (e) {
      lastError = e.toString();
      online.value = false;
    }
  }

  /// One full push: hand the audit trail and heartbeat to the outbox, drain it, and
  /// refresh the catalogue. This is the batch that runs at shift close and on a
  /// manual sync, never on the timer. Failures are recorded, never thrown.
  Future<void> tick() async {
    if (_state == SyncState.working) return;
    _state = SyncState.working;
    try {
      // Hand the audit trail to the outbox before draining. With one shared Odoo
      // login every order there says the same user rang it, so this log is the only
      // record of who actually did what and it has to reach the server too.
      await _queueAudit();
      await _queueHeartbeat();
      sentThisRun = await _outbox.drain();
      if (sentThisRun > 0) {
        // Acknowledged entries are kept a while so a duplicate push is still
        // recognisable, then cleared. Without this the table only ever grows.
        _outboxStore.pruneSent();
      }
      if (_puller != null && catalogueNeedsRefresh) {
        final pull = await _puller.pull();
        // Never overwrite a working catalogue with an empty pull.
        if (pull.isUsable) {
          _catalogue.replaceAll(
            categories: pull.categories,
            products: pull.products,
            groups: pull.groups,
            productGroupIds: pull.productGroupIds,
            paymentMethods: pull.paymentMethods,
            customers: pull.customers,
            refreshedAt: _now().toUtc(),
          );
          catalogueRevision.value++;
        }
      }
      lastError = null;
      _state = SyncState.idle;
      // A completed push is the strongest proof of being online.
      online.value = true;
    } catch (e) {
      lastError = e.toString();
      _state = SyncState.offline;
      online.value = false;
    }
  }

  /// Alias read at the call sites that push a batch (shift close, manual sync), so
  /// their intent reads as "flush what is queued" rather than an anonymous tick.
  Future<void> flush() => tick();
}
