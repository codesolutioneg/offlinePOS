import 'package:flutter/material.dart';

import '../../core/export/data_export.dart';
import '../../core/i18n/l10n.dart';

/// The one CSV download used by the individual report screens.
///
/// The hub exports the order table; each report has its own shape, and without a
/// shared helper every screen would grow its own copy of the write-and-tell-the-user
/// dance. [name] is the file stem, e.g. 'report-expenses'.
Future<void> downloadReportCsv(
  BuildContext context, {
  required String name,
  required List<String> header,
  required List<List<String>> rows,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  final saved = tr(context, 'Saved to');
  final failed = tr(context, 'Could not save file');
  try {
    final path = await writeTextExport(
      exportFileName(name, DateTime.now(), 'csv'),
      buildCsv(header, rows),
    );
    messenger.showSnackBar(SnackBar(content: Text('$saved: $path')));
  } catch (_) {
    messenger.showSnackBar(SnackBar(content: Text(failed)));
  }
}

/// The download action every report puts in its app bar, so the icon, tooltip and
/// key are identical wherever a manager looks for it.
IconButton reportCsvAction(BuildContext context, {required VoidCallback onPressed}) =>
    IconButton(
      key: const Key('report-csv'),
      tooltip: tr(context, 'Download CSV'),
      icon: const Icon(Icons.download),
      onPressed: onPressed,
    );
