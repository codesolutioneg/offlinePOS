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
  }
}
