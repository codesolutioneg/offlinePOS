import 'dart:ffi';
import 'dart:io';

import 'package:sqlite3/open.dart';

/// Point tests at the system SQLCipher so encryption can be exercised for real.
/// Only Linux is wired here because that is where these tests run.
void useSystemSqlcipher() {
  if (Platform.isLinux) {
    open.overrideFor(OperatingSystem.linux,
        () => DynamicLibrary.open('libsqlcipher.so.0'));
  }
}
