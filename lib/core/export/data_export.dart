import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'export_header.dart';

/// Turns a table of rows into a downloadable file the user can actually open.
///
/// Kept independent of any one screen so the audit log and the reports share the
/// same CSV/escaping and the same "where did it save" behaviour. The pure string
/// builders ([csvField], [buildCsv], [exportFileName]) carry no file IO so they
/// can be unit-tested without a platform channel.

/// Escapes a single CSV field per RFC 4180: a value containing a comma, quote or
/// line break is wrapped in quotes with any inner quote doubled, so a product
/// name like `Fish, chips & "mushy" peas` survives a round-trip into Excel.
String csvField(String value) {
  if (value.contains(',') ||
      value.contains('"') ||
      value.contains('\n') ||
      value.contains('\r')) {
    return '"${value.replaceAll('"', '""')}"';
  }
  return value;
}

/// A CSV document: the [header] row followed by one line per row in [rows].
///
/// With a [head] the document opens with the report's name and the shop/period/who
/// block, then a blank line, then the table. Spreadsheets read that as leading
/// one-column rows, which is exactly how a printed report reads too.
String buildCsv(List<String> header, List<List<String>> rows,
    {ExportHeader? head}) {
  final lines = <String>[];
  if (head != null) {
    lines.add(csvField(head.title));
    for (final (label, value) in head.lines) {
      lines.add('${csvField(label)},${csvField(value)}');
    }
    lines.add('');
  }
  lines.add(header.map(csvField).join(','));
  for (final r in rows) {
    lines.add(r.map(csvField).join(','));
  }
  return lines.join('\n');
}

/// `<name>-<yyyymmdd-hhmm>.<ext>`, e.g. `report-sales-20260814-0930.csv`. The
/// timestamp is passed in by the caller so the file name is deterministic and
/// this stays free of `DateTime.now()`.
String exportFileName(String name, DateTime at, String ext) {
  String two(int n) => n.toString().padLeft(2, '0');
  final stamp = '${at.year}${two(at.month)}${two(at.day)}'
      '-${two(at.hour)}${two(at.minute)}';
  return '$name-$stamp.$ext';
}

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
