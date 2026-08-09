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
    this.catalogueMaxAge = const Duration(hours: 6),
    DateTime Function()? now,
  })  : _outbox = outbox,
        _catalogue = catalogue,
        _puller = puller,
        _outboxStore = outboxStore,
        _audit = audit,
        _now = now ?? DateTime.now;

  final Outbox _outbox;
  final CatalogueStore _catalogue;
  final OdooPuller? _puller;
  final SqliteOutboxStore _outboxStore;
  final AuditLog? _audit;
  final String deviceId;
  final String appVersion;
  final Duration catalogueMaxAge;
  final DateTime Function() _now;

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

  void start({Duration every = const Duration(seconds: 30)}) {
    _timer?.cancel();
    _timer = Timer.periodic(every, (_) => tick());
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

  /// One pass. Safe to call at any time; failures are recorded, never thrown, so a
  /// timer tick can never take the app down.
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
    } catch (e) {
      lastError = e.toString();
      _state = SyncState.offline;
    }
  }
}
