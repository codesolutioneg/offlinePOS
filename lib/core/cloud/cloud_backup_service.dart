import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart';

import '../audit/audit_log.dart';
import '../db/database.dart';
import '../db/stress_purge.dart';
import '../export/db_backup.dart';
import 'backup_envelope.dart';
import 'cloud_backup_state.dart';
import 'cloud_client.dart';
import 'cloud_secrets.dart';
import 'recovery_key.dart';

/// The shop already backs up under a recovery key this till does not hold.
class RecoveryKeyNeeded implements Exception {
  const RecoveryKeyNeeded(this.shopName);
  final String shopName;
}

/// The recovery key typed in is not the one the shop's backups use.
class RecoveryKeyMismatch implements Exception {
  const RecoveryKeyMismatch();
}

/// How one attempt ended.
enum CloudBackupOutcome {
  uploaded,

  /// Nothing changed since the last upload.
  unchanged,

  /// No server or no pairing on this till.
  notConfigured,

  /// Another attempt is already running.
  busy,

  /// Stress Lab orders are on the till; they never leave it, backups included.
  stressOrders,

  /// The server could not be reached or refused. Tried again later.
  failed,
}

/// What the settings screen shows.
typedef CloudBackupStatus = ({
  bool configured,
  bool running,
  String? url,
  String? shopName,
  DateTime? lastSuccessAt,
  DateTime? lastTryAt,
  String? lastError,
});

/// Copies the whole till to the shop's backup server whenever there is a line.
///
/// Hourly, and at every shift close, the database is snapshotted, sealed under the
/// shop's recovery key (see [BackupEnvelope]) and uploaded. A till whose data has
/// not changed sends nothing. With the line down the attempt fails quietly and
/// the next tick tries again; selling never waits on any of it.
///
/// Nothing on the success path writes to the database: a write would make the
/// next snapshot differ, and an idle till would then upload every hour.
class CloudBackupService {
  CloudBackupService({
    required this.db,
    required this.state,
    required this.secrets,
    required this.deviceId,
    required this.appVersion,
    required String Function() deviceName,
    Future<String?> Function()? databaseKey,
    CloudClient Function(String baseUrl)? clientFor,
    Future<Directory> Function()? scratch,
    AuditLog? audit,
    DateTime Function()? now,
    this.every = const Duration(hours: 1),
    this.retryAfter = const Duration(minutes: 5),
    this.tick = const Duration(minutes: 1),
  })  : _deviceName = deviceName,
        _databaseKey = databaseKey ?? (() async => null),
        _clientFor = clientFor ?? CloudClient.new,
        _scratch = scratch ?? (() async => Directory.systemTemp),
        _audit = audit,
        _now = now ?? DateTime.now;

  final Db db;
  final CloudBackupStateStore state;
  final CloudSecrets secrets;
  final String deviceId;
  final String appVersion;
  final String Function() _deviceName;
  final Future<String?> Function() _databaseKey;
  final CloudClient Function(String baseUrl) _clientFor;
  final Future<Directory> Function() _scratch;
  final AuditLog? _audit;
  final DateTime Function() _now;

  /// How long after the last good backup the next routine one is due.
  final Duration every;

  /// How long after a failed attempt the next routine one may start.
  final Duration retryAfter;

  /// How often the timer wakes to ask whether a backup is due.
  final Duration tick;

  static const String tokenSecret = 'token';
  static const String recoveryKeySecret = 'recovery_key';

  Timer? _timer;
  Future<CloudBackupOutcome>? _running;
  String? _requested;
  String? _lastLogged;

  /// Bumped when an attempt starts or ends, so an open screen can redraw.
  final ValueNotifier<int> changes = ValueNotifier(0);

  void start() {
    _timer?.cancel();
    _timer = Timer.periodic(tick, (_) => unawaited(_onTick()));
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// Ask for a backup at the next chance, whatever the hour says. Used at shift
  /// close, where the day's takings are the thing most worth having off the till.
  void request(String reason) {
    _requested = reason;
    unawaited(_onTick());
  }

  Future<bool> get isConfigured async => (await connectionDetails()) != null;

  Future<CloudBackupStatus> status() async {
    final s = state.load();
    return (
      configured: await isConfigured,
      running: _running != null,
      url: s.url,
      shopName: s.shopName,
      lastSuccessAt: s.lastSuccessAt,
      lastTryAt: s.lastTryAt,
      lastError: s.lastError,
    );
  }

  /// The recovery key this till holds, without making one.
  Future<RecoveryKey?> heldRecoveryKey() async {
    final held = await secrets.read(recoveryKeySecret);
    return held == null || held.isEmpty ? null : RecoveryKey.parse(held);
  }

  /// The shop's recovery key, made on first use and kept in the keychain.
  Future<RecoveryKey> recoveryKey() async {
    final held = await heldRecoveryKey();
    if (held != null) return held;
    final key = RecoveryKey.generate();
    await secrets.write(recoveryKeySecret, key.format());
    return key;
  }

  /// Keep [key] as the shop's, after it has opened one of the shop's backups.
  Future<void> adoptRecoveryKey(RecoveryKey key) =>
      secrets.write(recoveryKeySecret, key.format());

  /// Pair this till with the shop on [url] using the code from the server.
  ///
  /// A shop has one recovery key for all its tills. Once its first backup is
  /// up, a till joining it has to be given that key in [recoveryKey], or it
  /// would seal its backups under one nobody holds.
  Future<String> pair({
    required String url,
    required String pairCode,
    String? recoveryKey,
  }) async {
    final given = (recoveryKey ?? '').trim().isEmpty
        ? null
        : RecoveryKey.parse(recoveryKey!);
    final client = _clientFor(url);
    try {
      final paired = await client.pair(
        pairCode: pairCode,
        deviceId: deviceId,
        deviceName: _deviceName(),
        appVersion: appVersion,
      );
      final shopKeyId = paired.keyId;
      if (shopKeyId != null) {
        if (given != null && given.id != shopKeyId) {
          throw const RecoveryKeyMismatch();
        }
        if (given == null && (await heldRecoveryKey())?.id != shopKeyId) {
          throw RecoveryKeyNeeded(paired.shopName);
        }
      }
      if (given != null) await adoptRecoveryKey(given);
      await secrets.write(tokenSecret, paired.token);
      state.save(CloudBackupState(url: url.trim(), shopName: paired.shopName));
      _audit?.record('system', 'cloud.paired', detail: '${url.trim()} ${paired.shopName}');
      changes.value++;
      return paired.shopName;
    } finally {
      client.close();
    }
  }

  /// Forget the pairing. Backups already on the server stay there.
  Future<void> unpair() async {
    await secrets.write(tokenSecret, null);
    state.save(CloudBackupState(url: state.load().url));
    _audit?.record('system', 'cloud.unpaired');
    changes.value++;
  }

  /// The paired server and this till's token, or null when unpaired.
  Future<({String url, String token})?> connectionDetails() async {
    final url = state.load().url;
    final token = await secrets.read(tokenSecret);
    if (url == null || url.isEmpty || token == null || token.isEmpty) return null;
    return (url: url, token: token);
  }

  /// A client for the paired server, for the restore screen. The caller closes it.
  Future<({CloudClient client, String token})?> connection() async {
    final details = await connectionDetails();
    if (details == null) return null;
    return (client: _clientFor(details.url), token: details.token);
  }

  /// Back up now, unless one is already running.
  Future<CloudBackupOutcome> runNow({String reason = 'manual'}) {
    if (_running != null) return Future.value(CloudBackupOutcome.busy);
    final attempt = _attempt(reason).whenComplete(() {
      _running = null;
      changes.value++;
    });
    _running = attempt;
    changes.value++;
    return attempt;
  }

  Future<void> _onTick() async {
    if (_running != null) return;
    final requested = _requested;
    if (requested == null && !_due()) return;
    _requested = null;
    await runNow(reason: requested ?? 'hourly');
  }

  bool _due() {
    final s = state.load();
    final now = _now();
    if (s.lastError != null &&
        s.lastTryAt != null &&
        now.difference(s.lastTryAt!) < retryAfter) {
      return false;
    }
    final last = s.lastSuccessAt;
    return last == null || now.difference(last) >= every;
  }

  Future<CloudBackupOutcome> _attempt(String reason) async {
    final connection = await this.connection();
    if (connection == null) return CloudBackupOutcome.notConfigured;
    final (:client, :token) = connection;
    final s = state.load();
    try {
      if (stressOrderCount(db) > 0) return CloudBackupOutcome.stressOrders;
      s.lastTryAt = _now();

      final database = await _snapshot();
      final dbSha = crypto.sha256.convert(database).toString();
      if (dbSha == s.lastDbSha) {
        s
          ..lastSuccessAt = _now()
          ..lastError = null;
        return CloudBackupOutcome.unchanged;
      }

      final key = await recoveryKey();
      final createdAt = _now();
      final sealed = await BackupEnvelope.seal(
        BackupHeader(
          deviceId: deviceId,
          deviceName: _deviceName(),
          createdAt: createdAt,
          appVersion: appVersion,
          dbSha256: dbSha,
          dbKey: await _databaseKey(),
        ),
        database,
        key,
      );
      await client.upload(token, sealed,
          createdAt: createdAt, reason: reason, keyId: key.id);

      s
        ..lastDbSha = dbSha
        ..lastSuccessAt = _now()
        ..lastError = null;
      _lastLogged = null;
      return CloudBackupOutcome.uploaded;
    } catch (e) {
      s.lastError = e is CloudError ? e.message : '$e';
      // Once per new reason, not every five minutes of an outage.
      if (s.lastError != _lastLogged) {
        _lastLogged = s.lastError;
        _audit?.record('system', 'cloud.backup.failed', detail: '$reason: $e');
      }
      return CloudBackupOutcome.failed;
    } finally {
      client.close();
      state.save(s);
    }
  }

  Future<Uint8List> _snapshot() async {
    final dir = await _scratch();
    final path = await backupDatabase(db, destination: () async => dir);
    final file = File(path);
    try {
      return await file.readAsBytes();
    } finally {
      try {
        await file.delete();
      } catch (_) {}
    }
  }
}
