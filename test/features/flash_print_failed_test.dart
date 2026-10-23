import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/features/reports/flash/flash_preview_screen.dart';
import 'package:offline_pos/features/reports/flash/flash_report_data.dart';
import 'package:offline_pos/features/reports/flash/flash_type_dialog.dart';

/// A Flash that did not reach the printer says so, loudly, and offers a retry.
void main() {
  final data = FlashReportBuilder.build(
    title: 'Flash Summary',
    periodLabel: 'Today',
    orders: const [],
  );

  Widget app(Future<void> Function(FlashReportData, FlashKind) print) =>
      MaterialApp(
        home: FlashPreviewScreen(
          data: data,
          kind: FlashKind.summary,
          formatAmount: (v) => v.toStringAsFixed(2),
          onPrintFlash: print,
        ),
      );

  testWidgets('a printer that is off opens a dialog with its address', (t) async {
    var calls = 0;
    await t.pumpWidget(app((_, _) async {
      calls++;
      throw StateError('Printer offline: 192.168.1.50');
    }));
    await t.pumpAndSettle();

    expect(find.byKey(const Key('flash-print-failed')), findsOneWidget);
    expect(find.text('Receipt printer is not connected'), findsWidgets);
    expect(find.textContaining('192.168.1.50'), findsOneWidget);

    await t.tap(find.byKey(const Key('flash-print-retry')));
    await t.pumpAndSettle();
    expect(calls, 2);
  });

  testWidgets('no receipt printer at all: no retry, points at the settings', (t) async {
    await t.pumpWidget(app((_, _) async {
      throw StateError('No receipt printer configured');
    }));
    await t.pumpAndSettle();

    expect(find.byKey(const Key('flash-print-failed')), findsOneWidget);
    expect(find.byKey(const Key('flash-print-retry')), findsNothing);
    expect(find.textContaining('Settings › Printers'), findsOneWidget);
  });

  testWidgets('a print that went out shows no dialog', (t) async {
    await t.pumpWidget(app((_, _) async {}));
    await t.pumpAndSettle();

    expect(find.byKey(const Key('flash-print-failed')), findsNothing);
    expect(find.text('Sent to receipt printer'), findsWidgets);
  });
}
