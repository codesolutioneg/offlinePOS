import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:offline_pos/domain/order.dart';
import 'package:offline_pos/features/reports/sales_report_screen.dart';
import 'package:offline_pos/web_reports/login_art.dart';
import 'package:offline_pos/web_reports/site_api.dart';
import 'package:offline_pos/web_reports/site_app.dart';

import '../ui/report_period.dart';

/// The reports site's API, in memory: two accounts, one branch, three sales.
class FakeSite {
  String? signedIn;

  static const branch = {'id': 'b1', 'name': 'Main'};

  final accounts = <String, (String, Map<String, Object?>)>{
    'owner': (
      'owner-pass-1',
      {
        'id': 'u1',
        'username': 'owner',
        'display_name': 'Owner',
        'role': 'owner',
        'all_branches': true,
        'branch_ids': <String>[],
        'capabilities': ['costs', 'audit', 'staff', 'expenses', 'backoffice', 'flash'],
        'active': true,
      }
    ),
    'mona': (
      'mona-pass-1',
      {
        'id': 'u2',
        'username': 'mona',
        'display_name': 'Mona',
        'role': 'accountant',
        'all_branches': false,
        'branch_ids': ['b1'],
        'capabilities': ['expenses', 'backoffice', 'flash'],
        'active': true,
      }
    ),
  };

  late final List<Map<String, Object?>> records = () {
    final at = DateTime.now().toUtc().subtract(const Duration(hours: 1));
    Map<String, Object?> sale(String name, double price, double qty) {
      final order = Order(deviceId: 'till-1', cashierId: 'sara', createdAt: at)
        ..lines.add(OrderLine(productId: 1, name: name, quantity: qty, unitPrice: price))
        ..state = OrderState.paid;
      return {
        'kind': 'order',
        'key': order.uuid,
        'branch_id': 'b1',
        'at': at.toIso8601String(),
        'payload': order.toMap(),
      };
    }

    return [
      sale('Koshary', 45, 2),
      sale('Tea', 10, 1),
      sale('Om Ali', 40, 1),
      {
        'kind': 'shop',
        'key': 'b1',
        'branch_id': 'b1',
        'at': null,
        'payload': {'name': 'Demo shop'},
      },
    ];
  }();

  Map<String, Object?>? get _user =>
      signedIn == null ? null : accounts[signedIn]!.$2;

  Future<http.Response> handle(http.Request r) async {
    http.Response reply(int status, Object body) => http.Response(
        jsonEncode(body), status,
        headers: {'content-type': 'application/json; charset=utf-8'});
    final path = r.url.path;
    if (r.method == 'POST' && path == '/api/auth/login') {
      final m = jsonDecode(r.body) as Map<String, dynamic>;
      final account = accounts[m['username']];
      if (account == null || account.$1 != m['password']) {
        return reply(401, {'error': 'wrong username or password'});
      }
      signedIn = m['username'] as String;
      return reply(200, {'user': account.$2});
    }
    final user = _user;
    if (user == null) return reply(401, {'error': 'sign in first'});
    switch (path) {
      case '/api/me':
        return reply(200, {
          'user': user,
          'shop': {'id': 's1', 'name': 'Demo shop'},
          'branches': [branch],
        });
      case '/api/branches':
        return reply(200, {
          'branches': [
            {...branch, 'devices': <Object>[]},
          ],
        });
      case '/api/records':
        final kinds = (r.url.queryParameters['kinds'] ?? '').split(',').toSet();
        return reply(200, {
          'records': [
            for (final rec in records)
              if (kinds.contains(rec['kind'])) rec,
          ],
        });
      case '/api/auth/logout':
        signedIn = null;
        return http.Response('', 204);
    }
    return reply(404, {'error': 'no such route'});
  }
}

void main() {
  late FakeSite site;

  setUp(() => site = FakeSite());

  Future<void> start(WidgetTester t) async {
    t.view.physicalSize = const Size(1500, 1000);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(SiteApp(
        api: SiteApi(base: Uri.parse('http://site.test'), client: MockClient(site.handle))));
    await t.pumpAndSettle();
  }

  Future<void> signIn(WidgetTester t, String username, String password) async {
    await t.enterText(find.byKey(const Key('login-username')), username);
    await t.enterText(find.byKey(const Key('login-password')), password);
    await t.tap(find.byKey(const Key('login-submit')));
    await t.pumpAndSettle();
  }

  Future<void> openReports(WidgetTester t) async {
    await t.tap(find.byKey(const Key('home-reports')));
    await t.pumpAndSettle();
  }

  testWidgets('the sign-in picture shows beside the form, and gives way on a phone',
      (t) async {
    await start(t);
    expect(find.byType(LoginArt), findsOneWidget);

    t.view.physicalSize = const Size(400, 800);
    await t.pumpAndSettle();
    expect(find.byType(LoginArt), findsNothing);
    expect(find.byKey(const Key('login-submit')), findsOneWidget);
  });

  testWidgets('a wrong password is refused, the right one opens the shop', (t) async {
    await start(t);
    await signIn(t, 'owner', 'nope-nope');
    expect(find.byKey(const Key('login-error')), findsOneWidget);

    await signIn(t, 'owner', 'owner-pass-1');
    expect(find.text('Demo shop'), findsOneWidget);
    expect(find.text('Main'), findsOneWidget);
    // Today's takings on the branch card and the headline figure: 90 + 10 + 40.
    expect(
        t.widget<Text>(find.byKey(const Key('branch-sales-b1'))).data, '140.00');
    expect(
        find.descendant(of: find.byKey(const Key('kpi-sales')), matching: find.text('140.00')),
        findsOneWidget);
    expect(
        find.descendant(of: find.byKey(const Key('kpi-orders')), matching: find.text('3')),
        findsOneWidget);
    expect(find.byKey(const Key('home-users')), findsOneWidget);
  });

  testWidgets('the owner gets the till\'s reports over the uploaded sales', (t) async {
    await start(t);
    await signIn(t, 'owner', 'owner-pass-1');
    await openReports(t);

    expect(find.byKey(const Key('rep-cost-sales')), findsOneWidget);
    expect(find.byKey(const Key('rep-activity')), findsOneWidget);

    await tapReport(t, 'rep-summary');
    expect(find.byType(SalesReportScreen, skipOffstage: false), findsOneWidget);
    expect(find.textContaining('140.00', skipOffstage: false), findsWidgets);
  });

  testWidgets('the front page fits a phone, changes period and opens a branch\'s reports',
      (t) async {
    await start(t);
    await signIn(t, 'owner', 'owner-pass-1');
    t.view.physicalSize = const Size(420, 2400);
    await t.pumpAndSettle();
    expect(find.byKey(const Key('kpi-sales')), findsOneWidget);

    await t.tap(find.byKey(const Key('period-yesterday')));
    await t.pumpAndSettle();
    expect(
        find.descendant(of: find.byKey(const Key('kpi-orders')), matching: find.text('0')),
        findsOneWidget);

    await t.tap(find.byKey(const Key('period-week')));
    await t.pumpAndSettle();
    expect(
        find.descendant(of: find.byKey(const Key('kpi-orders')), matching: find.text('3')),
        findsOneWidget);

    // The reports screen is the till's, laid out for a desk screen.
    t.view.physicalSize = const Size(1500, 1000);
    await t.pumpAndSettle();
    await t.ensureVisible(find.byKey(const Key('branch-reports-b1')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('branch-reports-b1')));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('rep-summary')), findsOneWidget);
  });

  testWidgets('an accountant sees only the reports the owner allowed', (t) async {
    await start(t);
    await signIn(t, 'mona', 'mona-pass-1');
    expect(find.byKey(const Key('home-users')), findsNothing);
    await openReports(t);

    expect(find.byKey(const Key('rep-summary')), findsOneWidget);
    expect(find.byKey(const Key('rep-expenses')), findsOneWidget);
    expect(find.byKey(const Key('rep-cost-sales')), findsNothing);
    expect(find.byKey(const Key('rep-menu-eng')), findsNothing);
    expect(find.byKey(const Key('rep-activity')), findsNothing);
    expect(find.byKey(const Key('rep-refunds')), findsNothing);
    expect(find.byKey(const Key('rep-hours')), findsNothing);
  });
}
