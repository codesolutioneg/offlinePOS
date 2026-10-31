import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/features/reports/rm/thermal_report.dart';

void main() {
  List<String> texts(List<ThermalLine> lines) =>
      [for (final l in lines) l.text];

  test('column titles, a rule under them, then a line per row', () {
    final lines = thermalTableLines(
      const ['Product', 'Units', 'Revenue'],
      const [
        ['Pizza', '1', '250.50'],
        ['Koshari', '12', '150.00'],
      ],
      40,
    );

    expect(texts(lines), [
      'Product                    Units Revenue',
      '-' * 40,
      'Pizza                          1  250.50',
      'Koshari                       12  150.00',
    ]);
  });

  test('no line is wider than the roll, however long a name is', () {
    final lines = thermalTableLines(
      const ['Product', 'Units', 'Revenue'],
      [
        ['A dish with a name far too long for any receipt roll' * 2, '1', '9.00'],
      ],
      40,
    );

    for (final l in lines) {
      expect(l.text.length, lessThanOrEqualTo(40), reason: l.text);
    }
    // The figures survive; it is the name that gives way.
    expect(lines.last.text, endsWith('    1    9.00'));
  });

  test('a sectioned report prints each section under its own centred title', () {
    final lines = thermalTableLines(
      const ['Section', 'Item', 'Amount'],
      const [
        ['Payment types', 'Visa', '1156.14'],
        ['Tax types', 'Service', '79.20'],
        ['Tax types', 'VAT', '141.98'],
      ],
      40,
    );

    final titles = lines.where((l) => l.center).toList();
    expect(texts(titles), ['Payment types', 'Tax types']);
    expect(titles.every((l) => l.bold), isTrue);
    // Titles and the rule again for every section, as on the page.
    expect(lines.where((l) => l.text == '-' * 40), hasLength(2));
    expect(texts(lines), contains('VAT                               141.98'));
  });

  test('a table too wide for the roll prints a record at a time', () {
    final lines = thermalTableLines(
      const ['Order', 'Bill time', 'Revenue centre', 'Table', 'Cashier', 'Total'],
      const [
        ['953', '2026-10-07 11:47', 'Car delivery', 'T1', 'yasser', '313.49'],
        ['962', '2026-10-07 12:01', 'Dine-in', '', 'yasser', '280.88'],
      ],
      40,
    );

    for (final l in lines) {
      expect(l.text.length, lessThanOrEqualTo(40), reason: l.text);
    }
    final all = texts(lines);
    // What the row is, then each column as a label with its value at the edge.
    expect(all.first, 'Order${' ' * 32}953');
    expect(lines.first.bold, isTrue);
    expect(all, contains('Total${' ' * 29}313.49'));
    // A column with nothing in it is not printed as an empty label.
    expect(all.where((t) => t.startsWith('Table')), hasLength(1));
    expect(all.where((t) => t == '-' * 40), hasLength(2));
  });

  test('slip preview includes shop, title, filter, then the table', () {
    final lines = thermalReportSlipLines(
      const ThermalReport(
        title: 'Driver account',
        period: 'Today',
        filter: 'All drivers',
        header: ['Driver', 'Orders', 'Total'],
        rows: [
          ['Ali', '2', '100.00'],
        ],
        dateLabel: 'Date/time',
        filterLabel: 'Report filter',
      ),
      shopName: 'Test Shop',
      columns: 40,
      at: DateTime(2026, 10, 19, 15, 30),
    );
    final all = texts(lines);
    expect(all.first, 'Test Shop');
    expect(lines.first.center, isTrue);
    expect(all, contains('Driver account'));
    expect(all, contains('Date/time: 2026-10-19 15:30'));
    expect(all, contains('Report filter: All drivers'));
    expect(all.any((t) => t.startsWith('Ali') && t.contains('100.00')), isTrue);
  });
}
