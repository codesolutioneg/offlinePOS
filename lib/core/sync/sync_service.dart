import 'dart:async';

import '../db/catalogue_store.dart';
import 'odoo_puller.dart';
import 'outbox.dart';

enum SyncState { idle, working, offline }

/// Drives the round trip on a timer: drain the outbox, then refresh the catalogue.
///
/// Nothing here is ever awaited by a selling screen. The till's job is to take money;
/// this runs behind it and catches up when there is a line.
class SyncService {
  SyncService({
    required Outbox outbox,
    required CatalogueStore catalogue,
    OdooPuller? puller,
    this.catalogueMaxAge = const Duration(hours: 6),
    DateTime Function()? now,
  })  : _outbox = outbox,
        _catalogue = catalogue,
        _puller = puller,
        _now = now ?? DateTime.now;

  final Outbox _outbox;
  final CatalogueStore _catalogue;
  final OdooPuller? _puller;
  final Duration catalogueMaxAge;
  final DateTime Function() _now;

  Timer? _timer;
  SyncState _state = SyncState.idle;
  String? lastError;
  int sentThisRun = 0;

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

  /// One pass. Safe to call at any time; failures are recorded, never thrown, so a
  /// timer tick can never take the app down.
  Future<void> tick() async {
    if (_state == SyncState.working) return;
    _state = SyncState.working;
    try {
      sentThisRun = await _outbox.drain();
      if (_puller != null && catalogueNeedsRefresh) {
        final pull = await _puller.pull();
        // Never overwrite a working catalogue with an empty pull.
        if (pull.isUsable) {
          _catalogue.replaceAll(
            categories: pull.categories,
            products: pull.products,
            groups: pull.groups,
            productGroupIds: pull.productGroupIds,
            refreshedAt: _now().toUtc(),
          );
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
