import 'startup_log.dart';

/// What to close if a launch throws part way through.
///
/// A failure screen with the sync timer still running behind it is a till that
/// says it is shut while it goes on talking to the server, and an open database
/// handle is a lock held against the next launch. Anything started before the
/// first frame registers here so a failed launch leaves nothing behind.
class StartupUnwind {
  final _steps = <void Function()>[];

  void add(void Function() close) => _steps.add(close);

  int get length => _steps.length;

  /// Closes everything in reverse, so a service is stopped before the database it
  /// was writing through is closed.
  void run(StartupLog log) {
    for (final step in _steps.reversed) {
      try {
        step();
      } catch (error) {
        // Already reporting one failure; a teardown that fails too must not
        // replace the reason the till would not open.
        log.note('could not undo a started service: $error');
      }
    }
    _steps.clear();
  }
}
