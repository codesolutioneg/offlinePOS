import 'dart:io';

/// The facts support would otherwise have to talk an operator through collecting.
///
/// Read at launch and written into the log, so a till that will not open explains
/// its own state without anyone opening Task Manager, a console or Explorer.
/// Paths, sizes and versions only: nothing here can identify a customer or carry a
/// secret, because this file is meant to be sent to whoever is helping.
class StartupProbe {
  /// [databasePath] is null when the launch failed before it was even known.
  static List<String> facts({required String version, String? databasePath}) {
    final facts = <String>[
      'app version: $version',
      'system: ${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
      'locale: ${Platform.localeName}',
    ];

    if (databasePath == null) {
      facts.add('database: not resolved, the launch failed before its path was known');
      return facts;
    }

    facts.add('database: $databasePath');
    // A -wal or -shm left beside the file is what an instance that never closed
    // leaves behind. Worth knowing before anyone is told to delete anything.
    for (final suffix in const ['', '-wal', '-shm', '-journal']) {
      final name = suffix.isEmpty ? 'pos.db' : 'pos.db$suffix';
      final file = File('$databasePath$suffix');
      try {
        facts.add(file.existsSync()
            ? '  $name present, ${file.lengthSync()} bytes, '
                'last written ${file.lastModifiedSync().toUtc().toIso8601String()}'
            : '  $name absent');
      } catch (error) {
        facts.add('  $name could not be read: $error');
      }
    }
    return facts;
  }
}
