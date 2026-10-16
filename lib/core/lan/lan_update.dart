import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;

import 'lan_credential.dart';
import 'lan_peer.dart';

/// Packs [from] into the zip [to]. Injected so a suite can offer a build without
/// shelling out.
typedef PackFolder = Future<void> Function(Directory from, File to);

/// The build the primary runs, offered to the other tills in the shop so updating
/// one machine updates all of them.
///
/// The package is this till's own program folder, zipped the first time anyone
/// asks and kept for as long as this build runs. Packing takes tens of seconds, so
/// the first ask is answered "not ready" and the asker comes back later rather than
/// holding a request open.
class LanUpdateOffer {
  LanUpdateOffer({
    required this.version,
    required this.installDirectory,
    required this.cacheDirectory,
    PackFolder? pack,
    LanLog? log,
  })  : _pack = pack ?? packWithPowerShell,
        _log = log;

  final String version;
  final Directory installDirectory;
  final Directory cacheDirectory;
  final PackFolder _pack;
  final LanLog? _log;

  File? _package;
  String? _sha256;
  int? _size;
  Future<void>? _packing;

  /// Why the last packing failed, while it is retrying.
  String? lastError;

  /// The zip, once packed.
  File? get package => _package;

  /// What this till offers right now. The first ask starts the packing.
  Map<String, dynamic> manifest() {
    if (_package == null) _packing ??= _build();
    return {
      'version': version,
      'ready': _package != null,
      if (_package != null) 'size': _size,
      if (_package != null) 'sha256': _sha256,
    };
  }

  /// Waits for a packing already started. For the tests and for a caller that
  /// wants the offer ready before it answers.
  Future<void> get packed => _packing ?? Future.value();

  Future<void> _build() async {
    try {
      await cacheDirectory.create(recursive: true);
      final file = File('${cacheDirectory.path}${Platform.pathSeparator}'
          'lan-offer-$version.zip');
      if (!await file.exists()) {
        // Compress-Archive only writes a name ending in .zip.
        final partial = File('${cacheDirectory.path}${Platform.pathSeparator}'
            'lan-offer-$version.partial.zip');
        if (await partial.exists()) await partial.delete();
        await _pack(installDirectory, partial);
        await partial.rename(file.path);
      }
      final digest = await crypto.sha256.bind(file.openRead()).first;
      _size = await file.length();
      _sha256 = digest.toString();
      _package = file;
      lastError = null;
      await _dropOlderOffers(file);
    } catch (e) {
      lastError = '$e';
      _log?.call('lan.update.pack_failed', '$e');
      // The next ask tries again.
      _packing = null;
    }
  }

  Future<void> _dropOlderOffers(File keep) async {
    try {
      await for (final entry in cacheDirectory.list()) {
        final name = entry.uri.pathSegments.last;
        if (entry is File && name.startsWith('lan-offer-') && entry.path != keep.path) {
          await entry.delete();
        }
      }
    } catch (_) {}
  }

  /// Zips the program folder with what every Windows till already has. Logs and
  /// write probes stay behind: they belong to this machine, not to the build.
  static Future<void> packWithPowerShell(Directory from, File to) async {
    String quote(String s) => "'${s.replaceAll("'", "''")}'";
    final script = "\$ErrorActionPreference = 'Stop'; "
        'Get-ChildItem -LiteralPath ${quote(from.path)} -Force | '
        "Where-Object { \$_.Name -notlike '*.log' -and \$_.Name -notlike '.update-*' } | "
        'Compress-Archive -DestinationPath ${quote(to.path)} -CompressionLevel Fastest';
    final result = await Process.run('powershell.exe', [
      '-NoProfile',
      '-NonInteractive',
      '-ExecutionPolicy',
      'Bypass',
      '-Command',
      script,
    ]);
    if (result.exitCode != 0) {
      throw ProcessException(
          'powershell.exe', const [], '${result.stderr}'.trim(), result.exitCode);
    }
  }

  /// The words the primary signs, so a secondary installs only a package whose
  /// size and digest came from a till holding the shop key.
  static String signedText(String version, String sha256, int size) =>
      '$version|$sha256|$size';
}

/// A newer build the primary is offering, ready to download.
class LanUpdateAvailable {
  const LanUpdateAvailable({
    required this.version,
    required this.size,
    required this.sha256,
  });

  final String version;
  final int size;
  final String sha256;
}

/// Signs and checks an offer with the shop key.
extension LanUpdateSigning on LanCredential {
  static const String _method = 'OFFER';
  static const String _path = '/lan/update';

  String signOffer(String version, String sha256, int size) => stamp(
        method: _method,
        path: _path,
        body: LanUpdateOffer.signedText(version, sha256, size),
      );

  bool offerIsGenuine(String? signature, String version, String sha256, int size) =>
      check(
        signature,
        method: _method,
        path: _path,
        body: LanUpdateOffer.signedText(version, sha256, size),
      ) ==
      LanAuth.ok;
}
