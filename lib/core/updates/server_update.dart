import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;

import 'app_build.dart';
import 'download.dart';
import 'manifest_signature.dart';
import 'update_manifest.dart';

/// Where every till, primary or not, looks for a newer build on the internet.
const String releaseManifestUrl = String.fromEnvironment(
  'RELEASE_MANIFEST_URL',
  defaultValue:
      'https://updates.91.99.195.177.sslip.io/offline-pos/manifest.json',
);

/// The public half of the key `tools/release_sign.dart` signs with. A till
/// installs nothing from the server that this key did not sign, so whoever runs
/// the server still cannot push a build onto a till.
const String releasePublicKey = String.fromEnvironment(
  'RELEASE_PUBLIC_KEY',
  defaultValue: 'tInCU0/aYplSRsZ0sQTmXuXy1LovNgtidbNW8BfYz74=',
);

/// A build the server offers, signed and newer than the one running.
class ServerRelease {
  const ServerRelease(this.manifest, this.size);

  final UpdateManifest manifest;

  /// Bytes, when the manifest said; the progress bar falls back to the
  /// response's own length otherwise.
  final int? size;

  String get version => manifest.version;
}

/// Checks the release server and downloads from it.
class ServerUpdateChannel {
  ServerUpdateChannel({
    required this.manifestUrl,
    required ManifestVerifier verifier,
    HttpClient Function()? client,
    this.timeout = const Duration(seconds: 20),
  })  : _verifier = verifier,
        _client = client ?? HttpClient.new;

  factory ServerUpdateChannel.release() => ServerUpdateChannel(
        manifestUrl: Uri.parse(releaseManifestUrl),
        verifier: ManifestVerifier.fromBase64(releasePublicKey),
      );

  final Uri manifestUrl;
  final ManifestVerifier _verifier;
  final HttpClient Function() _client;
  final Duration timeout;

  /// The release newer than [ownVersion], or null when there is none or the
  /// server cannot be reached. Throws [FormatException] for a manifest the
  /// release key did not sign, which is worth recording rather than ignoring.
  Future<ServerRelease?> check(String ownVersion) async {
    final own = AppBuild.tryParse(ownVersion);
    if (own == null) return null;
    final String body;
    final client = _client();
    try {
      final request = await client.getUrl(manifestUrl).timeout(timeout);
      final response = await request.close().timeout(timeout);
      if (response.statusCode != 200) {
        await response.drain<void>().catchError((_) {});
        return null;
      }
      body = await utf8.decoder.bind(response).join().timeout(timeout);
    } on IOException {
      return null;
    } on TimeoutException {
      return null;
    } finally {
      client.close(force: true);
    }
    final manifest = await _verifier.verify(body);
    final offered = AppBuild.tryParse(manifest.version);
    if (offered == null || !offered.isNewerThan(own)) return null;
    return ServerRelease(manifest, _declaredSize(body));
  }

  /// Downloads [release] into [staging] and checks it against the signed digest.
  /// Throws on anything short of that, leaving nothing behind.
  Future<File> download(ServerRelease release, Directory staging,
      {DownloadProgress? onProgress}) async {
    await staging.create(recursive: true);
    final sep = Platform.pathSeparator;
    final file = File('${staging.path}${sep}server-${release.version}.zip');
    final partial = File('${file.path}.download');
    final client = _client();
    try {
      final request = await client.getUrl(release.manifest.url).timeout(timeout);
      final response = await request.close().timeout(timeout);
      if (response.statusCode != 200) {
        throw HttpException(
            '${response.statusCode} from ${release.manifest.url}');
      }
      await saveDownload(response, partial,
          onProgress: (got, total) =>
              onProgress?.call(got, total ?? release.size));
      final digest =
          (await crypto.sha256.bind(partial.openRead()).first).toString();
      if (digest != release.manifest.sha256) {
        throw StateError('the download does not match the signed release '
            '($digest)');
      }
      if (await file.exists()) await file.delete();
      await partial.rename(file.path);
      return file;
    } catch (_) {
      if (await partial.exists()) await partial.delete();
      rethrow;
    } finally {
      client.close(force: true);
    }
  }

  /// The size inside the signed payload. Read after the signature held, so it
  /// is the release key's word, not the server's.
  static int? _declaredSize(String body) {
    try {
      final document = jsonDecode(body) as Map;
      final payload = utf8.decode(base64.decode(document['manifest'] as String));
      final size = (jsonDecode(payload) as Map)['size'];
      return size is int ? size : null;
    } catch (_) {
      return null;
    }
  }
}
