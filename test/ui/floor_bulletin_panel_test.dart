import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/domain/floor_bulletin.dart';
import 'package:offline_pos/features/tables/floor_bulletin_panel.dart';

void main() {
  const bulletin = FloorBulletin(
    tables: 9,
    openTables: 1,
    freeTables: 8,
    sentToKitchen: 0,
    notSent: 1,
    billPrinted: 0,
    delivery: 1,
    takeaway: 0,
    openAmount: 136.79,
    paidToday: 0,
    salesToday: 0,
  );

  Future<void> pump(WidgetTester t, Set<String> hidden) => t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              height: 700,
              child: FloorBulletinPanel(
                bulletin: bulletin,
                formatAmount: (v) => v.toStringAsFixed(2),
                hidden: hidden,
              ),
            ),
          ),
        ),
      );

  testWidgets('shows every row by default', (t) async {
    await pump(t, const {});
    for (final r in FloorBulletinPanel.rows) {
      expect(find.byKey(Key('bulletin-${r.id}')), findsOneWidget);
    }
    expect(find.text('8 / 9'), findsOneWidget);
  });

  testWidgets('the board is only as tall as its rows, the Dishflow mark under it',
      (t) async {
    await pump(t, const {'free', 'sent', 'not-sent', 'billed', 'delivery',
        'takeaway', 'open-amount', 'paid', 'sales'});
    final board = t.getRect(find.byKey(const Key('floor-bulletin')));
    final logo = t.getRect(find.byKey(const Key('floor-bulletin-logo')));
    expect(board.height, lessThan(200));
    expect(logo.top, closeTo(board.bottom, 1));
    expect(find.text('Dishflow'), findsOneWidget);
  });

  testWidgets('a row switched off in settings is left off the board',
      (t) async {
    await pump(t, const {'sales', 'open-amount'});
    expect(find.byKey(const Key('bulletin-sales')), findsNothing);
    expect(find.byKey(const Key('bulletin-open-amount')), findsNothing);
    expect(find.byKey(const Key('bulletin-open')), findsOneWidget);
  });
}
