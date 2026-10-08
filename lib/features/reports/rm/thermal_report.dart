/// One of the till's reports as the receipt printer is handed it.
class ThermalReport {
  const ThermalReport({
    required this.title,
    required this.period,
    required this.filter,
    required this.header,
    required this.rows,
    this.dateLabel = 'Date/time',
    this.filterLabel = 'Report filter',
  });

  final String title;

  /// The session or range it covers, printed under the title.
  final String period;

  /// What it was narrowed to, in words.
  final String filter;
  final List<String> header;
  final List<List<String>> rows;

  /// The two heading labels, already in the language on screen.
  final String dateLabel;
  final String filterLabel;
}

/// One printed line of a report's table.
class ThermalLine {
  const ThermalLine(this.text, {this.bold = false, this.center = false});

  final String text;
  final bool bold;
  final bool center;
}

/// A report's table set for a receipt roll [width] characters wide, the way the
/// back office sets its forty-column reports: the column titles, a rule under
/// them, then a line per row with its text on the left and its figures lined up
/// on the right.
///
/// A table whose first column is `Section` prints each section under its own
/// centred title with the titles and the rule repeated, as the page does.
List<ThermalLine> thermalTableLines(
  List<String> header,
  List<List<String>> rows,
  int width,
) {
  final sectioned = header.isNotEmpty && header.first == 'Section';
  final columns = sectioned ? header.sublist(1) : header;
  if (columns.isEmpty) return const [];
  List<String> cellsOf(List<String> row) => sectioned ? row.sublist(1) : row;

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

  final right = [for (var i = 0; i < columns.length; i++) figures(i)];

  // Each column as wide as the longest thing in it, a space between columns.
  final want = <int>[
    for (var i = 0; i < columns.length; i++)
      [
        columns[i].length,
        for (final row in rows)
          if (i < cellsOf(row).length) cellsOf(row)[i].trim().length,
      ].fold<int>(3, (a, b) => b > a ? b : a),
  ];
  final gaps = columns.length - 1;
  final room = width - gaps;
  final widths = List<int>.of(want);
  final total = want.fold<int>(0, (a, b) => a + b);
  if (total <= room) {
    // The first column takes what is left, so the figures sit at the edge.
    widths[0] += room - total;
  } else {
    // Too much for the roll: the figures keep their width and the text columns
    // share what remains, cut short where they have to be.
    final fixed = [
      for (var i = 0; i < want.length; i++)
        if (right[i]) want[i],
    ].fold<int>(0, (a, b) => a + b);
    final texts = [
      for (var i = 0; i < want.length; i++)
        if (!right[i]) i,
    ];
    if (texts.isEmpty || fixed >= room) {
      for (var i = 0; i < widths.length; i++) {
        widths[i] = (want[i] * room / total).floor().clamp(1, room);
      }
    } else {
      final share = room - fixed;
      final wanted = texts.fold<int>(0, (a, i) => a + want[i]);
      var used = 0;
      for (final i in texts) {
        widths[i] = (want[i] * share / wanted).floor().clamp(1, share);
        used += widths[i];
      }
      widths[texts.first] += share - used;
    }
  }

  String fit(String value, int i) {
    final text = value.trim();
    final cut = text.length > widths[i] ? text.substring(0, widths[i]) : text;
    return right[i] ? cut.padLeft(widths[i]) : cut.padRight(widths[i]);
  }

  String line(List<String> cells) => [
        for (var i = 0; i < columns.length; i++)
          fit(i < cells.length ? cells[i] : '', i),
      ].join(' ').trimRight();

  final out = <ThermalLine>[];

  // A table with more columns than a roll can set side by side is printed a
  // record at a time instead: what the row is on a line of its own, then each
  // of its other columns as a label with its value at the far edge.
  final stacked = columns.length > 4 && total > room;
  String pair(String label, String value) {
    final l = label.trim();
    final v = value.trim();
    final space = width - l.length - v.length;
    if (space >= 1) return '$l${' ' * space}$v';
    final cut = '$l $v';
    return cut.length > width ? cut.substring(0, width) : cut;
  }

  void records(List<List<String>> lines) {
    for (final row in lines) {
      final cells = cellsOf(row);
      out.add(ThermalLine(
          pair(columns.first, cells.isEmpty ? '' : cells.first),
          bold: true));
      for (var i = 1; i < columns.length && i < cells.length; i++) {
        if (cells[i].trim().isEmpty) continue;
        out.add(ThermalLine(pair(columns[i], cells[i])));
      }
      out.add(ThermalLine('-' * width));
    }
  }

  void table(List<List<String>> lines) {
    if (stacked) return records(lines);
    out
      ..add(ThermalLine(line(columns)))
      ..add(ThermalLine('-' * width));
    for (final row in lines) {
      out.add(ThermalLine(line(cellsOf(row))));
    }
  }

  if (!sectioned) {
    table(rows);
    return out;
  }
  final sections = <String>[];
  for (final row in rows) {
    if (row.isNotEmpty && !sections.contains(row.first)) sections.add(row.first);
  }
  for (final section in sections) {
    out
      ..add(const ThermalLine(''))
      ..add(ThermalLine(section, bold: true, center: true));
    table([
      for (final row in rows)
        if (row.isNotEmpty && row.first == section) row,
    ]);
  }
  return out;
}
