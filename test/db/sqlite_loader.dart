import 'dart:ffi';
import 'dart:io';

import 'package:sqlite3/open.dart';

/// Use the system SQLite for tests.
///
/// The package ships a prebuilt library linked against a newer glibc than some
/// build boxes have, which fails to load with a `GLIBC_2.xx not found`. The system
/// library is ABI-compatible and always present on Linux and macOS.
void useSystemSqlite() {
  if (Platform.isLinux) {
    open.overrideFor(OperatingSystem.linux,
        () => DynamicLibrary.open('libsqlite3.so.0'));
  } else if (Platform.isMacOS) {
    open.overrideFor(OperatingSystem.macOS,
        () => DynamicLibrary.open('libsqlite3.dylib'));
  } else if (Platform.isWindows) {
    // The Windows build box ships an old sqlite3.dll with no UPSERT support
    // (ON CONFLICT ... DO UPDATE needs SQLite 3.24+), which the schema relies on.
    // CI downloads a modern dll and points SQLITE3_DLL at it; without the override
    // the tests would load whatever old library happens to be on the PATH.
    final lib = Platform.environment['SQLITE3_DLL'];
    if (lib != null && lib.isNotEmpty) {
      open.overrideFor(OperatingSystem.windows, () => DynamicLibrary.open(lib));
    }
  }
}
