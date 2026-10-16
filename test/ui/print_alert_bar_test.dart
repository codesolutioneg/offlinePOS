import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/widgets/print_alert_bar.dart';

void main() {
  late ValueNotifier<List<PrintAlert>> alerts;
  var printerBack = false;

  PrintAlert kitchen({int count = 1}) => PrintAlert(
        kind: 'kitchen',
        title: 'Kitchen ticket did not print',
        where: 'T1',
        count: count,
        retry: () async => printerBack,
      );

  Widget bar() => MaterialApp(
        home: Scaffold(
          body: PrintAlertBar(
            alerts: alerts,
            onDismiss: (kind) => alerts.value = [
              for (final a in alerts.value)
                if (a.kind != kind) a,
            ],
          ),
        ),
      );

  setUp(() {
    alerts = ValueNotifier(const []);
    printerBack = false;
  });

  testWidgets('with nothing waiting there is no strip', (t) async {
    await t.pumpWidget(bar());
    expect(find.byKey(const Key('print-alert-kitchen')), findsNothing);
  });

  testWidgets('a slip no printer took stays up and names the table', (t) async {
    alerts.value = [kitchen(count: 3)];
    await t.pumpWidget(bar());
    await t.pump(const Duration(seconds: 30));

    expect(find.byKey(const Key('print-alert-kitchen')), findsOneWidget);
    expect(find.textContaining('T1 (+2)'), findsOneWidget);
  });

  testWidgets('retry keeps the strip while the printer is still off', (t) async {
    alerts.value = [kitchen()];
    await t.pumpWidget(bar());

    await t.tap(find.byKey(const Key('print-alert-retry-kitchen')));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('print-alert-kitchen')), findsOneWidget);

    printerBack = true;
    await t.tap(find.byKey(const Key('print-alert-retry-kitchen')));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('print-alert-kitchen')), findsNothing);
  });

  testWidgets('ignore takes the strip off', (t) async {
    alerts.value = [kitchen()];
    await t.pumpWidget(bar());

    await t.tap(find.byKey(const Key('print-alert-ignore-kitchen')));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('print-alert-kitchen')), findsNothing);
  });
}
