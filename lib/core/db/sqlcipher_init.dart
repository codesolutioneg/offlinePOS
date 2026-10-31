import 'dart:ffi';
import 'dart:io';
import 'dart:math';

import 'package:sqlite3/open.dart';

/// Load SQLCipher on Android before the first [Db.open].
///
/// The native `.so` comes from `net.zetetic:sqlcipher-android` in the Android
/// Gradle build. Other platforms keep the default `sqlite3` lookup (plain or
/// whatever the installer bundled) until the sqlite3 ^3 migration.
Future<void> initSqlCipher() async {
  if (!Platform.isAndroid) return;
  open.overrideFor(OperatingSystem.android, openCipherOnAndroid);
}

/// Same lookup [sqlcipher_flutter_libs] 0.6.x used on old devices.
DynamicLibrary openCipherOnAndroid() {
  try {
    return DynamicLibrary.open('libsqlcipher.so');
  } catch (_) {
    final appIdAsBytes = File('/proc/self/cmdline').readAsBytesSync();
    final endOfAppId = max(appIdAsBytes.indexOf(0), 0);
    final appId = String.fromCharCodes(appIdAsBytes.sublist(0, endOfAppId));
    return DynamicLibrary.open('/data/data/$appId/lib/libsqlcipher.so');
  }
}
