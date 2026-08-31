import 'dart:async';

import 'package:flutter/foundation.dart';

import '../audit/audit_log.dart';
import '../../domain/catalogue.dart';
import '../db/catalogue_store.dart';
import '../db/sqlite_outbox_store.dart';
import 'device_status.dart';
import 'odoo_puller.dart';
import 'outbox.dart';

enum SyncState { idle, working, offline }

/// Where the armed state of a failed batch push survives a restart.
///
/// It has to survive one. A close that failed at midnight arms a retry in memory,
/// and a till switched off for the night comes back with an empty head and a day's
/// takings still queued, waiting on somebody remembering to tap Sync now. That is
/// the failure the retry exists to remove, so the arming is written down.
///
/// Only the arming is persisted, never "there are sales queued". The difference is
/// the whole product rule: sales sit on the till all through service and go as one
/// batch at close, so a till that re-armed on a pending count alone would drain
/// mid-shift and push them one at a time.
abstract interface class RetryArmingStore {
  /// The push still owed to the server, or null when nothing is armed.
  ({DateTime armedAt, String reason})? read();

  void write(DateTime armedAt, String reason);

  void clear();

  /// Why the last retry stopped, kept separately and for the same reason the
  /// arming is kept: a till that gave up has to still say so tomorrow. Without
  /// this the arming is cleared on the boot that finds it expired, and every boot
  /// after that reports nothing at all while the takings are still queued, which
  /// is the silence this was built to end.
  String? readStopped();

  void writeStopped(String reason);
}

/// What one catalogue refresh actually did, so a manual "Refresh menu" can say
/// something true instead of a hopeful "done".
enum RefreshOutcome {
  /// New prices are on the till.
  updated,

  /// Nothing to do: the catalogue is young enough, the pull came back empty, or
  /// another pass is already running.
  unchanged,

  /// The server could not be reached. The old prices are still there and selling
  /// carries on.
  unreachable,

  /// The server answered with something that did not work.
  failed,
}

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
    this.reconcile,
    this.mergeBatch,
    RetryArmingStore? arming,
    this.catalogueMaxAge = const Duration(minutes: 30),
    this.retryWindow = const Duration(hours: 12),
    this.retryInterval = const Duration(minutes: 5),
    DateTime Function()? now,
  })  : _outbox = outbox,
        _catalogue = catalogue,
        _puller = puller,
        _outboxStore = outboxStore,
        _audit = audit,
        _probe = probe,
        _arming = arming,
        _now = now ?? DateTime.now;

  final Outbox _outbox;
  final CatalogueStore _catalogue;
  final OdooPuller? _puller;
  final SqliteOutboxStore _outboxStore;
  final AuditLog? _audit;

  /// Null on a build with nowhere to write it, in which case the arming lives only
  /// as long as the process does and [restoreArming] has nothing to find.
  final RetryArmingStore? _arming;

  /// A cheap reachability check against the configured server. Injected so this
  /// stays testable without a socket. Null on a build with no way to probe, in
  /// which case a successful push is the only signal of being online.
  final Future<bool> Function()? _probe;

  final String deviceId;
  final String appVersion;

  /// How old the menu may get before the background loop pulls it again.
  ///
  /// Half an hour, because the thing the shop actually complains about is a price
  /// changed in Odoo that the till is still selling at yesterday's number. Sign-in
  /// and the manual refresh both force a pull, so this only sets the worst case for
  /// a till nobody touches. The pull is read-only and stays that way: shortening it
  /// changes how often prices come down, never how often orders go up.
  final Duration catalogueMaxAge;

  /// How long after a batch push failed the timer keeps trying to finish it. Wide
  /// enough to sit through an overnight outage and deliver before the shop opens,
  /// bounded so a till that has been pointed at a dead server for days stops
  /// pretending a retry is still coming and says it gave up instead.
  final Duration retryWindow;

  /// Floor between two retry attempts. The loop ticks every 20 s, and a drain
  /// against a dead server costs a socket timeout plus a failed attempt on every
  /// queued entry, so the retry is paced far below the loop.
  final Duration retryInterval;

  final DateTime Function() _now;

  /// Re-queues any paid order that is not on the wire yet. Injected so this class
  /// stays free of order/domain types. It closes the window where a paid sale's
  /// original enqueue was lost (app killed between saving the sale and queuing it),
  /// which would otherwise leave the sale on the till but never book it. Safe to
  /// call before every batch: the outbox is unique on (kind, uuid) and the server
  /// dedupes on uuid, so re-queuing an already-queued or already-booked order is a
  /// no-op rather than a double sale.
  final Future<void> Function()? reconcile;

  /// Sends the queued sales as one merged sales order and returns true when it
  /// did, leaving nothing for the drain behind it. Null on a build that cannot
  /// merge, and it answers false whenever the shop has not asked for merging or
  /// the batch is not one that can be merged safely, which is the normal case.
  ///
  /// Injected rather than built here for the same reason [reconcile] is: this
  /// class stays free of order and settings types. It runs on a batch push (a
  /// shift close, a manual sync) and on the retry that finishes one, never on the
  /// read-only timer pass.
  final Future<bool> Function()? mergeBatch;

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

  DateTime? _retryArmedAt;
  String? _retryArmedReason;
  DateTime? _lastRetryAt;
  int _retryAttempts = 0;
  String? _retryStoppedReason;

  /// True while a batch push that did not deliver everything is waiting for the
  /// timer to finish it. See [retryArmedFlush].
  bool get retryArmed => _retryArmedAt != null;

  /// When the failed push happened. The retry window runs from here and is never
  /// extended by a later attempt, so a dead server cannot be retried forever.
  DateTime? get retryArmedAt => _retryArmedAt;

  /// What went wrong on the push that armed the retry, or why it was given up on,
  /// in the words support gets read back to them.
  String? get retryArmedReason => _retryArmedReason;
  String? get retryStoppedReason => _retryStoppedReason;

  /// Background attempts made since arming, and when the last one ran. Together
  /// they are the difference between "still trying" and "quietly doing nothing".
  int get retryAttempts => _retryAttempts;
  DateTime? get lastRetryAt => _lastRetryAt;

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
  ///
  /// The single exception is a batch push that already ran and did not get
  /// everything out: [retryArmedFlush] finishes that one batch. The loop still
  /// never starts a push of its own.
  void start({Duration every = const Duration(seconds: 20)}) {
    _timer?.cancel();
    // Before the first tick, so the pass below already knows a close is owed.
    restoreArming();
    _timer = Timer.periodic(every, (_) => periodicPass());
    // Probe once at startup so the badge is right before the first tick.
    unawaited(periodicPass());
  }

  /// One turn of the periodic loop: the read-only [refresh], then, only while a
  /// failed batch push is armed, one bounded attempt to finish it. Kept as its own
  /// method so the two stay separate: [refresh] is what the loop does every time
  /// and it must remain incapable of pushing an order.
  Future<void> periodicPass() async {
    await refresh();
    await retryArmedFlush();
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

  /// The tenders to write with a fresh catalogue.
  ///
  /// A refresh replaces everything at once, which is right for the menu and wrong
  /// for the payment methods: the tender read is optional and a server that refuses
  /// it (the integration user missing the Point of Sale group is the usual reason)
  /// would otherwise wipe the methods the till was already selling with, leaving
  /// every sale to book as cash. So an unanswered question keeps the old answer.
  List<PaymentMethod> _tendersFrom(CataloguePull pull) =>
      pull.paymentMethodsRead ? pull.paymentMethods : _catalogue.paymentMethods();

  /// A read-only pass: check reachability and refresh the catalogue if it is stale.
  /// Never drains the outbox, so it never pushes an order. This is what the timer
  /// runs, keeping the badge and prices current without booking anything.
  ///
  /// [force] skips the age gate only. A price changed in Odoo at 09:00 would
  /// otherwise sit unseen until the catalogue aged past [catalogueMaxAge]; a cashier
  /// signing in, or asking for the menu by hand, gets the prices now. Nothing else
  /// changes: forced or not, this pass still cannot send an order.
  Future<RefreshOutcome> refresh({bool force = false}) async {
    if (_state == SyncState.working) return RefreshOutcome.unchanged;
    if (_probe != null) {
      online.value = await _probe();
      // No point pulling if nothing is reachable; the badge is already set.
      if (!online.value) return RefreshOutcome.unreachable;
    }
    if (_puller == null || (!force && !catalogueNeedsRefresh)) {
      if (_probe == null) online.value = true;
      return RefreshOutcome.unchanged;
    }
    try {
      final pull = await _puller.pull();
      if (pull.isUsable) {
        _catalogue.replaceAll(
          categories: pull.categories,
          products: pull.products,
          groups: pull.groups,
          productGroupIds: pull.productGroupIds,
          paymentMethods: _tendersFrom(pull),
          customers: pull.customers,
          productImages: pull.productImages,
          refreshedAt: _now().toUtc(),
        );
        catalogueRevision.value++;
      }
      lastError = null;
      // A successful read proves reachability even when no probe was injected.
      online.value = true;
      return pull.isUsable ? RefreshOutcome.updated : RefreshOutcome.unchanged;
    } catch (e) {
      lastError = e.toString();
      online.value = false;
      return RefreshOutcome.failed;
    }
  }

  /// One full push: hand the audit trail and heartbeat to the outbox, drain it, and
  /// refresh the catalogue. This is the batch that runs at shift close and on a
  /// manual sync, never on the timer. Failures are recorded, never thrown.
  Future<void> tick() async {
    if (_state == SyncState.working) return;
    _state = SyncState.working;
    try {
      // Sweep any paid order that never made it onto the wire back into the outbox
      // before draining, so a sale can never be stranded on the till.
      await reconcilePending();
      // Hand the audit trail to the outbox before draining. With one shared Odoo
      // login every order there says the same user rang it, so this log is the only
      // record of who actually did what and it has to reach the server too.
      await _queueAudit();
      await _queueHeartbeat();
      // Before the ordinary drain, because merging is about how these same sales
      // reach the server, not about sending them twice. When it delivers, the
      // sales are already marked and the drain below only carries the audit trail
      // and the heartbeat.
      await _mergeBatchIfAsked();
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
            paymentMethods: _tendersFrom(pull),
            customers: pull.customers,
            productImages: pull.productImages,
            refreshedAt: _now().toUtc(),
          );
          catalogueRevision.value++;
        }
      }
      lastError = null;
      _state = SyncState.idle;
      // A completed push is the strongest proof of being online.
      online.value = true;
      _armRetryIfIncomplete(null);
    } catch (e) {
      lastError = e.toString();
      _state = SyncState.offline;
      online.value = false;
      _armRetryIfIncomplete(e.toString());
    }
  }

  /// Decide, at the end of a batch push, whether the timer has to come back and
  /// finish the job. A failed shift close used to sit there until somebody noticed
  /// the next morning and tapped Sync now; the day's takings are not something to
  /// leave waiting on a person remembering.
  ///
  /// Only sales arm a retry. A push that failed on the catalogue read with nothing
  /// owed to the server has nothing for a retry to deliver, and the periodic
  /// refresh already re-reads the catalogue on its own.
  void _armRetryIfIncomplete(String? failure) {
    if (pendingSales == 0) {
      if (_retryArmedAt != null) _disarmRetry('nothing left to send');
      return;
    }
    final reason = failure ?? '$pendingSales sale(s) still queued after the push';
    if (_retryArmedAt != null) {
      // Keep the original arming time: the window is meant to expire, and a fresh
      // failure every few minutes would push it out forever.
      _retryArmedReason = reason;
      _arming?.write(_retryArmedAt!, reason);
      return;
    }
    _retryArmedAt = _now().toUtc();
    _retryArmedReason = reason;
    _retryAttempts = 0;
    _lastRetryAt = null;
    _retryStoppedReason = null;
    _arming?.write(_retryArmedAt!, reason);
  }

  void _disarmRetry(String why) {
    _retryArmedAt = null;
    _retryStoppedReason = why;
    // Cleared on the way down as well as on delivery. A window that closed is
    // finished with, and leaving the record would re-arm it on the next boot and
    // start the same dead push again every morning. The reason outlives the
    // arming, so a till that gave up is still able to say so.
    _arming?.clear();
    _arming?.writeStopped(why);
  }

  /// Pick up a batch push that was still owed when the process last stopped.
  ///
  /// Called from [start], so a till rebooted overnight after a failed close carries
  /// on trying instead of waiting for a person. The original arming time comes back
  /// with it, which is what makes the window mean anything: twelve hours from the
  /// close that failed, not twelve more from every restart.
  void restoreArming() {
    if (_retryArmedAt != null) return;
    final saved = _arming?.read();
    if (saved == null) {
      // Nothing owed. If the last thing that happened was a give-up, that is
      // still the truth about this till and it survives the restart, because the
      // arming it was attached to does not.
      _retryStoppedReason ??= _arming?.readStopped();
      return;
    }
    if (pendingSales == 0) {
      // Delivered by some other route before the record was cleared. Nothing is
      // owed, so the record goes rather than arming a retry with nothing to send.
      _arming?.clear();
      return;
    }
    if (_now().toUtc().difference(saved.armedAt) >= retryWindow) {
      // The window closed while the till was off. Say so, the way a live give-up
      // says it, instead of silently starting a fresh twelve hours. Written down
      // as well as remembered: the boot after this one has no arming left to
      // find, and a till with a day's takings queued must not go quiet.
      _disarmRetry('gave up with $pendingSales sale(s) still queued when the '
          'retry window closed');
      return;
    }
    _retryArmedAt = saved.armedAt;
    _retryArmedReason = saved.reason;
    _retryAttempts = 0;
    _lastRetryAt = null;
    _retryStoppedReason = null;
  }

  /// One bounded catch-up attempt for a batch push that did not deliver.
  ///
  /// Called by the loop next to [refresh], never from inside it: orders leave this
  /// till as one batch because the shop has a single shared Odoo login, so the
  /// read-only pass has to stay read-only. This is the same batch finishing late,
  /// which is why it only ever runs when a real push already failed.
  ///
  /// Does nothing unless armed, gives up when [retryWindow] has passed, and paces
  /// itself to one attempt per [retryInterval] so a dead server is not hammered
  /// every 20 s.
  Future<void> retryArmedFlush() async {
    final armedAt = _retryArmedAt;
    if (armedAt == null) return;
    final now = _now().toUtc();
    if (pendingSales == 0) {
      // Something else got there first: a manual sync, or an earlier attempt.
      _disarmRetry('nothing left to send');
      return;
    }
    if (now.difference(armedAt) >= retryWindow) {
      // Recorded rather than dropped, so diagnostics can say it gave up instead of
      // showing a till that looks like it is still trying.
      _disarmRetry('gave up with $pendingSales sale(s) still queued when the '
          'retry window closed');
      return;
    }
    final last = _lastRetryAt;
    if (last != null && now.difference(last) < retryInterval) return;
    // A push is already running (a manual sync, a shift close): that one owns the
    // queue and this attempt would only fight it for the same entries.
    if (_state == SyncState.working) return;
    // [refresh] has just run the probe on this same pass, so an offline till costs
    // nothing here: no socket, no burnt attempt on every queued entry.
    if (!online.value) return;

    _lastRetryAt = now;
    _retryAttempts++;
    _state = SyncState.working;
    try {
      // Same sweep the batch push does, in case the sale that was lost from the
      // outbox is the reason the close came up short.
      await reconcilePending();
      // A close that merged and then failed has to be finished the same way. Left
      // to the drain, the same sales would go out one at a time under their own
      // uuids, and a batch the server had already committed but never
      // acknowledged would then be booked a second time as individual sales.
      await _mergeBatchIfAsked();
      sentThisRun = await _outbox.drain(maxBatches: _retryMaxBatches);
      if (sentThisRun > 0) {
        _outboxStore.pruneSent();
        // Something was accepted, which is the only proof of a line worth acting
        // on. Nothing sent proves nothing, so the badge is left to the probe.
        online.value = true;
      }
      // The drain swallows a sender failure, so what is left in the queue is the
      // honest answer about whether the books are up to date.
      final left = pendingSales;
      _state = left == 0 || sentThisRun > 0 ? SyncState.idle : SyncState.offline;
      if (left == 0) {
        lastError = null;
        _disarmRetry('delivered on retry $_retryAttempts');
      }
    } catch (e) {
      lastError = e.toString();
      _state = SyncState.offline;
      online.value = false;
    }
  }

  Future<void> _mergeBatchIfAsked() async {
    final merge = mergeBatch;
    if (merge != null) await merge();
  }

  /// Re-queue paid orders that are not yet on the wire. Exposed so a caller can run
  /// it before reading [pendingSales] (e.g. the shift-close message), otherwise a
  /// sale lost from the outbox would read as "nothing to sync".
  Future<void> reconcilePending() async {
    final r = reconcile;
    if (r != null) await r();
  }

  /// Alias read at the call sites that push a batch (shift close, manual sync), so
  /// their intent reads as "flush what is queued" rather than an anonymous tick.
  Future<void> flush() => tick();

  /// Batches one retry attempt will take. A long backlog is worked through over
  /// several attempts rather than one long run behind a cashier who is mid-sale.
  static const int _retryMaxBatches = 10;
}
