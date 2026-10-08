import 'dart:io';
import 'dart:typed_data';

import '../db/db_key.dart';
import 'cloud_secrets.dart';

/// A database restored from the cloud, waiting for the next launch to take its
/// place.
///
/// The running till holds pos.db open, so a restore cannot replace it in place.
/// It is written beside it instead, and [apply] swaps it in at start-up, before
/// anything opens the database. The database it replaces is renamed, never
/// deleted, and its key is kept in the keychain, so a restore picked by mistake
/// can still be undone by support.
class PendingRestore {
  PendingRestore(this.databasePath, this.secrets);

  final String databasePath;
  final CloudSecrets secrets;

  static const String restoreKeySecret = 'restore_db_key';
  static const String previousKeySecret = 'db_key_before_restore';

  String get _staged => '$databasePath.restore';

  bool get isStaged => File(_staged).existsSync();

  /// Write [database] to sit beside the live one until the next launch.
  Future<void> stage(Uint8List database, {String? databaseKey}) async {
    final part = File('$_staged.part');
    await part.writeAsBytes(database, flush: true);
    await secrets.write(restoreKeySecret, databaseKey);
    await part.rename(_staged);
  }

  Future<void> cancel() async {
    final staged = File(_staged);
    if (staged.existsSync()) await staged.delete();
    await secrets.write(restoreKeySecret, null);
  }

  /// Swap a staged restore in. Returns where the replaced database went, or null
  /// when nothing was staged.
  Future<String?> apply(KeyStore databaseKeys, {DateTime? at}) async {
    final staged = File(_staged);
    if (!staged.existsSync()) return null;

    final restoredKey = await secrets.read(restoreKeySecret);
    if (restoredKey != null && restoredKey.isNotEmpty) {
      final current = await databaseKeys.read();
      if (current != null && current.isNotEmpty) {
        await secrets.write(previousKeySecret, current);
      }
      await databaseKeys.write(restoredKey);
    }

    final stamp = (at ?? DateTime.now())
        .toIso8601String()
        .replaceAll(RegExp(r'[:.]'), '-');
    final kept = '$databasePath.before-restore-$stamp';
    for (final suffix in const ['', '-wal', '-shm']) {
      final live = File('$databasePath$suffix');
      if (live.existsSync()) await live.rename('$kept$suffix');
    }
    await staged.rename(databasePath);
    await secrets.write(restoreKeySecret, null);
    return kept;
  }
}
