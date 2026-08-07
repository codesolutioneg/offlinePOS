import 'package:crypto/crypto.dart' as crypto;

import 'manifest_signature.dart';
import 'update_gate.dart';
import 'update_manifest.dart';
import 'update_storage.dart';

enum UpdateStage {
  /// Nothing checked yet.
  idle,

  /// The server has nothing newer.
  upToDate,

  /// The last check got no answer. Says nothing about the till's ability to sell.
  unreachable,

  /// There is a build, and the gate is holding it.
  waiting,

  downloading,

  /// Downloaded and verified, on disk, waiting for a safe moment.
  staged,

  /// The build could not be trusted and was thrown away: an unsigned or forged
  /// manifest, or bytes that did not match the digest the release key vouched for.
  discarded,

  installed,
}

/// A snapshot the diagnostics screen can render without asking any questions.
class UpdateStatus {
  const UpdateStatus({
    required this.stage,
    this.manifest,
    this.decision,
    this.stagedPath,
    this.error,
    this.checkedAt,
  });

  final UpdateStage stage;

  /// The build being considered, if the last check found one.
  final UpdateManifest? manifest;

  /// Why the till is waiting. Null when nothing is pending.
  final UpdateDecision? decision;

  final String? stagedPath;
  final String? error;
  final DateTime? checkedAt;

  bool get hasVerifiedDownload => stagedPath != null;

  /// One line for the UI: either what is happening or what it is waiting for.
  String get summary => switch (stage) {
        UpdateStage.idle => 'No update check yet.',
        UpdateStage.upToDate => 'Up to date.',
        UpdateStage.unreachable => 'Could not reach the update server.',
        UpdateStage.waiting => decision?.reason ?? 'Waiting.',
        UpdateStage.downloading => 'Downloading update.',
        UpdateStage.staged => decision?.reason ?? 'Update ready to install.',
        UpdateStage.discarded => 'Update refused: it could not be verified.',
        UpdateStage.installed => 'Update installed.',
      };
}

/// Reads the manifest. Injected so this is testable without a socket.
typedef FetchText = Future<String> Function(Uri url);

/// Reads the binary.
typedef FetchBytes = Future<List<int>> Function(Uri url);

/// Hands the verified file to the platform installer.
typedef Installer = Future<void> Function(String path);

/// Fetches, verifies and stages app updates.
///
/// Every step is allowed to fail. None of them may throw at the caller or hold a
/// lock a selling screen could ever wait on: an update is the least important thing
/// this app does, and a shop with no line must never notice that it failed.
///
/// Trust runs in one direction and starts at the release key. The signature
/// authenticates the manifest, the manifest carries the digest, and the digest
/// authenticates the bytes. Nothing here treats a value from the network as
/// trustworthy because another value from the same network agreed with it.
class UpdateService {
  UpdateService({
    required this.manifestUrl,
    required this.currentVersion,
    required ManifestVerifier verifier,
    required TillState Function() readTill,
    required FetchText fetchText,
    required FetchBytes fetchBytes,
    required UpdateStorage storage,
    this.gate = const UpdateGate(),
    this.installer,
    DateTime Function()? now,
  })  : _verifier = verifier,
        _readTill = readTill,
        _fetchText = fetchText,
        _fetchBytes = fetchBytes,
        _storage = storage,
        _now = now ?? DateTime.now {
    // Checked here rather than trusted from the wiring. The manifest is where the
    // digest lives, so a plain-http manifest url voids the whole chain, and the
    // one place that would notice is a call site that does not exist yet.
    if (manifestUrl.scheme != 'https' || manifestUrl.host.isEmpty) {
      throw ArgumentError.value(
          manifestUrl.toString(), 'manifestUrl', 'must be an https url with a host');
    }
  }

  final Uri manifestUrl;
  final String currentVersion;
  final UpdateGate gate;

  /// Optional: without it a verified build is staged and left for the host app or an
  /// operator to install.
  final Installer? installer;

  final ManifestVerifier _verifier;
  final TillState Function() _readTill;
  final FetchText _fetchText;
  final FetchBytes _fetchBytes;
  final UpdateStorage _storage;
  final DateTime Function() _now;

  UpdateStatus _status = const UpdateStatus(stage: UpdateStage.idle);
  UpdateStatus get status => _status;

  bool _running = false;

  /// One pass: ask the server, ask the gate, download, verify, stage, install.
  ///
  /// Safe to call on a timer. Returns the new status rather than throwing, so a tick
  /// can never take the app down.
  Future<UpdateStatus> check() async {
    if (_running) return _status;
    // Handed to the platform installer: this process is about to be replaced, and
    // installing the same file twice is a second uninvited restart.
    if (_status.stage == UpdateStage.installed) return _status;
    _running = true;
    try {
      final staged = _status.hasVerifiedDownload ? _status.manifest : null;

      final UpdateManifest manifest;
      try {
        // An unsigned or forged manifest is indistinguishable from no answer, and
        // is treated as one: the till keeps the build it is running.
        manifest = await _verifier.verify(await _fetchText(manifestUrl));
      } catch (e) {
        // A verified build on disk outlives a failed check: it needs no server.
        if (staged != null) return await _installWhenSafe();
        return _set(UpdateStatus(
          stage: UpdateStage.unreachable,
          error: e.toString(),
          checkedAt: _now(),
        ));
      }

      if (staged != null) {
        if (staged.sha256 == manifest.sha256) return await _installWhenSafe();
        // The rollout changed while this till waited for a quiet moment. Delete the
        // staged file rather than installing a build the server has withdrawn, and
        // rather than leaving it on the till for someone to install by hand: a build
        // is usually pulled because there is something wrong with it.
        await _erase(_status.stagedPath);
        _set(const UpdateStatus(stage: UpdateStage.idle));
      }

      if (!manifest.isNewerThan(currentVersion)) {
        // Covers a rollback too: a server advertising an older build is ignored
        // rather than downgrading a till that is already ahead of it.
        return _set(UpdateStatus(
          stage: UpdateStage.upToDate,
          manifest: manifest,
          checkedAt: _now(),
        ));
      }

      final mandatory = manifest.isMandatoryFor(currentVersion);
      final decision = gate.evaluate(_readTill(), mandatory: mandatory);
      if (!decision.allowed) {
        // Not downloaded either: pulling a hundred megabytes over a shop's line
        // during service is its own kind of harm.
        return _set(UpdateStatus(
          stage: UpdateStage.waiting,
          manifest: manifest,
          decision: decision,
          checkedAt: _now(),
        ));
      }

      _set(UpdateStatus(
        stage: UpdateStage.downloading,
        manifest: manifest,
        checkedAt: _now(),
      ));

      final List<int> bytes;
      try {
        bytes = await _fetchBytes(manifest.url);
      } catch (e) {
        return _set(UpdateStatus(
          stage: UpdateStage.unreachable,
          manifest: manifest,
          error: e.toString(),
          checkedAt: _now(),
        ));
      }

      final digest = crypto.sha256.convert(bytes).toString();
      if (digest != manifest.sha256) {
        // Truncated, corrupted or substituted: all three look the same here and all
        // three are refused. The bytes are dropped without ever touching disk, so
        // there is nothing for a later pass to pick up by accident.
        return _set(UpdateStatus(
          stage: UpdateStage.discarded,
          manifest: manifest,
          error: 'checksum mismatch: expected ${manifest.sha256}, got $digest',
          checkedAt: _now(),
        ));
      }

      final String path;
      try {
        path = await _storage.save(_fileNameFor(manifest), bytes);
      } catch (e) {
        return _set(UpdateStatus(
          stage: UpdateStage.discarded,
          manifest: manifest,
          error: e.toString(),
          checkedAt: _now(),
        ));
      }

      _set(UpdateStatus(
        stage: UpdateStage.staged,
        manifest: manifest,
        stagedPath: path,
        checkedAt: _now(),
      ));
      return await _installWhenSafe();
    } finally {
      _running = false;
    }
  }

  Future<UpdateStatus> _installWhenSafe() async {
    final manifest = _status.manifest;
    final path = _status.stagedPath;
    if (manifest == null || path == null) return _status;

    // Asked again here, not reused from the download: a cashier can start a sale
    // while a large build is still coming down the line, and the state that matters
    // is the one at the instant the app is replaced.
    final decision = gate.evaluate(
      _readTill(),
      mandatory: manifest.isMandatoryFor(currentVersion),
    );
    if (!decision.allowed) {
      return _set(UpdateStatus(
        stage: UpdateStage.staged,
        manifest: manifest,
        decision: decision,
        stagedPath: path,
        checkedAt: _now(),
      ));
    }

    final install = installer;
    if (install == null) {
      return _set(UpdateStatus(
        stage: UpdateStage.staged,
        manifest: manifest,
        stagedPath: path,
        checkedAt: _now(),
      ));
    }

    // Checked again against the file on disk, not against the bytes that were
    // hashed at download. The gate deliberately holds a verified build until the
    // shop closes, so hours pass in between, and anything that can write to the
    // staging directory in that window would otherwise get to choose what the till
    // installs. The digest itself is trustworthy because the release key signed
    // the manifest carrying it.
    final List<int> onDisk;
    try {
      onDisk = await _storage.read(path);
    } catch (e) {
      // Unreadable now does not mean tampered with; the next pass tries again.
      return _set(UpdateStatus(
        stage: UpdateStage.staged,
        manifest: manifest,
        stagedPath: path,
        error: e.toString(),
        checkedAt: _now(),
      ));
    }

    final onDiskDigest = crypto.sha256.convert(onDisk).toString();
    if (onDiskDigest != manifest.sha256) {
      await _erase(path);
      return _set(UpdateStatus(
        stage: UpdateStage.discarded,
        manifest: manifest,
        error: 'staged file changed after it was verified: expected '
            '${manifest.sha256}, got $onDiskDigest',
        checkedAt: _now(),
      ));
    }

    try {
      await install(path);
    } catch (e) {
      // The file is verified and still on disk, so the next pass can retry.
      return _set(UpdateStatus(
        stage: UpdateStage.staged,
        manifest: manifest,
        stagedPath: path,
        error: e.toString(),
        checkedAt: _now(),
      ));
    }
    return _set(UpdateStatus(
      stage: UpdateStage.installed,
      manifest: manifest,
      stagedPath: path,
      checkedAt: _now(),
    ));
  }

  UpdateStatus _set(UpdateStatus status) => _status = status;

  /// Removes a staged build. Failing to delete is not worth reporting: the file is
  /// only ever installed after it has been re-checked, so one left behind is
  /// wasted disk and not a way in.
  Future<void> _erase(String? path) async {
    if (path == null) return;
    try {
      await _storage.delete(path);
    } catch (_) {}
  }

  static final RegExp _unsafe = RegExp(r'[^A-Za-z0-9._-]');
  static final RegExp _extension = RegExp(r'\.[A-Za-z0-9]{1,6}$');

  /// The server names the build, never the path: a url ending in '../../lib/x.so'
  /// must not be able to choose where the till writes.
  static String _fileNameFor(UpdateManifest manifest) {
    final ext = _extension.stringMatch(manifest.url.path) ?? '';
    final version = manifest.version.replaceAll(_unsafe, '_');
    return 'update-$version-${manifest.buildNumber}$ext';
  }
}
