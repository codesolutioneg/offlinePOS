import 'rm_layout.dart';

/// The words the page heading is set in, already in the language on screen.
class RmPageLabels {
  const RmPageLabels({
    this.date = 'Date',
    this.time = 'Time',
    this.page = 'Page',
    this.session = 'Session #',
    this.filterSettings = 'Filter Settings',
  });

  final String date;
  final String time;
  final String page;
  final String session;
  final String filterSettings;
}

/// Lays one of the till's own reports out as a back-office page: the date and
/// time on one side, the shop and the report in the middle, the page on the
/// other, the session and the filter under them, and then the table, ruled under
/// its column titles with its figures on the right.
///
/// A table whose first column is `Section` is drawn as one small table per
/// section, each under its own centred title, which is how a session summary
/// reads.
RmDocument layOutReportTable({
  required String shop,
  required String title,
  required String period,
  required String filter,
  required DateTime ranAt,
  required List<String> header,
  required List<List<String>> rows,
  RmPageLabels labels = const RmPageLabels(),
}) {
  const pageWidth = 595.0;
  const pageHeight = 842.0;
  const margin = 36.0;
  const line = 14.0;
  const right = pageWidth - margin;
  const width = right - margin;

  final items = <RmPlaced>[];
  var page = 0;
  var y = margin;

  void put(String text, double x, double w,
      {double size = 9.5,
      bool bold = false,
      bool underline = false,
      int justify = 0,
      double? at}) {
    items.add(RmPlaced(
      page: page,
      x: x,
      y: at ?? y,
      width: w,
      text: text,
      cell: RmCell(
        kind: RmKind.text,
        row: 0,
        column: 0,
        length: 0,
        fontSize: size,
        justify: justify,
        bold: bold,
        underline: underline,
      ),
    ));
  }

  void rule(double x, double w) => items.add(RmPlaced(
        page: page,
        x: x,
        y: y - 6,
        width: w,
        text: '',
        cell: const RmCell(
          kind: RmKind.rule,
          row: 0,
          column: 0,
          length: 0,
          fontSize: 9,
          justify: 0,
        ),
      ));

  String two(int n) => n.toString().padLeft(2, '0');
  final at = ranAt.toLocal();
  final date = '${at.year}-${two(at.month)}-${two(at.day)}';
  final hour = at.hour % 12 == 0 ? 12 : at.hour % 12;
  final time = '$hour:${two(at.minute)} ${at.hour < 12 ? 'AM' : 'PM'}';

  // The heading every page opens with. The first also says what it was
  // narrowed to.
  void heading() {
    y = margin;
    put('${labels.date}:', margin, 50, bold: true, size: 10);
    put(date, margin + 54, 90, size: 10);
    put('${labels.time}:', margin, 50, bold: true, size: 10, at: y + 16);
    put(time, margin + 54, 90, size: 10, at: y + 16);
    if (shop.isNotEmpty) {
      put(shop, margin + 150, width - 300, bold: true, size: 15, justify: 1);
    }
    put(title, margin + 110, width - 220,
        bold: true, size: 15, justify: 1, at: y + (shop.isEmpty ? 0 : 22));
    put('${labels.page}:', right - 110, 50, bold: true, size: 10);
    put('${page + 1}', right - 56, 56, size: 10, justify: 2);
    y += 46;
    put('${labels.session}:', margin, 80, bold: true, size: 10);
    put(period, margin + 84, width - 84, size: 10);
    y += 22;
    if (page == 0) {
      put(labels.filterSettings, margin, 160,
          bold: true, underline: true, size: 10);
      y += 16;
      put(filter, margin + 16, width - 16, size: 10);
      y += 26;
    } else {
      y += 6;
    }
  }

  void newPage() {
    page++;
    heading();
  }

  final sectioned = header.isNotEmpty && header.first == 'Section';
  final columns = sectioned ? header.sublist(1) : header;
  List<String> cellsOf(List<String> row) => sectioned ? row.sublist(1) : row;

  // A column of figures lines up on its last digit.
  final figure = RegExp(r'^[-+]?[\d,]*\.?\d+%?$');
  bool figures(int column) {
    var any = false;
    for (final row in rows) {
      final cells = cellsOf(row);
      if (column >= cells.length) continue;
      final value = cells[column].trim();
      if (value.isEmpty) continue;
      if (!figure.hasMatch(value)) return false;
      any = true;
    }
    return any;
  }

  // Each column as wide as what it has to hold, shared out over the page.
  final weights = <double>[
    for (var i = 0; i < columns.length; i++)
      [
        columns[i].length,
        for (final row in rows)
          if (i < cellsOf(row).length) cellsOf(row)[i].length,
      ].fold<int>(6, (a, b) => b > a ? b : a).clamp(6, 40).toDouble(),
  ];
  final total = weights.fold<double>(0, (a, b) => a + b);
  // A narrow table does not stretch across the page: it reads as a list.
  final tableWidth = (total * 7).clamp(220.0, width).toDouble();
  final left = <double>[];
  final wide = <double>[];
  var x = margin;
  for (final w in weights) {
    left.add(x);
    wide.add(tableWidth * w / total);
    x += tableWidth * w / total;
  }
  final justify = [
    for (var i = 0; i < columns.length; i++) figures(i) ? 2 : 0,
  ];

  void titles() {
    for (var i = 0; i < columns.length; i++) {
      put(columns[i], left[i] + 3, wide[i] - 6, justify: justify[i]);
    }
    y += line + 3;
    rule(margin, tableWidth);
    y += 5;
  }

  void body(List<List<String>> lines) {
    for (final row in lines) {
      if (y + line > pageHeight - margin) {
        newPage();
        titles();
      }
      final cells = cellsOf(row);
      for (var i = 0; i < columns.length && i < cells.length; i++) {
        put(cells[i], left[i] + 3, wide[i] - 6, justify: justify[i]);
      }
      y += line;
    }
  }

  heading();
  if (sectioned) {
    final sections = <String>[];
    for (final row in rows) {
      if (row.isNotEmpty && !sections.contains(row.first)) sections.add(row.first);
    }
    for (final section in sections) {
      final lines = [
        for (final row in rows)
          if (row.isNotEmpty && row.first == section) row,
      ];
      // A section starts where its title and first lines can stay together.
      if (y + 3 * line + 30 > pageHeight - margin) newPage();
      put(section, margin, tableWidth, bold: true, size: 12, justify: 1);
      y += 18;
      titles();
      body(lines);
      y += 22;
    }
  } else {
    titles();
    body(rows);
  }

  return RmDocument(
    items: items,
    pages: page + 1,
    pageWidth: pageWidth,
    pageHeight: pageHeight,
  );
}
