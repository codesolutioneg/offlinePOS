import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/features/reports/rm/rm_layout.dart';
import 'package:offline_pos/features/reports/rm/rm_pdf.dart';
import 'package:offline_pos/features/reports/rm/rm_report_viewer.dart';

void main() {
  final reports = parseRmReports(
      File('assets/report_layouts/layouts.json').readAsStringSync());

  const system = RmSystem(
    shop: 'Nour Grill',
    report: 'Item Sales',
    period: 'Today',
    ranAt: '2026-10-07 14:22',
    filter: 'None',
  );

  RmReport named(String id) => reports.firstWhere((r) => r.id == id);

  test('every bundled layout lays out without leaving the page', () {
    expect(reports, hasLength(91));
    for (final r in reports) {
      final doc = layOutRmReport(r, system);
      expect(doc.pages, greaterThan(0), reason: r.id);
      for (final i in doc.items) {
        expect(i.y, lessThan(doc.pageHeight), reason: '${r.id} runs off the page');
        expect(i.x, greaterThanOrEqualTo(0), reason: r.id);
      }
    }
  });

  test('the heading carries the shop, the report and when it was run', () {
    final doc = layOutRmReport(named('ItemSales'), system);
    final texts = doc.items.map((i) => i.text).toSet();
    expect(texts, containsAll(['Nour Grill', 'Item Sales', '2026-10-07 14:22']));
    expect(texts, contains('Date/time:'));
  });

  test('a level with no data shows its fields by name', () {
    final doc = layOutRmReport(named('ItemSales'), system);
    final field = doc.items.firstWhere((i) => i.text == 'Item Revenue');
    expect(field.placeholder, isTrue);
  });

  test('a list draws one line per row under one set of column titles', () {
    const list =
        'Flattened Item grouped by Menu Item grouped by Group Numbers';
    final doc = layOutRmReport(named('ItemSales'), system, rows: {
      list: [
        RmRow(const {
          'Total Revenues': '400.50'
        }, children: {
          'Group': [
            RmRow(const {
              'Group Name': 'Burgers'
            }, children: {
              'Flattened Item grouped by Menu Item Detail': const [
                RmRow({'Description': 'Classic', 'Item Revenue': '250.50'}),
                RmRow({'Description': 'Truffle', 'Item Revenue': '150.00'}),
              ],
            }),
          ],
        }),
      ],
    });
    final texts = doc.items.map((i) => i.text).toList();
    expect(texts.where((t) => t == 'Description'), hasLength(1));
    expect(texts, containsAll(['Classic', 'Truffle', '250.50', '150.00']));
    expect(texts, containsAll(['Burgers', '400.50']));
  });

  test('a computed field reads as its formula', () {
    final rule =
        named('ATIPTips').computed.firstWhere((r) => r.field == '% CC Tips');
    expect(rule.expression, '[CC Tips] * 100 / [CC Sales]');
  });

  test('the laid-out report saves as a PDF', () async {
    final bytes = await buildRmPdf(layOutRmReport(named('ItemSales'), system));
    expect(String.fromCharCodes(bytes.take(4)), '%PDF');
    final keep = Directory('build/rm-layouts')..createSync(recursive: true);
    File('${keep.path}/item-sales.pdf').writeAsBytesSync(bytes);
    for (final id in ['SessionSummary', 'employeeTimeKeeping', 'DiscReport']) {
      final r = named(id);
      File('${keep.path}/$id.pdf').writeAsBytesSync(await buildRmPdf(
          layOutRmReport(
              r,
              RmSystem(
                  shop: 'Nour Grill',
                  report: r.name,
                  period: 'Today',
                  ranAt: '2026-10-07 14:22',
                  filter: 'None'))));
    }
  });

  testWidgets('the viewer turns the pages and says how many there are',
      (t) async {
    t.view.physicalSize = const Size(1400, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);

    final report =
        reports.firstWhere((r) => layOutRmReport(r, system).pages > 1);
    await t.pumpWidget(MaterialApp(
      home: RmReportViewer(
          title: report.name, document: layOutRmReport(report, system)),
    ));

    expect(find.byKey(const Key('rm-page')), findsOneWidget);
    expect(find.byKey(const Key('rm-unwired')), findsOneWidget);
    expect(
        t.widget<Text>(find.byKey(const Key('rm-page-count'))).data, startsWith('1 '));

    await t.tap(find.byKey(const Key('rm-next')));
    await t.pumpAndSettle();
    expect(
        t.widget<Text>(find.byKey(const Key('rm-page-count'))).data, startsWith('2 '));
  });
}
