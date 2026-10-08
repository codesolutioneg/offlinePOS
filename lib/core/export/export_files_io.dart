import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// The user's Downloads directory when the platform has one, else the app
/// documents directory. Downloads is null on mobile and can throw on platforms
/// without the notion, so both are handled.
///
/// Public because everything a till hands to a human lands in the same place: a CSV,
/// a PDF and the database backup all have to be findable by the same instruction
/// over the phone.
Future<Directory> exportDirectory() async {
  try {
    final downloads = await getDownloadsDirectory();
    if (downloads != null) return downloads;
  } catch (_) {
    // Fall through to app documents below.
  }
  return getApplicationDocumentsDirectory();
}

/// Writes [content] to [fileName] under the export directory and returns the
/// absolute path, so the caller can tell the user where the file landed.
Future<String> writeTextExport(String fileName, String content) async {
  final dir = await exportDirectory();
  final file = File('${dir.path}${Platform.pathSeparator}$fileName');
  await file.writeAsString(content);
  return file.path;
}

/// Writes [bytes] (e.g. a PDF) to [fileName] under the export directory and
/// returns the absolute path.
Future<String> writeBytesExport(String fileName, List<int> bytes) async {
  final dir = await exportDirectory();
  final file = File('${dir.path}${Platform.pathSeparator}$fileName');
  await file.writeAsBytes(bytes);
  return file.path;
}
