import 'dart:io';

/// A breadcrumb trail of the launch, flushed to disk as each step begins.
///
/// The runner shows the window only once Flutter has rendered a frame
/// (`windows/runner/flutter_window.cpp`), so anything that throws or blocks
/// before `runApp` leaves a live process with no window and nothing on screen to
/// say why. Support cannot read a stack trace that was never printed.
///
/// Each line is written synchronously *before* the work it names, so the last
/// line in the file is the step that never finished. A launch that reached the
/// first frame says so, which tells a startup failure apart from a window that
/// opened somewhere off screen.
///
/// Never given a key, a password or a PIN: step names and failure reasons only.
class StartupLog {
  StartupLog(this._file);

  /// Kept in the system temp directory rather than the app's own, because
  /// resolving the app's directory is itself a step worth logging and is a step
  /// that can hang. Temp needs no plugin channel and no await.
  factory StartupLog.forThisLaunch({Directory? directory}) {
    final base = directory ?? Directory.systemTemp;
    return StartupLog(File('${base.path}${Platform.pathSeparator}$fileName'));
  }

  static const fileName = 'offline_pos_startup.log';

  /// Named for the person who will be asked to send it, not for the developer
  /// who will read it.
  static const supportFileName = 'offline_pos_problem_report.txt';

  /// Kept across launches so a good one can be compared with a bad one, but
  /// dropped once it stops being a diagnostic and starts being a disk usage.
  static const maxBytes = 256 * 1024;

  final File _file;

  /// Where to look, quoted on the failure screen so an operator can find it.
  String get path => _file.path;

  void begin(String version) {
    _trim();
    _write('--- launch $version on ${Platform.operatingSystem} ---');
  }

  /// Records that [description] is about to begin.
  void step(String description) => _write('step: $description');

  /// What the till found around itself, from [StartupProbe].
  void facts(Iterable<String> facts) {
    for (final fact in facts) {
      _write('fact: $fact');
    }
  }

  /// Copies the whole log somewhere an operator can be asked for it in one
  /// sentence, and returns where that was.
  ///
  /// The desktop first: "send me the file on your desktop" is an instruction
  /// anyone can follow, and no one should be talked through a console. Falls back
  /// to the home directory when the desktop has been redirected, and finally to
  /// the log's own directory, which always exists because it was just written to.
  String? copyForSupport() {
    for (final directory in _destinations()) {
      try {
        if (!directory.existsSync()) continue;
        final target =
            File('${directory.path}${Platform.pathSeparator}$supportFileName');
        target.writeAsStringSync(
          _file.existsSync() ? _file.readAsStringSync() : '',
          flush: true,
        );
        return target.path;
      } catch (_) {
        // Try the next one. A report that cannot be saved must not replace the
        // failure it was describing.
      }
    }
    return null;
  }

  Iterable<Directory> _destinations() {
    final home = Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'];
    return [
      if (home != null) Directory('$home${Platform.pathSeparator}Desktop'),
      if (home != null) Directory(home),
      _file.parent,
    ];
  }

  void failed(Object error, StackTrace stack) {
    _write('FAILED: $error');
    _write(stack.toString().trimRight());
  }

  void _write(String line) {
    final stamped = '${DateTime.now().toIso8601String()} $line';
    // Diagnostics must never be the reason a till fails to open, so a line that
    // cannot be written is dropped rather than thrown. Also to stderr, which
    // `flutter run` and a launch from a console both show.
    try {
      _file.writeAsStringSync('$stamped\n', mode: FileMode.append, flush: true);
    } catch (_) {}
    try {
      stderr.writeln(stamped);
    } catch (_) {}
  }

  void _trim() {
    try {
      if (_file.existsSync() && _file.lengthSync() > maxBytes) _file.deleteSync();
    } catch (_) {}
  }
}
