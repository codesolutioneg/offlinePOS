import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/updates/windows_installer.dart';

/// Runs the real launcher, not a fake. PowerShell started detached straight from
/// the app had no console and exited before its first line, so every install
/// closed the till and installed nothing while every test with a fake launcher
/// passed.
void main() {
  test('the real launcher runs the handoff to the end', () async {
    final root = Directory.systemTemp.createTempSync('handoff live ');
    addTearDown(() => root.delete(recursive: true).catchError((_) => root));
    final target = Directory('${root.path}\\Offline POS')..createSync();
    File('${target.path}\\old.txt').writeAsStringSync('old');
    final staging = Directory('${root.path}\\Code Solution\\updates')
      ..createSync(recursive: true);
    final content = Directory('${root.path}\\build')..createSync();
    File('${content.path}\\new.txt').writeAsStringSync('new');
    final desktop = Directory('${root.path}\\Desktop')..createSync();
    final shell = await Process.run('powershell', [
      '-NoProfile',
      '-Command',
      "\$s = New-Object -ComObject WScript.Shell; "
          "\$l = \$s.CreateShortcut('${desktop.path}\\Old POS.lnk'); \$l.TargetPath = 'C:\\old copy\\offline_pos.exe'; \$l.Save(); "
          "\$l = \$s.CreateShortcut('${desktop.path}\\Notes.lnk'); \$l.TargetPath = 'C:\\Windows\\notepad.exe'; \$l.Save()",
    ]);
    expect(shell.exitCode, 0, reason: '${shell.stderr}');
    final zip = File('${staging.path}\\update-9.9.9+1.zip');
    final packed = await Process.run('powershell', [
      '-NoProfile',
      '-Command',
      "Compress-Archive -Path '${content.path}\\*' -DestinationPath '${zip.path}'",
    ]);
    expect(packed.exitCode, 0, reason: '${packed.stderr}');

    await WindowsZipInstaller(
      stagingDirectory: staging,
      installDirectory: target,
      // Nothing to relaunch: the report is written before the relaunch is tried.
      executablePath: '${target.path}\\not-here.exe',
      processId: 999999,
      requestExit: () async {},
      desktopDirectory: desktop.path,
    ).install(zip.path);

    final report = File('${staging.path}\\install-report.txt');
    for (var i = 0; i < 60 && !report.existsSync(); i++) {
      await Future<void>.delayed(const Duration(seconds: 1));
    }
    expect(report.existsSync(), isTrue, reason: 'the script never ran');
    expect(report.readAsStringSync(), contains('installed'));
    expect(File('${target.path}\\new.txt').existsSync(), isTrue);
    expect(File('${target.path}\\old.txt').existsSync(), isFalse);

    // The shortcut to the old copy is gone, one to this install is there, and a
    // shortcut to anything else is left alone.
    expect(File('${desktop.path}\\Old POS.lnk').existsSync(), isFalse);
    expect(File('${desktop.path}\\Notes.lnk').existsSync(), isTrue);
    final fresh = File('${desktop.path}\\Offline POS.lnk');
    expect(fresh.existsSync(), isTrue);
    final linked = await Process.run('powershell', [
      '-NoProfile',
      '-Command',
      "(New-Object -ComObject WScript.Shell).CreateShortcut('${fresh.path}').TargetPath",
    ]);
    expect('${linked.stdout}'.trim(), '${target.path}\\not-here.exe');
  }, skip: !Platform.isWindows, timeout: const Timeout(Duration(minutes: 2)));
}
