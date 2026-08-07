import 'dart:io';

/// Where a downloaded build lives between being verified and being installed.
///
/// Read and delete are part of the contract, not conveniences. The gate holds a
/// verified build until the shop closes, so hours can pass between the digest
/// check and the install, and the file has to be re-read and re-checked at the
/// moment it is handed over. Delete exists so a build the server withdraws does
/// not sit on the till waiting for someone to install it by hand.
abstract interface class UpdateStorage {
  /// Writes [bytes] under [fileName] and returns where they landed.
  Future<String> save(String fileName, List<int> bytes);

  Future<List<int>> read(String path);

  /// Removing something already gone is not an error.
  Future<void> delete(String path);
}

/// Staging on the local filesystem, in a directory only this app can write.
///
/// The directory matters as much as the bytes. A staged build in a shared or
/// world-writable location can be swapped for another one during the hours the
/// gate holds it, and the till would install the replacement believing it had
/// checked it. Hand this the app's private support directory, never external or
/// shared storage.
class FileUpdateStorage implements UpdateStorage {
  FileUpdateStorage(this.directory);

  /// App-private. Created on first use with owner-only permissions where the
  /// platform honours them.
  final Directory directory;

  @override
  Future<String> save(String fileName, List<int> bytes) async {
    await directory.create(recursive: true);
    final file = File('${directory.path}${Platform.pathSeparator}$fileName');
    await file.writeAsBytes(bytes, flush: true);
    if (!Platform.isWindows) {
      // Owner only. Another app or another user on the machine must not be able
      // to rewrite a build this till has already verified.
      await Process.run('chmod', ['600', file.path]);
    }
    return file.path;
  }

  @override
  Future<List<int>> read(String path) => File(path).readAsBytes();

  @override
  Future<void> delete(String path) async {
    final file = File(path);
    if (await file.exists()) await file.delete();
  }
}
