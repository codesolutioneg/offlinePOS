import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:offline_pos/web_reports/branches_page.dart';
import 'package:offline_pos/web_reports/site_api.dart';

void main() {
  late List<Map<String, Object?>> branches;
  late List<String> deleted;

  setUp(() {
    branches = [
      {'id': 'b1', 'name': 'Main branch', 'devices': <Object>[]},
      {'id': 'b2', 'name': 'Stress test', 'devices': <Object>[]},
    ];
    deleted = [];
  });

  Future<http.Response> handle(http.Request r) async {
    if (r.method == 'GET' && r.url.path == '/api/branches') {
      return http.Response(jsonEncode({'branches': branches}), 200,
          headers: {'content-type': 'application/json'});
    }
    final id = r.url.pathSegments.last;
    if (r.method == 'DELETE' && r.url.path == '/api/branches/$id') {
      deleted.add(id);
      branches.removeWhere((b) => b['id'] == id);
      return http.Response('', 204);
    }
    return http.Response(jsonEncode({'error': 'no such route'}), 404);
  }

  Future<void> open(WidgetTester t, {bool owner = true}) async {
    t.view.physicalSize = const Size(1400, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(
      home: BranchesPage(
        api: SiteApi(base: Uri.parse('http://site.test'), client: MockClient(handle)),
        canManage: owner,
      ),
    ));
    await t.pumpAndSettle();
  }

  Future<void> deleteTyping(WidgetTester t, String typed) async {
    await t.tap(find.byKey(const Key('branch-delete-b2')));
    await t.pumpAndSettle();
    await t.tap(find.text('Continue'));
    await t.pumpAndSettle();
    await t.enterText(find.byType(TextField), typed);
    await t.tap(find.widgetWithText(FilledButton, 'Delete'));
    await t.pumpAndSettle();
  }

  testWidgets('the owner deletes a branch once its name is typed', (t) async {
    await open(t);
    await deleteTyping(t, 'Stress test');

    expect(deleted, ['b2']);
    expect(find.text('Stress test'), findsNothing);
    // The last branch stays: there is nothing to delete it for.
    expect(find.byKey(const Key('branch-delete-b1')), findsNothing);
  });

  testWidgets('a name that does not match deletes nothing', (t) async {
    await open(t);
    await deleteTyping(t, 'Stress');

    expect(deleted, isEmpty);
    expect(find.text('Stress test'), findsOneWidget);
  });

  testWidgets('only the owner is offered the delete', (t) async {
    await open(t, owner: false);
    expect(find.byKey(const Key('branch-delete-b2')), findsNothing);
  });
}
