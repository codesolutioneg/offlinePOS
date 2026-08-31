import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/updates/update_gate.dart';
import 'package:offline_pos/core/updates/update_manifest.dart';
import 'package:offline_pos/core/updates/update_service.dart';
import 'package:offline_pos/core/updates/update_storage.dart';
import 'package:offline_pos/core/updates/windows_installer.dart';

import 'release_key.dart';

/// Records what would have been launched. Nothing is ever spawned here: a real
/// handoff script would wait for this test runner to exit and then unpack a zip
/// over it.
class FakeLauncher {
  FakeLauncher({this.fails = false});

  final bool fails;
  final List<List<String>> calls = [];

  Future<void> call(String executable, List<String> arguments) async {
    calls.add([executable, ...arguments]);
    if (fails) throw ProcessException(executable, arguments, 'not found', 2);
  }
}

/// Trading is 08:00-04:00, so this is a moment the gate allows an install.
final quietHours = DateTime(2026, 3, 4, 5, 15);

late Directory staging;

WindowsZipInstaller installerFor(
  FakeLauncher launcher, {
  required List<String> exits,
  String install = r'C:\Program Files\Offline POS',
  String exe = r'C:\Program Files\Offline POS\offline_pos.exe',
  int processId = 4242,
}) =>
    WindowsZipInstaller(
      stagingDirectory: staging,
      installDirectory: Directory(install),
      executablePath: exe,
      processId: processId,
      launcher: launcher.call,
      requestExit: () async => exits.add('exit'),
    );

File get script =>
    File('${staging.path}${Platform.pathSeparator}install-handoff.ps1');

void main() {
  setUp(() {
    staging = Directory.systemTemp.createTempSync('offlinepos-install-test');
  });

  tearDown(() {
    if (staging.existsSync()) staging.deleteSync(recursive: true);
  });

  test('the script is written into the staging directory and launched', () async {
    final launcher = FakeLauncher();
    final exits = <String>[];
    await installerFor(launcher, exits: exits)
        .install('${staging.path}${Platform.pathSeparator}update-1.1.0-7.zip');

    expect(script.existsSync(), isTrue,
        reason: 'the script belongs beside the staged build, not in a shared temp');

    expect(launcher.calls, hasLength(1));
    final call = launcher.calls.single;
    expect(call.first, 'powershell.exe');
    expect(call, containsAllInOrder(['-File', script.path]));
    expect(call, contains('-NoProfile'));
    expect(call, contains('-NonInteractive'));
  });

  test('the app is asked to exit only after the launcher succeeded', () async {
    final exits = <String>[];
    await installerFor(FakeLauncher(), exits: exits).install('C:\\staged.zip');
    expect(exits, ['exit']);

    final failed = <String>[];
    await expectLater(
      installerFor(FakeLauncher(fails: true), exits: failed)
          .install('C:\\staged.zip'),
      throwsA(isA<ProcessException>()),
    );
    expect(failed, isEmpty,
        reason: 'nothing was launched, so taking the app down would just be an '
            'outage with no update at the end of it');
  });

  test('every path in the script is quoted', () async {
    final launcher = FakeLauncher();
    final zip = r'C:\Program Files\Offline POS\updates\update-1.1.0-7.zip';
    await installerFor(launcher, exits: []).install(zip);

    final text = script.readAsStringSync();
    expect(text, contains("-LiteralPath '$zip'"));
    expect(text, contains("-Destination 'C:\\Program Files\\Offline POS'"));
    expect(
        text,
        contains(
            "-FilePath 'C:\\Program Files\\Offline POS\\offline_pos.exe'"));
    // Nothing an install path could carry may end up as a bare word the shell
    // parses, and a single-quoted PowerShell literal expands nothing inside it.
    for (final line in text.split('\n')) {
      if (line.contains('Program Files')) {
        expect(line, matches(RegExp(r"'[^']*Program Files[^']*'")));
      }
    }
  });

  test('a path containing a quote cannot break out of its literal', () async {
    final text = installerFor(FakeLauncher(), exits: [], install: r"C:\o'brien")
        .buildScript(stagedZipPath: r"C:\o'brien\u.zip", scriptPath: 'x.ps1');
    expect(text, contains(r"-Destination 'C:\o''brien'"));
    expect(text, contains(r"-LiteralPath 'C:\o''brien\u.zip'"));
  });

  test('a bad archive never touches the working install', () async {
    // Expanding straight over the install directory means a truncated download
    // half replaces the build and leaves a mix of two behind.
    final text = installerFor(FakeLauncher(), exits: [])
        .buildScript(stagedZipPath: r'C:\u.zip', scriptPath: r'C:\s.ps1');

    final expand = RegExp(r'Expand-Archive[^\n]*').stringMatch(text)!;
    expect(expand, contains(WindowsZipInstaller.unpackedDirName));
    expect(expand, isNot(contains('Program Files')),
        reason: 'the archive is opened beside the zip, not over the install');
    // The install is only written once the whole archive is on disk.
    expect(text.indexOf('Expand-Archive'), lessThan(text.indexOf('Copy-Item')));
  });

  test('the till is brought back up even when the install failed', () async {
    // The one outcome worse than a failed update: the process was stopped to let
    // the files be replaced, the replacing threw, and nothing started again. A
    // shop is then staring at a machine that will not open, with no running app
    // left to retry.
    final text = installerFor(FakeLauncher(), exits: [])
        .buildScript(stagedZipPath: r'C:\u.zip', scriptPath: r'C:\s.ps1');

    expect(text, contains('} catch {'));
    expect(text, contains('} finally {'));

    final relaunch = text.indexOf('Start-Process');
    final finallyAt = text.indexOf('} finally {');
    expect(finallyAt, greaterThan(-1));
    expect(relaunch, greaterThan(finallyAt),
        reason: 'the relaunch is unconditional, not the last step of the happy path');

    // And the copy is inside the guarded block, so a throw reaches the finally.
    expect(text.indexOf('try {'), lessThan(text.indexOf('Copy-Item')));
    expect(text.indexOf('Copy-Item'), lessThan(finallyAt));
  });

  test('the outcome is left where the next launch can read it', () async {
    // A detached script's exit code goes nowhere, so a failure that is not
    // written down looks exactly like a build that stages forever.
    final text = installerFor(FakeLauncher(), exits: [])
        .buildScript(stagedZipPath: r'C:\u.zip', scriptPath: r'C:\s.ps1');

    expect(text, contains(WindowsZipInstaller.reportFileName));
    expect(text, contains("'installed' | Set-Content"));
    expect(text, contains(r'"failed: $($_.Exception.Message)"'));
    expect(text, contains('install not attempted'));
  });

  test('the script waits for this process before it unpacks anything', () async {
    final text = installerFor(FakeLauncher(), exits: [], processId: 9091)
        .buildScript(stagedZipPath: r'C:\u.zip', scriptPath: r'C:\s.ps1');

    expect(text, contains(r'$tillPid = 9091'));
    final wait = text.indexOf('Get-Process -Id \$tillPid');
    final unpack = text.indexOf('Expand-Archive');
    final relaunch = text.indexOf('Start-Process');
    expect(wait, greaterThan(-1));
    expect(wait, lessThan(unpack));
    expect(unpack, lessThan(relaunch));

    // Still holding its files when the wait runs out means the install is left
    // alone rather than half replaced.
    expect(text, contains('exit 1'));
    expect(text.indexOf('exit 1'), lessThan(unpack));
  });

  test('there is no installer on a platform this repo does not package for', () {
    final installer = platformUpdateInstaller(stagingDirectory: staging);
    if (Platform.isWindows) {
      expect(installer, isNotNull);
    } else {
      expect(installer, isNull,
          reason: 'staged and manual is the deliberate answer off Windows');
    }
  });

  group('through the service', () {
    late ReleaseKey release;
    setUpAll(() async => release = await ReleaseKey.generate());

    final build = utf8.encode('the 1.1.0 windows zip');
    final digest = sha256.convert(build).toString();

    Future<String> manifest() => release.sign(utf8.encode(jsonEncode(UpdateManifest(
          version: '1.1.0',
          buildNumber: 7,
          url: Uri.parse('https://updates.example/offlinePOS-windows.zip'),
          sha256: digest,
        ).toMap())));

    UpdateService serviceWith(Installer installer, MemoryStorage storage) =>
        UpdateService(
          manifestUrl: Uri.parse('https://updates.example/manifest.json'),
          currentVersion: '1.0.0',
          verifier: release.verifier,
          readTill: () => TillState(localTime: quietHours, soleTill: false),
          fetchText: (_) => manifest(),
          fetchBytes: (_) async => build,
          storage: storage,
          installer: installer,
        );

    test('a handoff that could not start keeps the staged build', () async {
      final storage = MemoryStorage();
      final service = serviceWith(
        (path) async => throw ProcessException('powershell.exe', [], 'no shell', 2),
        storage,
      );

      final status = await service.check();
      expect(status.stage, UpdateStage.staged);
      expect(status.error, contains('no shell'));
      expect(status.stagedPath, isNotNull);
      expect(storage.deleted, isEmpty,
          reason: 'the file is verified, so the next pass should reuse it');

      // The pass after it gets to try again, which stage installed would refuse.
      expect((await service.check()).stage, UpdateStage.staged);
    });

    test('a handoff that started marks the build installed', () async {
      final storage = MemoryStorage();
      final handed = <String>[];
      final status =
          await serviceWith((path) async => handed.add(path), storage).check();
      expect(status.stage, UpdateStage.installed);
      expect(handed, [status.stagedPath]);
    });
  });
}

/// Staging with nothing on disk.
class MemoryStorage implements UpdateStorage {
  final Map<String, List<int>> files = {};
  final List<String> deleted = [];

  @override
  Future<String> save(String fileName, List<int> bytes) async {
    final path = '/var/updates/$fileName';
    files[path] = bytes;
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
