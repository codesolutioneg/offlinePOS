import 'dart:io';

import 'update_service.dart';

/// Starts the handoff script and returns once it is running. Injected so a test
/// can prove the argument shape without ever spawning a process.
typedef ScriptLauncher = Future<void> Function(
    String executable, List<String> arguments);

/// Ends this process so the script can replace its files. Injected for the same
/// reason: a test that really called this would take the test runner with it.
typedef ExitRequest = Future<void> Function();

/// Installs the Windows build by handing the job to a script that outlives us.
///
/// CI packages the Windows release as a zip of the runner directory, not as an
/// installer exe, so installing means replacing the files in the install directory
/// and starting the app again. A running Windows process cannot do that to itself:
/// its own exe and its dlls are held open for as long as it lives. So the work is
/// written out as a small script, launched detached, and this process then exits;
/// the script waits for that exit before it touches anything.
///
/// PowerShell rather than cmd because the two things the script has to do, wait on
/// a process id and unpack a zip, are one call each there (`Get-Process`,
/// `Expand-Archive`) and neither exists in cmd without shipping another tool onto
/// the till.
///
/// The order matters, because once this process has exited nobody is left to fix
/// anything: the archive is opened beside the zip first so a bad download cannot
/// half replace a working install, the install is written only once the whole
/// archive is on disk, and the app is started again unconditionally, including
/// after a failure. A shop staring at a machine that will not open is worse than a
/// shop running last week's build. What went wrong is written next to the zip,
/// because a detached script's exit code goes nowhere.
///
/// Nothing here decides whether installing is safe or whether the build is
/// trustworthy. `UpdateService` has already verified the signature and re-checked
/// the digest against this exact file, and asked the gate again.
class WindowsZipInstaller {
  WindowsZipInstaller({
    required this.stagingDirectory,
    Directory? installDirectory,
    String? executablePath,
    int? processId,
    ScriptLauncher? launcher,
    ExitRequest? requestExit,
  })  : executablePath = executablePath ?? Platform.resolvedExecutable,
        installDirectory = installDirectory ??
            File(executablePath ?? Platform.resolvedExecutable).parent,
        processId = processId ?? pid,
        _launch = launcher ?? _startDetached,
        _exit = requestExit ?? _exitProcess;

  /// App-private, and the same directory the verified zip is staged in. The script
  /// decides what lands in the install directory and runs with this user's rights,
  /// so it needs at least the protection the staged build gets: written somewhere a
  /// shared or world-writable temp directory would let anything on the machine
  /// rewrite between being written and being launched.
  final Directory stagingDirectory;

  /// Where the zip is unpacked over. The runner directory, which is where the
  /// executable lives.
  final Directory installDirectory;

  /// Relaunched once the files are in place.
  final String executablePath;

  /// The process the script waits for. Ours, so it is waiting for us to let go of
  /// our own files.
  final int processId;

  final ScriptLauncher _launch;
  final ExitRequest _exit;

  /// Matches [Installer]. Throws when the handoff could not be started.
  ///
  /// Throwing is the only honest failure here. `UpdateService` keeps the verified
  /// file and retries on the next pass when this throws, and marks the build
  /// installed when it does not, so a swallowed error would park a build that never
  /// actually installed and never gets another attempt.
  Future<void> install(String stagedZipPath) async {
    final script = await _writeScript(stagedZipPath);

    // Detached, so it survives the exit below. If it cannot even be started there
    // is nothing to exit for, and the throw leaves the staged build for next time.
    await _launch('powershell.exe', [
      '-NoProfile',
      '-NonInteractive',
      // The script is ours, in a directory only this app writes, and a shop machine
      // may well carry a policy that refuses any file-backed script.
      '-ExecutionPolicy',
      'Bypass',
      '-WindowStyle',
      'Hidden',
      '-File',
      script.path,
    ]);

    await _exit();
  }

  Future<File> _writeScript(String stagedZipPath) async {
    await stagingDirectory.create(recursive: true);
    final script = File(
        '${stagingDirectory.path}${Platform.pathSeparator}install-handoff.ps1');
    await script.writeAsString(
      buildScript(stagedZipPath: stagedZipPath, scriptPath: script.path),
      flush: true,
    );
    return script;
  }

  /// The script, as text. Public so a test can read what would run without running
  /// it, which is the only way to check the quoting.
  String buildScript({required String stagedZipPath, required String scriptPath}) {
    final zip = _quote(stagedZipPath);
    final target = _quote(installDirectory.path);
    final exe = _quote(executablePath);
    final self = _quote(scriptPath);
    final unpacked = _quote(
        '${stagingDirectory.path}${Platform.pathSeparator}$unpackedDirName');
    final report = _quote(
        '${stagingDirectory.path}${Platform.pathSeparator}$reportFileName');

    return '''
\$ErrorActionPreference = 'Stop'
\$tillPid = $processId

# Wait for the till to let go of its own exe and dlls. Unpacking over a live
# install fails part way through and leaves a mix of two builds behind.
for (\$i = 0; \$i -lt $_waitSeconds; \$i++) {
  if (-not (Get-Process -Id \$tillPid -ErrorAction SilentlyContinue)) { break }
  Start-Sleep -Seconds 1
}
if (Get-Process -Id \$tillPid -ErrorAction SilentlyContinue) {
  # Still running, so the files are still locked. Leaving the install untouched
  # means the till keeps the build it has and the next pass tries again.
  'still running after $_waitSeconds seconds, install not attempted' |
    Set-Content -LiteralPath $report
  exit 1
}

# From here the till is not running, so every path below has to end with it
# running again. A shop left staring at a machine that will not open is worse
# than a shop running last week's build.
try {
  # Unpacked beside the zip first, never straight over the install. A truncated
  # or unreadable archive then fails with the working build untouched, instead
  # of half replacing it and leaving a mix of two.
  if (Test-Path -LiteralPath $unpacked) {
    Remove-Item -LiteralPath $unpacked -Recurse -Force
  }
  Expand-Archive -LiteralPath $zip -DestinationPath $unpacked -Force

  # Only once the whole archive is on disk does the install get touched.
  Copy-Item -Path (Join-Path $unpacked '*') -Destination $target -Recurse -Force

  'installed' | Set-Content -LiteralPath $report
} catch {
  # Recorded for the next launch to find. The exit code cannot say anything: this
  # is detached, so nobody is waiting for it.
  "failed: \$(\$_.Exception.Message)" | Set-Content -LiteralPath $report
} finally {
  # Unconditional on purpose. Whether the copy finished, failed, or failed half
  # way, the till comes back up: worst case on a mixed directory, where the app's
  # own startup guard reports what it found.
  Start-Process -FilePath $exe -WorkingDirectory $target
  Remove-Item -LiteralPath $unpacked -Recurse -Force -ErrorAction SilentlyContinue
}

# Best effort: the shell may still hold this file open, and a leftover copy is
# overwritten by the next install anyway.
Remove-Item -LiteralPath $self -Force -ErrorAction SilentlyContinue
''';
  }

  /// Where the archive is expanded before anything in the install directory is
  /// touched, and where the outcome is left for the next launch to find.
  static const String unpackedDirName = 'update-unpacked';
  static const String reportFileName = 'install-report.txt';

  /// How long the script waits for this process to go away before giving up.
  static const int _waitSeconds = 120;

  /// A single-quoted PowerShell literal.
  ///
  /// Quoting is not tidiness. A shop installs under 'C:\Program Files\...', and an
  /// unquoted path with a space in it both breaks and turns the path into somewhere
  /// an argument can be smuggled. Single quotes rather than double because
  /// PowerShell expands neither variables nor `\$(...)` inside them, so a path that
  /// contains either is inert text; the only escape needed is a doubled quote.
  static String _quote(String value) => "'${value.replaceAll("'", "''")}'";

  /// Detached with no stdio: nothing is left holding a pipe to a process that has
  /// to outlive us.
  static Future<void> _startDetached(
      String executable, List<String> arguments) async {
    await Process.start(executable, arguments,
        mode: ProcessStartMode.detached);
  }

  static Future<void> _exitProcess() async => exit(0);
}

/// The install step for this platform, or null when there is none.
///
/// Only Windows has one. Everywhere else a verified build is staged and left for an
/// operator, which is deliberate rather than missing: on Android the install is the
/// platform's own signed-package flow, and on macOS and Linux this repo ships no
/// packaging that an unattended replace-and-restart would be correct against.
/// Returning null says that plainly, and `UpdateService` already treats a staged
/// build with no installer as a finished, reportable state.
Installer? platformUpdateInstaller({required Directory stagingDirectory}) {
  if (!Platform.isWindows) return null;
  return WindowsZipInstaller(stagingDirectory: stagingDirectory).install;
}
