import 'dart:convert';

/// What one cell of a report layout is.
enum RmKind { text, field, system, rule }

/// One piece of a band: where it sits on the band's grid, how it is set, and
/// what it shows.
class RmCell {
  const RmCell({
    required this.kind,
    required this.row,
    required this.column,
    required this.length,
    required this.fontSize,
    required this.justify,
    this.bold = false,
    this.underline = false,
    this.italic = false,
    this.value = '',
    this.format = 0,
  });

  factory RmCell.fromJson(Map<String, dynamic> j) => RmCell(
        kind: switch (j['k']) {
          'v' => RmKind.field,
          's' => RmKind.system,
          'l' => RmKind.rule,
          _ => RmKind.text,
        },
        row: j['r'] as int,
        column: j['c'] as int,
        length: j['n'] as int,
        fontSize: (j['fs'] as int).toDouble(),
        justify: j['j'] as int,
        bold: j['b'] == 1,
        underline: j['u'] == 1,
        italic: j['i'] == 1,
        value: (j['x'] as String?) ?? '',
        format: (j['f'] as int?) ?? 0,
      );

  final RmKind kind;
  final int row;
  final int column;
  final int length;
  final double fontSize;

  /// 0 left, 1 centre, 2 right.
  final int justify;
  final bool bold;
  final bool underline;
  final bool italic;

  /// The text itself, the field's name, or the system value's number.
  final String value;

  /// How a field's value is written: 0 as it is, 1 as money, 2 as a number.
  final int format;
}

/// One level of a report's data and the three bands drawn for it: once above
/// its rows, once per row, once below them.
class RmBandSet {
  const RmBandSet({
    required this.what,
    required this.header,
    required this.details,
    required this.summary,
    this.landscape = false,
  });

  factory RmBandSet.fromJson(Map<String, dynamic> j) {
    List<RmCell> band(String name) => [
          for (final c in (j[name] as List? ?? const []))
            RmCell.fromJson((c as Map).cast<String, dynamic>()),
        ];
    return RmBandSet(
      what: j['what'] as String,
      header: band('header'),
      details: band('details'),
      summary: band('summary'),
      landscape: j['landscape'] == 1,
    );
  }

  /// The dotted path of the data this level is: `Sales.Orders`.
  final String what;
  final List<RmCell> header;
  final List<RmCell> details;
  final List<RmCell> summary;
  final bool landscape;
}

/// A field the report works out, rows it leaves out, or fields it totals.
class RmRule {
  const RmRule({
    required this.name,
    this.on = '',
    this.field = '',
    this.tokens = const [],
    this.sum = const [],
  });

  factory RmRule.fromJson(Map<String, dynamic> j) => RmRule(
        name: j['name'] as String,
        on: (j['on'] as String?) ?? '',
        field: (j['field'] as String?) ?? '',
        tokens: [
          for (final t in (j['tokens'] as List? ?? const []))
            ((t as List)[0] as int, t[1] as String),
        ],
        sum: [for (final f in (j['sum'] as List? ?? const [])) f as String],
      );

  /// `Compute`, `Filter`, and the rest of the vendor's rule names.
  final String name;

  /// The level of the data it applies to.
  final String on;

  /// The field a Compute rule makes.
  final String field;

  /// The expression, in order: 0 a field, 1 an operator, 2 a constant.
  final List<(int, String)> tokens;
  final List<String> sum;

  /// The expression as it reads: `Cash tips / CC Sales * 100`.
  String get expression => [
        for (final (type, value) in tokens) type == 0 ? '[$value]' : value,
      ].join(' ');
}

class RmBlock {
  const RmBlock({required this.type, required this.layouts, required this.rules});

  factory RmBlock.fromJson(Map<String, dynamic> j) => RmBlock(
        type: j['type'] as String,
        layouts: [
          for (final l in (j['layouts'] as List))
            RmBandSet.fromJson((l as Map).cast<String, dynamic>()),
        ],
        rules: [
          for (final r in (j['rules'] as List? ?? const []))
            RmRule.fromJson((r as Map).cast<String, dynamic>()),
        ],
      );

  /// The data the block is built from: `Sales`, `Labor Report`, or `Empty` for
  /// the page heading.
  final String type;
  final List<RmBandSet> layouts;
  final List<RmRule> rules;
}

/// One report's whole layout.
class RmReport {
  const RmReport({
    required this.id,
    required this.name,
    required this.group,
    required this.blocks,
  });

  factory RmReport.fromJson(Map<String, dynamic> j) => RmReport(
        id: j['id'] as String,
        name: j['name'] as String,
        group: j['group'] as String,
        blocks: [
          for (final b in (j['blocks'] as List))
            RmBlock.fromJson((b as Map).cast<String, dynamic>()),
        ],
      );

  final String id;
  final String name;
  final String group;
  final List<RmBlock> blocks;

  bool get landscape =>
      blocks.any((b) => b.layouts.any((l) => l.landscape));

  /// Every computed field, for whoever wires the report to data.
  Iterable<RmRule> get computed => blocks
      .expand((b) => b.rules)
      .where((r) => r.field.isNotEmpty && r.tokens.isNotEmpty);
}

/// The reports in the bundled layout file.
List<RmReport> parseRmReports(String json) => [
      for (final r in (jsonDecode(json) as List))
        RmReport.fromJson((r as Map).cast<String, dynamic>()),
    ];

/// The five values a layout asks the program for rather than the data.
class RmSystem {
  const RmSystem({
    required this.shop,
    required this.report,
    required this.period,
    required this.ranAt,
    required this.filter,
  });

  final String shop;
  final String report;
  final String period;
  final String ranAt;
  final String filter;

  String operator [](String number) => switch (number) {
        '0' => ranAt,
        '1' => filter,
        '2' => period,
        '3' => shop,
        '4' => report,
        _ => '',
      };
}

/// One row of a report's data: its own fields, and the rows under it by the last
/// part of their level's path.
class RmRow {
  const RmRow(this.fields, {this.children = const {}});

  final Map<String, String> fields;
  final Map<String, List<RmRow>> children;
}

/// A cell placed on a page, in points from the page's top left.
class RmPlaced {
  const RmPlaced({
    required this.page,
    required this.x,
    required this.y,
    required this.width,
    required this.cell,
    required this.text,
    this.placeholder = false,
    this.clip = true,
  });

  final int page;
  final double x;
  final double y;
  final double width;
  final RmCell cell;
  final String text;

  /// A field with no data behind it yet, shown by its name.
  final bool placeholder;

  /// Whether text longer than [width] is cut there. A value is, so it never
  /// runs into the column beside it; a layout's own wording set from the left
  /// is not, because its designer gave it the room it has on the page, not
  /// the room its cell says.
  final bool clip;
}

/// A report laid out on pages.
class RmDocument {
  const RmDocument({
    required this.items,
    required this.pages,
    required this.pageWidth,
    required this.pageHeight,
  });

  final List<RmPlaced> items;
  final int pages;
  final double pageWidth;
  final double pageHeight;

  Iterable<RmPlaced> on(int page) => items.where((i) => i.page == page);
}

/// Lays [report] out on pages.
///
/// The grid: a band's rows are [rowHeight] apart, and its columns are the width
/// of the page's text area shared between the widest band's columns, never fewer
/// than forty, which is what a heading spanning the page is set to.
///
/// [rows] is the data, by the full path of each outermost level drawn. With
/// none ([rows] null) every level draws once with its fields shown by name,
/// so a report nobody has wired yet still shows its whole shape. With data, a
/// level the data does not mention is left out altogether, the way the back
/// office leaves out a block it was not asked for; one it mentions with no
/// rows still draws its titles and totals. A level in [headless] draws
/// without its own titles.
///
/// [pageHeading] puts a heading on each page and answers where the content
/// starts under it; given one, the layout's own heading block is left out.
RmDocument layOutRmReport(
  RmReport report,
  RmSystem system, {
  Map<String, List<RmRow>>? rows,
  Set<String> headless = const {},
  double Function(List<RmPlaced> items, int page, double pageWidth)?
      pageHeading,
  String Function(String text)? translate,
}) {
  final bound = rows != null;
  final tx = translate ?? (String s) => s;
  const margin = 36.0;
  const rowHeight = 13.0;
  final landscape = report.landscape;
  final pageWidth = landscape ? 842.0 : 595.0;
  final pageHeight = landscape ? 595.0 : 842.0;

  var columns = 40;
  for (final b in report.blocks) {
    for (final l in b.layouts) {
      for (final c in [...l.header, ...l.details, ...l.summary]) {
        // A heading's value is given room to run on; it does not widen the grid.
        if (c.kind == RmKind.system) continue;
        if (c.column + c.length > columns) columns = c.column + c.length;
      }
    }
  }
  final unit = (pageWidth - 2 * margin) / columns;

  final items = <RmPlaced>[];
  var page = 0;
  var y = pageHeading?.call(items, 0, pageWidth) ?? margin;
  final top = y;

  void band(List<RmCell> cells, RmRow? row) {
    if (cells.isEmpty) return;
    final height =
        (cells.map((c) => c.row).reduce((a, b) => a > b ? a : b) + 1) * rowHeight;
    if (y + height > pageHeight - margin && y > top) {
      page++;
      y = pageHeading?.call(items, page, pageWidth) ?? margin;
    }
    for (final c in cells) {
      final String text;
      var placeholder = false;
      switch (c.kind) {
        case RmKind.text:
          text = tx(c.value);
        case RmKind.system:
          text = system[c.value];
        case RmKind.field:
          final value = row?.fields[c.value];
          placeholder = value == null && !bound;
          text = value != null ? tx(value) : (bound ? '' : c.value);
        case RmKind.rule:
          text = '';
      }
      items.add(RmPlaced(
        page: page,
        x: margin + c.column * unit,
        y: y + c.row * rowHeight,
        width: c.length * unit,
        cell: c,
        text: text,
        placeholder: placeholder,
        clip: !(c.kind == RmKind.text && c.justify == 0),
      ));
    }
    y += height;
  }

  for (final block in report.blocks) {
    // The layout's own heading gives way to the one the caller puts.
    if (pageHeading != null && block.type == 'Empty') continue;
    // Levels nest by their path: `A.B` is drawn inside each row of `A`.
    List<RmBandSet> under(String parent) => [
          for (final l in block.layouts)
            if (parent.isEmpty
                ? !block.layouts.any((o) =>
                    o.what != l.what && l.what.startsWith('${o.what}.'))
                : l.what.startsWith('$parent.') &&
                    !block.layouts.any((o) =>
                        o.what != l.what &&
                        o.what.length > parent.length &&
                        l.what.startsWith('${o.what}.')))
              l,
        ];

    void level(RmBandSet set, List<RmRow>? data, RmRow? parent) {
      if (bound && data == null) return;
      final kids = under(set.what);
      // With no data the level draws once, as its own sample row.
      final own = data ?? const <RmRow?>[null];
      void inside(RmRow? row) {
        for (final kid in kids) {
          level(kid, row?.children[kid.what.split('.').last], row);
        }
      }

      if (set.details.isNotEmpty) {
        // A list: its column titles once, a line per row, its totals once.
        if (!headless.contains(set.what)) band(set.header, parent);
        for (final row in own) {
          band(set.details, row);
          inside(row);
        }
        band(set.summary, parent);
      } else {
        // A group: headed and totalled once for each of its rows.
        for (final row in own) {
          band(set.header, row);
          inside(row);
          band(set.summary, row);
        }
      }
    }

    final before = items.length;
    for (final top in under('')) {
      level(top, rows?[top.what], null);
    }
    if (items.length > before) y += rowHeight;
  }

  return RmDocument(
    items: items,
    pages: page + 1,
    pageWidth: pageWidth,
    pageHeight: pageHeight,
  );
}
