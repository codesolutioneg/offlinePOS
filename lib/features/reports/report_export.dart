import 'package:flutter/material.dart';

import '../../core/export/data_export.dart';
import '../../core/export/export_header.dart';
import '../../core/export/pdf_export.dart';
import '../../core/export/xlsx_export.dart';
import '../../core/i18n/l10n.dart';

/// One report reduced to the shape every export renders: a column header and its
/// rows, all as strings. Built lazily at the moment a download is picked, so
/// nothing is computed for a report the manager only looks at.
class ReportTable {
  const ReportTable({required this.header, required this.rows});

  final List<String> header;
  final List<List<String>> rows;
}

/// Who and what the reports under it belong to, so every download carries a proper
/// header without eighteen screens each growing three more constructor arguments.
///
/// An inherited widget rather than a parameter because the report screens are
/// pushed as their own routes: the hub wraps the page it pushes, and the report
/// inside reads the shop, the period and the cashier off it. A report opened
/// outside the hub simply falls back to a bare header.
class ReportScope extends InheritedWidget {
  const ReportScope({
    super.key,
    required this.shopName,
    required this.periodLabel,
    required this.ranBy,
    required super.child,
  });

  final String shopName;

  /// The range the hub is filtered to, e.g. "Today" or "8/1 - 8/14".
  final String periodLabel;

  /// The cashier who is looking at it.
  final String ranBy;

  static ReportScope? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ReportScope>();

  @override
  bool updateShouldNotify(ReportScope old) =>
      shopName != old.shopName ||
      periodLabel != old.periodLabel ||
      ranBy != old.ranBy;
}

/// The header block for [title], from the scope above [context] and the clock.
ExportHeader reportHeader(BuildContext context, String title) {
  final scope = ReportScope.of(context);
  return ExportHeader(
    title: title,
    lines: [
      if (scope != null && scope.shopName.isNotEmpty)
        (tr(context, 'Shop'), scope.shopName),
      (tr(context, 'Report'), title),
      if (scope != null && scope.periodLabel.isNotEmpty)
        (tr(context, 'Period'), scope.periodLabel),
      if (scope != null && scope.ranBy.isNotEmpty)
        (tr(context, 'Run by'), scope.ranBy),
      (tr(context, 'Generated'), exportStamp(DateTime.now())),
    ],
  );
}

/// The download menu every report puts in its app bar, so the icon, the formats and
/// the key are identical wherever a manager looks for it. [name] is the file stem,
/// e.g. 'report-expenses'; [title] is the report's own name, already translated.
///
/// Excel and PDF are what the shop asked for. CSV stays on the menu because it is
/// what an accountant's own tooling imports, and it costs one line to keep.
PopupMenuButton<String> reportExportAction(
  BuildContext context, {
  required String name,
  required String title,
  required ReportTable Function() table,
}) =>
    PopupMenuButton<String>(
      key: const Key('report-export'),
      tooltip: tr(context, 'Download'),
      icon: const Icon(Icons.download),
      onSelected: (format) =>
          downloadReport(context, name: name, title: title, table: table(), format: format),
      itemBuilder: (ctx) => [
        PopupMenuItem(
          key: const Key('export-xlsx'),
          value: 'xlsx',
          child: Text(tr(ctx, 'Excel')),
        ),
        PopupMenuItem(
          key: const Key('export-pdf'),
          value: 'pdf',
          child: Text(tr(ctx, 'PDF')),
        ),
        PopupMenuItem(
          key: const Key('export-csv'),
          value: 'csv',
          child: Text(tr(ctx, 'CSV')),
        ),
      ],
    );

/// Writes one report to the export directory in [format] and tells the user where
/// it landed, or that it could not be saved. Never throws at the caller: a report
/// that will not save is a message, not a crash on a till.
Future<void> downloadReport(
  BuildContext context, {
  required String name,
  required String title,
  required ReportTable table,
  required String format,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  final saved = tr(context, 'Saved to');
  final failed = tr(context, 'Could not save file');
  final head = reportHeader(context, title);
  final file = exportFileName(name, DateTime.now(), format);
  try {
    final path = switch (format) {
      'pdf' => await writeBytesExport(
          file, await buildPdfTable(title, table.header, table.rows, head: head)),
      'xlsx' => await writeBytesExport(
          file,
          buildXlsxTable(table.header, table.rows, head: head) ??
              (throw StateError('workbook not encoded'))),
      _ => await writeTextExport(
          file, buildCsv(table.header, table.rows, head: head)),
    };
    messenger.showSnackBar(SnackBar(content: Text('$saved: $path')));
  } catch (_) {
    messenger.showSnackBar(SnackBar(content: Text(failed)));
  }
}
