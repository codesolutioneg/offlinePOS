import 'package:flutter/material.dart';

import '../../../core/export/data_export.dart';
import '../../../core/i18n/l10n.dart';
import '../report_export.dart';
import 'rm_layout.dart';
import 'rm_pdf.dart';
import 'rm_report_viewer.dart';
import 'rm_table_page.dart';
import 'thermal_report.dart';

/// Opens [child] in a window over the screen behind it, the way the back office
/// opens a report over its report list.
Future<void> showReportWindow(BuildContext context, Widget child) =>
    showDialog<void>(
      context: context,
      builder: (_) => Dialog(
        insetPadding: const EdgeInsets.all(28),
        shape: const RoundedRectangleBorder(
            side: BorderSide(color: Color(0xFF707070))),
        clipBehavior: Clip.hardEdge,
        // The whole of the room the dialog is given: a report is a window, not
        // a box sized to whatever happens to be in it.
        child: SizedBox.expand(child: child),
      ),
    );

/// One of the till's own reports, drawn as a back-office page.
///
/// The report is built out of sight so it can say what its table is (see
/// [ReportScope.onTable]); the window then lays that table out as a page and
/// shows the page instead. A report that announces no table is shown as the
/// screen it always was, so nothing is ever a blank window.
class ReportWindow extends StatefulWidget {
  const ReportWindow({
    super.key,
    required this.shopName,
    required this.periodLabel,
    required this.ranBy,
    required this.filter,
    required this.report,
    this.onPrint,
  });

  /// Prints the report on the receipt printer. Null leaves the window without
  /// its thermal button.
  final Future<void> Function(ThermalReport report)? onPrint;

  final String shopName;
  final String periodLabel;
  final String ranBy;

  /// What the report was narrowed to, in words.
  final String filter;
  final Widget report;

  @override
  State<ReportWindow> createState() => _ReportWindowState();
}

class _ReportWindowState extends State<ReportWindow> {
  String? _name;
  String? _title;
  ReportTable? _table;
  RmDocument? _document;

  /// Set once the report has built without announcing a table.
  bool _asScreen = false;
  bool _announced = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_announced) setState(() => _asScreen = true);
    });
  }

  void _onTable(String name, String title, ReportTable Function() table) {
    if (_announced) return;
    _announced = true;
    // Told in the middle of the report's own build, so the page waits a frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final built = table();
      setState(() {
        _name = name;
        _title = title;
        _table = built;
        _document = layOutReportTable(
          shop: widget.shopName,
          title: title,
          period: widget.periodLabel,
          filter: widget.filter,
          ranAt: DateTime.now(),
          header: built.header,
          rows: built.rows,
          labels: RmPageLabels(
            date: tr(context, 'Date'),
            time: tr(context, 'Time'),
            page: tr(context, 'Page'),
            session: tr(context, 'Session #'),
            filterSettings: tr(context, 'Filter Settings'),
            am: tr(context, 'AM'),
            pm: tr(context, 'PM'),
          ),
          translate: (s) => tr(context, s),
        );
      });
    });
  }

  Future<void> _print(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final sent = tr(context, 'Sent to the receipt printer');
    final held = tr(context, 'Printer offline — job held');
    final none = tr(context, 'No receipt printer configured');
    final table = _table!;
    final report = ThermalReport(
      title: _title!,
      period: widget.periodLabel,
      filter: widget.filter,
      header: table.header,
      rows: table.rows,
      dateLabel: tr(context, 'Date/time'),
      filterLabel: tr(context, 'Report filter'),
    );
    try {
      await widget.onPrint!(report);
      messenger.showSnackBar(SnackBar(content: Text(sent)));
    } catch (e) {
      final raw = '$e';
      messenger.showSnackBar(SnackBar(
        content: Text(raw.contains('Printer offline')
            ? held
            : raw.contains('No receipt printer')
                ? none
                : raw),
      ));
    }
  }

  /// Excel and CSV are the table as it always exported; the PDF is the page.
  Future<void> _download(BuildContext context, String format) async {
    final name = _name!;
    final title = _title!;
    if (format != 'pdf') {
      return downloadReport(context,
          name: name, title: title, table: _table!, format: format);
    }
    final messenger = ScaffoldMessenger.of(context);
    final saved = tr(context, 'Saved to');
    final failed = tr(context, 'Could not save file');
    try {
      final path = await writeBytesExport(
          exportFileName(name, DateTime.now(), 'pdf'),
          await buildRmPdf(_document!));
      messenger.showSnackBar(SnackBar(content: Text('$saved: $path')));
    } catch (_) {
      messenger.showSnackBar(SnackBar(content: Text(failed)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final document = _document;
    return ReportScope(
      shopName: widget.shopName,
      periodLabel: widget.periodLabel,
      ranBy: widget.ranBy,
      onTable: _onTable,
      child: Stack(children: [
        Offstage(offstage: !_asScreen, child: widget.report),
        if (document != null)
          Positioned.fill(
            // Under the scope, so a download is headed like any other.
            child: Builder(
              builder: (context) => RmReportViewer(
                title: _title ?? '',
                document: document,
                onPrint: widget.onPrint == null ? null : () => _print(context),
                export: Builder(
                  // Under the viewer's own scaffold, which is where the
                  // message saying where the file went has to show.
                  builder: (context) => PopupMenuButton<String>(
                    key: const Key('report-export'),
                    tooltip: tr(context, 'Download'),
                    icon:
                        const Icon(Icons.save, size: 20, color: Colors.black87),
                    onSelected: (format) => _download(context, format),
                    itemBuilder: (ctx) => [
                      for (final (format, label) in const [
                        ('xlsx', 'Excel'),
                        ('pdf', 'PDF'),
                        ('csv', 'CSV'),
                      ])
                        PopupMenuItem(
                          key: Key('export-$format'),
                          value: format,
                          child: Text(tr(ctx, label)),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ]),
    );
  }
}
