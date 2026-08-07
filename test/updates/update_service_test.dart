import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/updates/manifest_signature.dart';
import 'package:offline_pos/core/updates/update_gate.dart';
import 'package:offline_pos/core/updates/update_manifest.dart';
import 'package:offline_pos/core/updates/update_service.dart';
import 'package:offline_pos/core/updates/update_storage.dart';

import 'release_key.dart';

final build = utf8.encode('the 1.1.0 binary');
final buildDigest = sha256.convert(build).toString();

/// Trading is 08:00-04:00, so this is the quiet window the gate allows.
final quietHours = DateTime(2026, 3, 4, 5, 15);
final midService = DateTime(2026, 3, 4, 13, 30);

/// Stands in for the release server's signing key. The real private half lives on
/// that server and never reaches this repository or a device.
late ReleaseKey release;

/// The manifest bytes, unsigned. Only useful for building a document by hand.
List<int> manifestBytes({
  String version = '1.1.0',
  int buildNumber = 7,
  String? digest,
  String url = 'https://updates.example/pos-1.1.0.apk',
  String? minimumSupported,
  bool mandatory = false,
}) =>
    utf8.encode(jsonEncode(UpdateManifest(
      version: version,
      buildNumber: buildNumber,
      url: Uri.parse(url),
      sha256: digest ?? buildDigest,
      minimumSupportedVersion: minimumSupported,
      mandatory: mandatory,
    ).toMap()));

/// What the update host actually serves: the manifest bytes plus a signature over
/// exactly those bytes.
Future<String> signedManifest({
  String version = '1.1.0',
  int buildNumber = 7,
  String? digest,
  String url = 'https://updates.example/pos-1.1.0.apk',
  String? minimumSupported,
  bool mandatory = false,
}) =>
    release.sign(manifestBytes(
      version: version,
      buildNumber: buildNumber,
      digest: digest,
      url: url,
      minimumSupported: minimumSupported,
      mandatory: mandatory,
    ));

/// Staging with nothing on disk, and a hook for something else rewriting a file
/// the till has already verified.
class MemoryStorage implements UpdateStorage {
  final Map<String, List<int>> files = {};
  final List<String> saved = [];
  final List<String> deleted = [];

  @override
  Future<String> save(String fileName, List<int> bytes) async {
    final path = '/var/updates/$fileName';
    files[path] = bytes;
    saved.add(fileName);
    return path;
  }

  @override
  Future<List<int>> read(String path) async {
    final bytes = files[path];
    if (bytes == null) throw StateError('no such file: $path');
    return bytes;
  }

  @override
  Future<void> delete(String path) async {
    files.remove(path);
    deleted.add(path);
  }
}

/// A till with no network, no disk and no installer, all of it observable.
class Harness {
  Harness({
    required this.body,
    List<int>? binary,
    this.current = '1.0.0',
    TillState? state,
    bool withInstaller = true,
    ManifestVerifier? verifier,
  })  : bytes = binary ?? build,
        till = state ?? TillState(localTime: quietHours, soleTill: false) {
    service = UpdateService(
      manifestUrl: Uri.parse('https://updates.example/manifest.json'),
      currentVersion: current,
      verifier: verifier ?? release.verifier,
      readTill: () => till,
      fetchText: (url) async {
        final b = body;
        if (b == null) throw Exception('no route to host');
        return b;
      },
      fetchBytes: (url) async {
        downloads++;
        onDownload?.call();
        return bytes;
      },
      storage: storage,
      installer: withInstaller ? (path) async => installed.add(path) : null,
      now: () => DateTime.utc(2026, 3, 4, 5, 15),
    );
  }

  /// Null stands for a server that cannot be reached.
  String? body;
  List<int> bytes;
  final String current;
  TillState till;

  /// Runs while the download is in flight, to model the shop moving underneath it.
  void Function()? onDownload;

  int downloads = 0;
  final MemoryStorage storage = MemoryStorage();
  final List<String> installed = [];

  List<String> get saved => storage.saved;

  late final UpdateService service;
}

void main() {
  setUpAll(() async => release = await ReleaseKey.generate());

  group('version comparison', () {
    test('1.10.0 is newer than 1.9.0', () {
      expect(AppVersion.parse('1.10.0') > AppVersion.parse('1.9.0'), isTrue);
      expect(AppVersion.parse('1.9.0') > AppVersion.parse('1.10.0'), isFalse);
    });

    test('a missing patch position is zero', () {
      expect(AppVersion.parse('1.2'), AppVersion.parse('1.2.0'));
      expect(AppVersion.parse('1.2').hashCode, AppVersion.parse('1.2.0').hashCode);
    });

    test('the build metadata does not make a build newer', () {
      expect(AppVersion.parse('1.2.0+99'), AppVersion.parse('1.2.0+1'));
    });

    test('a pre-release is older than the release it leads to', () {
      expect(AppVersion.parse('1.2.0-rc2') < AppVersion.parse('1.2.0'), isTrue);
      expect(AppVersion.parse('1.2.0-rc2') > AppVersion.parse('1.2.0-rc1'), isTrue);
    });

    test('a large minor never loses to a large major', () {
      expect(AppVersion.parse('2.0.0') > AppVersion.parse('1.99.99'), isTrue);
    });
  });

  test('an advertised version that is not newer is ignored', () async {
    final older = Harness(body: await signedManifest(version: '1.9.0'), current: '1.10.0');
    expect((await older.service.check()).stage, UpdateStage.upToDate);
    expect(older.downloads, 0);

    final same = Harness(body: await signedManifest(version: '1.10.0'), current: '1.10.0');
    expect((await same.service.check()).stage, UpdateStage.upToDate);
    expect(same.downloads, 0);
  });

  test('a manifest check that gets no answer leaves the till selling', () async {
    final h = Harness(body: null);
    final status = await h.service.check();
    expect(status.stage, UpdateStage.unreachable);
    expect(status.error, contains('no route to host'));
    expect(h.downloads, 0);
    expect(h.saved, isEmpty);
  });

  test('a manifest that cannot be trusted is treated as no answer', () async {
    final noDigest = Harness(
        body: await release.sign(utf8.encode(jsonEncode({
      'version': '1.1.0',
      'url': 'https://updates.example/pos.apk',
      'sha256': 'not-a-digest',
    }))));
    expect((await noDigest.service.check()).stage, UpdateStage.unreachable);

    final plainHttp = Harness(
        body: await signedManifest(url: 'http://updates.example/pos-1.1.0.apk'));
    expect((await plainHttp.service.check()).stage, UpdateStage.unreachable);

    final garbage = Harness(body: '<html>login</html>');
    expect((await garbage.service.check()).stage, UpdateStage.unreachable);
    expect(garbage.downloads, 0);
  });

  group('only the release key decides what a till installs', () {
    test('a manifest signed by somebody else is refused, and nothing downloaded',
        () async {
      // Everything an attacker who owns the update host can produce: a manifest
      // they wrote, a binary they built, and a digest that matches it perfectly.
      // The digest is self-consistent and worth nothing, which is the whole point.
      final theirBinary = utf8.encode('their binary');
      final h = Harness(
        body: await ReleaseKey.forged(manifestBytes(
          digest: sha256.convert(theirBinary).toString(),
          url: 'https://updates.example/theirs.apk',
        )),
        binary: theirBinary,
      );

      final status = await h.service.check();
      expect(status.stage, UpdateStage.unreachable);
      expect(h.downloads, 0);
      expect(h.saved, isEmpty);
      expect(h.installed, isEmpty);
    });

    test('a manifest with no signature at all is refused', () async {
      final h = Harness(body: ReleaseKey.unsigned(manifestBytes()));
      expect((await h.service.check()).stage, UpdateStage.unreachable);
      expect(h.downloads, 0);
    });

    test('one flipped byte in the manifest invalidates the signature', () async {
      final document =
          jsonDecode(await signedManifest()) as Map<String, dynamic>;
      final bytes = base64.decode(document['manifest'] as String);
      bytes[0] ^= 0x01;
      document['manifest'] = base64.encode(bytes);

      final h = Harness(body: jsonEncode(document));
      expect((await h.service.check()).stage, UpdateStage.unreachable);
      expect(h.downloads, 0);
    });

    test('a till built with a different release key takes nothing', () async {
      final other = await ReleaseKey.generate();
      final h = Harness(body: await signedManifest(), verifier: other.verifier);
      expect((await h.service.check()).stage, UpdateStage.unreachable);
      expect(h.installed, isEmpty);
    });

    test('a plain-http manifest url cannot be wired up at all', () {
      // The binary url is checked when the manifest is parsed; this is the other
      // end, where a call site could otherwise void the whole chain in one line.
      expect(
        () => UpdateService(
          manifestUrl: Uri.parse('http://updates.example/manifest.json'),
          currentVersion: '1.0.0',
          verifier: release.verifier,
          readTill: () => TillState(localTime: quietHours),
          fetchText: (_) async => '',
          fetchBytes: (_) async => const [],
          storage: MemoryStorage(),
        ),
        throwsArgumentError,
      );
    });
  });

  group('a staged build is still checked at the moment it is installed', () {
    test('a file rewritten while the gate held it is refused, not installed',
        () async {
      // Downloaded and verified, then a cashier starts a sale, so the gate holds
      // the build instead of installing it.
      final h = Harness(body: await signedManifest());
      h.onDownload =
          () => h.till = TillState(localTime: quietHours, saleInProgress: true);
      expect((await h.service.check()).stage, UpdateStage.staged);

      // Hours pass with the build verified and waiting for the shop to close.
      // Anything that can write to the staging directory in that window would
      // otherwise get to choose what the till installs.
      final staged = h.storage.files.keys.single;
      h.storage.files[staged] = utf8.encode('a binary nobody signed');

      h.till = TillState(localTime: quietHours, soleTill: false);
      final status = await h.service.check();

      expect(status.stage, UpdateStage.discarded);
      expect(status.error, contains('changed after it was verified'));
      expect(h.installed, isEmpty);
      expect(h.storage.files, isEmpty, reason: 'and it is not left lying there');
    });

    test('a build the server withdraws is deleted, not left for a human to find',
        () async {
      final replacement = utf8.encode('the 1.2.0 binary');
      final h = Harness(body: await signedManifest(), withInstaller: false);
      final first = (await h.service.check()).stagedPath!;

      h.body = await signedManifest(
        version: '1.2.0',
        buildNumber: 8,
        digest: sha256.convert(replacement).toString(),
        url: 'https://updates.example/pos-1.2.0.apk',
      );
      h.bytes = replacement;
      await h.service.check();

      expect(h.storage.deleted, contains(first));
      expect(h.storage.files.keys, isNot(contains(first)));
    });
  });

  test('a download whose hash does not match is discarded and reported', () async {
    final h = Harness(body: await signedManifest(), binary: utf8.encode('tampered'));
    final status = await h.service.check();
    expect(status.stage, UpdateStage.discarded);
    expect(status.error, contains('checksum mismatch'));
    expect(h.saved, isEmpty, reason: 'a bad download never reaches disk');
    expect(h.installed, isEmpty);
  });

  test('a verified download is written once and installed', () async {
    final h = Harness(body: await signedManifest());
    final status = await h.service.check();
    expect(status.stage, UpdateStage.installed);
    expect(h.saved, ['update-1.1.0-7.apk']);
    expect(h.installed, ['/var/updates/update-1.1.0-7.apk']);
  });

  test('nothing is downloaded while sales are waiting to sync', () async {
    final h = Harness(
      body: await signedManifest(mandatory: true),
      state: TillState(localTime: quietHours, pendingSales: 4, soleTill: false),
    );
    final status = await h.service.check();
    expect(status.stage, UpdateStage.waiting);
    expect(status.decision!.blockers, contains(UpdateBlocker.unsyncedSales));
    expect(h.downloads, 0);
    expect(h.installed, isEmpty);
  });

  test('a routine update is not downloaded during service', () async {
    final h = Harness(
      body: await signedManifest(),
      state: TillState(localTime: midService, soleTill: false),
    );
    expect((await h.service.check()).stage, UpdateStage.waiting);
    expect(h.downloads, 0);
  });

  test('a sale that starts during the download stops the install', () async {
    final h = Harness(body: await signedManifest());
    h.onDownload =
        () => h.till = TillState(localTime: quietHours, saleInProgress: true);

    final blocked = await h.service.check();
    expect(blocked.stage, UpdateStage.staged);
    expect(blocked.decision!.primary!.blocker, UpdateBlocker.saleInProgress);
    expect(h.installed, isEmpty);

    // Sale finished: the verified file is installed without downloading again.
    h.till = TillState(localTime: quietHours, soleTill: false);
    expect((await h.service.check()).stage, UpdateStage.installed);
    expect(h.downloads, 1);
    expect(h.saved, hasLength(1));
    expect(h.installed, hasLength(1));
  });

  test('a verified build survives a failed check', () async {
    final h = Harness(body: await signedManifest(), withInstaller: false);
    expect((await h.service.check()).stage, UpdateStage.staged);

    h.body = null;
    final status = await h.service.check();
    expect(status.stage, UpdateStage.staged);
    expect(status.stagedPath, '/var/updates/update-1.1.0-7.apk');
  });

  test('a build the server withdraws is not the one that gets installed', () async {
    final replacement = utf8.encode('the 1.2.0 binary');
    final h = Harness(body: await signedManifest(), withInstaller: false);
    expect((await h.service.check()).stage, UpdateStage.staged);

    // The rollout is pulled and replaced while this till waits for a quiet moment.
    h.body = await signedManifest(
      version: '1.2.0',
      buildNumber: 8,
      digest: sha256.convert(replacement).toString(),
      url: 'https://updates.example/pos-1.2.0.apk',
    );
    h.bytes = replacement;

    final status = await h.service.check();
    expect(status.stage, UpdateStage.staged);
    expect(status.manifest!.version, '1.2.0');
    expect(status.stagedPath, '/var/updates/update-1.2.0-8.apk');
    expect(h.saved, ['update-1.1.0-7.apk', 'update-1.2.0-8.apk']);
  });

  test('a till the server no longer supports is updated as if mandatory', () async {
    final h = Harness(
      body: await signedManifest(minimumSupported: '1.1.0'),
      current: '1.0.0',
      state: TillState(localTime: midService, soleTill: false),
    );
    expect((await h.service.check()).stage, UpdateStage.installed);
  });

  test('without an installer a verified build is staged and left alone', () async {
    final h = Harness(body: await signedManifest(), withInstaller: false);
    final status = await h.service.check();
    expect(status.stage, UpdateStage.staged);
    expect(status.hasVerifiedDownload, isTrue);
    expect(status.summary, contains('ready to install'));
  });
}
