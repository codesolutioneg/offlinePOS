import 'rm_layout.dart';

/// The words the page heading is set in, already in the language on screen.
class RmPageLabels {
  const RmPageLabels({
    this.date = 'Date',
    this.time = 'Time',
    this.page = 'Page',
    this.session = 'Session #',
    this.filterSettings = 'Filter Settings',
    this.am = 'AM',
    this.pm = 'PM',
  });

  final String date;
  final String time;
  final String page;
  final String session;
  final String filterSettings;
  final String am;
  final String pm;
}

/// Puts the heading a report page opens with on [items] and answers where the
/// page's own content starts: the date and time on one side, the shop and the
/// report in the middle, the page on the other, then the session. The first
/// page also says what the report was narrowed to.
double putRmPageHeading(
  List<RmPlaced> items, {
  required int page,
  required double pageWidth,
  required String shop,
  required String title,
  required String period,
  required String filter,
  required DateTime ranAt,
  RmPageLabels labels = const RmPageLabels(),
}) {
  const margin = 36.0;
  final right = pageWidth - margin;
  final width = right - margin;
  var y = margin;

  void put(String text, double x, double w,
      {bool bold = false,
      bool underline = false,
      double size = 10,
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

  String two(int n) => n.toString().padLeft(2, '0');
  final at = ranAt.toLocal();
  final date = '${at.year}-${two(at.month)}-${two(at.day)}';
  final hour = at.hour % 12 == 0 ? 12 : at.hour % 12;
  final time = '$hour:${two(at.minute)} ${at.hour < 12 ? labels.am : labels.pm}';

  put('${labels.date}:', margin, 50, bold: true);
  put(date, margin + 54, 90);
  put('${labels.time}:', margin, 50, bold: true, at: y + 16);
  put(time, margin + 54, 90, at: y + 16);
  if (shop.isNotEmpty) {
    put(shop, margin + 150, width - 300, bold: true, size: 15, justify: 1);
  }
  put(title, margin + 110, width - 220,
      bold: true, size: 15, justify: 1, at: y + (shop.isEmpty ? 0 : 22));
  put('${labels.page}:', right - 110, 50, bold: true);
  put('${page + 1}', right - 56, 56, justify: 2);
  y += 46;
  put('${labels.session}:', margin, 80, bold: true);
  put(period, margin + 84, width - 84);
  y += 22;
  if (page == 0) {
    put(labels.filterSettings, margin, 160, bold: true, underline: true);
    y += 16;
    put(filter, margin + 16, width - 16);
    y += 26;
  } else {
    y += 6;
  }
  return y;
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
  String Function(String text)? translate,
}) {
  const margin = 36.0;
  const line = 14.0;
  // The table keeps its English words, which the export writes; only what is
  // drawn on the page is put into the reader's language.
  final tx = translate ?? (String s) => s;

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

  final justify = [
    for (var i = 0; i < columns.length; i++) figures(i) ? 2 : 0,
  ];

  // The longest thing each column has to hold, in characters.
  final chars = <int>[
    for (var i = 0; i < columns.length; i++)
      [
        columns[i].length,
        for (final row in rows)
          if (i < cellsOf(row).length) cellsOf(row)[i].trim().length,
      ].fold<int>(3, (a, b) => b > a ? b : a),
  ];

  /// The room the table wants across the page when set in [size].
  double natural(double size) =>
      chars.fold<double>(0, (sum, c) => sum + c * size * 0.56 + 10);

  // A table too wide for an upright page turns the page on its side, and one
  // too wide even for that is set smaller, down to what is still readable.
  var landscape = false;
  var bodySize = 9.5;
  if (natural(bodySize) > 595.0 - 2 * margin) {
    landscape = true;
    for (final size in const [9.5, 8.5, 7.5, 7.0]) {
      bodySize = size;
      if (natural(size) <= 842.0 - 2 * margin) break;
    }
  }
  final pageWidth = landscape ? 842.0 : 595.0;
  final pageHeight = landscape ? 595.0 : 842.0;
  final right = pageWidth - margin;
  final width = right - margin;

  final items = <RmPlaced>[];
  var page = 0;
  var y = margin;

  void put(String text, double x, double w,
      {double? size,
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
        fontSize: size ?? bodySize,
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

  // The heading every page opens with. The first also says what it was
  // narrowed to.
  void heading() {
    y = putRmPageHeading(
      items,
      page: page,
      pageWidth: pageWidth,
      shop: shop,
      title: title,
      period: period,
      filter: filter,
      ranAt: ranAt,
      labels: labels,
    );
  }

  void newPage() {
    page++;
    heading();
  }

  // Each column as wide as what it has to hold. Where even the smallest setting
  // is too wide, the figures keep their room and the text columns share what
  // is left, cut short where they have to be.
  final wide = <double>[for (final c in chars) c * bodySize * 0.56 + 10];
  var total = wide.fold<double>(0, (a, b) => a + b);
  if (total > width) {
    final texts = [
      for (var i = 0; i < wide.length; i++)
        if (justify[i] == 0) i,
    ];
    final fixed = total - texts.fold<double>(0, (a, i) => a + wide[i]);
    if (texts.isEmpty || fixed >= width) {
      for (var i = 0; i < wide.length; i++) {
        wide[i] = wide[i] * width / total;
      }
    } else {
      final share = width - fixed;
      final wanted = texts.fold<double>(0, (a, i) => a + wide[i]);
      for (final i in texts) {
        wide[i] = wide[i] * share / wanted;
      }
    }
    total = width;
  } else if (total < 220) {
    // A narrow table is given room to read as a list rather than a column.
    for (var i = 0; i < wide.length; i++) {
      wide[i] = wide[i] * 220 / total;
    }
    total = 220;
  }
  final tableWidth = total;
  final left = <double>[];
  var x = margin;
  for (final w in wide) {
    left.add(x);
    x += w;
  }

  void titles() {
    for (var i = 0; i < columns.length; i++) {
      put(tx(columns[i]), left[i] + 3, wide[i] - 6, justify: justify[i]);
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
        put(tx(cells[i]), left[i] + 3, wide[i] - 6, justify: justify[i]);
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
      put(tx(section), margin, tableWidth, bold: true, size: 12, justify: 1);
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
