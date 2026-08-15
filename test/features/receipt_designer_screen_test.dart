import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/db/database.dart';
import 'package:offline_pos/core/db/settings_store.dart';
import 'package:offline_pos/core/printing/printer_logo.dart';
import 'package:offline_pos/features/settings/receipt_designer_screen.dart';

import '../db/sqlite_loader.dart';

void main() {
  late Db db;
  late SettingsStore settings;
  int changedCount = 0;

  setUpAll(useSystemSqlite);
  setUp(() {
    db = Db.open(':memory:');
    settings = SettingsStore(db);
    changedCount = 0;
  });
  tearDown(() => db.close());

  /// A window tall enough for the whole options list, so a control below the fold
  /// is on screen rather than behind the pinned Save bar.
  void tallWindow(WidgetTester t) {
    t.view.physicalSize = const Size(1000, 2400);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
  }

  Widget app() => MaterialApp(
        home: ReceiptDesignerScreen(
          settings: settings,
          onChanged: () => changedCount++,
        ),
      );

  testWidgets('toggling cashier off, entering a header, and saving persists both', (t) async {
    await t.pumpWidget(app());

    await t.enterText(find.byKey(const Key('receipt-header')), 'Cairo Diner');
    await t.tap(find.byKey(const Key('t-cashier')));
    await t.tap(find.byKey(const Key('save-receipt')));
    await t.pumpAndSettle();

    expect(settings.getString('receipt_header'), 'Cairo Diner');
    expect(settings.getBool('receipt_show_cashier', fallback: true), false);
    expect(changedCount, 1);
    expect(find.text('Saved'), findsOneWidget);
  });

  testWidgets('the what-prints toggles default on and persist when switched off', (t) async {
    tallWindow(t);
    await t.pumpWidget(app());

    for (final k in ['t-datetime', 't-number', 't-table', 't-payment', 't-itemprice']) {
      await t.tap(find.byKey(Key(k)));
    }
    await t.tap(find.byKey(const Key('save-receipt')));
    await t.pumpAndSettle();

    expect(settings.receiptShowDateTime, false);
    expect(settings.receiptShowNumber, false);
    expect(settings.receiptShowTable, false);
    expect(settings.receiptShowPayment, false);
    expect(settings.receiptShowItemPrice, false);
  });

  testWidgets('the divider style is an exclusive choice and persists', (t) async {
    tallWindow(t);
    await t.pumpWidget(app());
    expect(settings.receiptDividerStyle, 'line');

    // The segment's ink well takes the tap, not the label the key is on.
    await t.tap(find.byKey(const Key('t-divider-stars')), warnIfMissed: false);
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('save-receipt')));
    await t.pumpAndSettle();

    expect(settings.receiptDividerStyle, 'stars');
  });

  testWidgets('the paper size writes the same key the printers screen uses', (t) async {
    tallWindow(t);
    settings.receiptColumns = 42;
    await t.pumpWidget(app());

    await t.tap(find.byKey(const Key('t-papersize-58')), warnIfMissed: false);
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('save-receipt')));
    await t.pumpAndSettle();

    expect(settings.receiptColumns, 32);
    expect(settings.getString('receipt_columns'), '32');
  });

  testWidgets('saving leaves settings the screen did not change alone', (t) async {
    settings.receiptColumns = 32;
    settings.receiptDividerStyle = 'dots';
    await t.pumpWidget(app());

    await t.tap(find.byKey(const Key('save-receipt')));
    await t.pumpAndSettle();

    expect(settings.receiptColumns, 32);
    expect(settings.receiptDividerStyle, 'dots');
    expect(settings.receiptShowTable, true);
  });

  testWidgets('the live preview reflects the header text and the cashier toggle',
      (t) async {
    tallWindow(t);
    await t.pumpWidget(app());

    expect(find.descendant(of: find.byKey(const Key('receipt-preview')), matching: find.text('Cairo Diner')),
        findsNothing);

    await t.enterText(find.byKey(const Key('receipt-header')), 'Cairo Diner');
    await t.pump();

    expect(find.descendant(of: find.byKey(const Key('receipt-preview')), matching: find.text('Cairo Diner')),
        findsOneWidget);

    // The cashier line only prints on the receipt (and shows in the preview)
    // while the toggle is on.
    expect(find.textContaining('Cashier:'), findsOneWidget);
    await t.tap(find.byKey(const Key('t-cashier')));
    await t.pump();
    expect(find.textContaining('Cashier:'), findsNothing);
  });

  testWidgets('the preview narrows when 58 mm paper is selected', (t) async {
    tallWindow(t);
    await t.pumpWidget(app());

    final wideBox = t.getSize(find.byKey(const Key('receipt-preview')));

    await t.tap(find.byKey(const Key('t-papersize-58')), warnIfMissed: false);
    await t.pump();

    final narrowBox = t.getSize(find.byKey(const Key('receipt-preview')));
    expect(narrowBox.width, lessThan(wideBox.width));
  });

  group('the shop logo', () {
    /// The upload the screen would do to a real printer, recorded instead of sent.
    Widget appWithUpload({bool printerAnswers = true, List<PrinterLogo>? sent}) =>
        MaterialApp(
          home: ReceiptDesignerScreen(
            settings: settings,
            onChanged: () => changedCount++,
            onUploadLogo: (logo) async {
              if (!printerAnswers) throw StateError('printer off');
              sent?.add(logo);
            },
          ),
        );

    testWidgets('the toggle persists and the preview shows where the mark lands',
        (t) async {
      tallWindow(t);
      await t.pumpWidget(app());

      expect(find.byKey(const Key('receipt-preview-logo')), findsNothing);

      await t.tap(find.byKey(const Key('t-logo')));
      await t.pump();
      expect(find.byKey(const Key('receipt-preview-logo')), findsOneWidget);

      await t.tap(find.byKey(const Key('save-receipt')));
      await t.pumpAndSettle();
      expect(settings.receiptPrintLogo, isTrue);
      // The command a receipt will carry from now on: print stored image 1.
      expect(settings.receiptLogoCommand(), [0x1c, 0x70, 1, 0]);
    });

    testWidgets('the raster fallback is a separate, deliberate choice', (t) async {
      tallWindow(t);
      settings.receiptPrintLogo = true;
      settings.receiptLogo =
          PrinterLogo(widthDots: 8, heightDots: 8, bits: Uint8List(8)..[0] = 0x80);
      await t.pumpWidget(app());

      await t.tap(find.byKey(const Key('t-logo-raster')));
      await t.tap(find.byKey(const Key('save-receipt')));
      await t.pumpAndSettle();

      expect(settings.receiptLogoRaster, isTrue);
      // Now the dots travel with the receipt instead of the four-byte command.
      expect(settings.receiptLogoCommand()!.sublist(0, 4), [0x1d, 0x76, 0x30, 0x00]);
    });

    testWidgets('a file that is not an image is refused before anything is stored',
        (t) async {
      tallWindow(t);
      final sent = <PrinterLogo>[];
      settings.receiptPrintLogo = true;
      await t.pumpWidget(appWithUpload(sent: sent));

      await t.enterText(
          find.byKey(const Key('logo-path')), '/definitely/not/here.png');
      await t.tap(find.byKey(const Key('upload-logo')));
      // Reading the file is real IO, which only runs outside the test's fake clock.
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await t.pumpAndSettle();

      expect(find.byKey(const Key('logo-status')), findsOneWidget);
      expect(settings.receiptLogo, isNull);
      expect(sent, isEmpty);
    });

    testWidgets('with no path at all it says so rather than doing nothing',
        (t) async {
      tallWindow(t);
      settings.receiptPrintLogo = true;
      await t.pumpWidget(appWithUpload());

      await t.tap(find.byKey(const Key('upload-logo')));
      await t.pumpAndSettle();

      expect(find.byKey(const Key('logo-status')), findsOneWidget);
    });
  });
}
