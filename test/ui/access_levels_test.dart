import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/app/pos_session.dart';
import 'package:offline_pos/core/audit/audit_log.dart';
import 'package:offline_pos/core/auth/access.dart';
import 'package:offline_pos/core/db/catalogue_store.dart';
import 'package:offline_pos/core/db/database.dart';
import 'package:offline_pos/core/db/order_store.dart';
import 'package:offline_pos/core/db/settings_store.dart';
import 'package:offline_pos/core/db/sqlite_outbox_store.dart';
import 'package:offline_pos/core/sync/outbox.dart';
import 'package:offline_pos/domain/catalogue.dart';
import 'package:offline_pos/features/admin/access_rules_screen.dart';
import 'package:offline_pos/features/sell/sell_screen.dart';

import '../db/sqlite_loader.dart';

/// Levels: per role, every screen and button is allowed, behind a manager PIN,
/// or hidden.
void main() {
  late Db db;
  late SettingsStore settings;

  setUpAll(useSystemSqlite);
  setUp(() {
    db = Db.open(':memory:');
    settings = SettingsStore(db);
  });
  tearDown(() => db.close());

  group('storage', () {
    test('everything is allowed until a rule is set; a manager never is limited',
        () {
      expect(settings.accessFor('cashier', 'floor.flash'), AccessRule.allow);
      settings.setAccess('cashier', 'floor.flash', AccessRule.hidden);
      settings.setAccess('cashier', 'screen.reports', AccessRule.manager);
      expect(settings.accessFor('cashier', 'floor.flash'), AccessRule.hidden);
      expect(settings.accessFor('cashier', 'screen.reports'), AccessRule.manager);
      settings.setAccess('manager', 'floor.flash', AccessRule.hidden);
      expect(settings.accessFor('manager', 'floor.flash'), AccessRule.allow);
      settings.setAccess('cashier', 'floor.flash', AccessRule.allow);
      expect(settings.accessFor('cashier', 'floor.flash'), AccessRule.allow);
    });

    test('a renamed level keeps its rules, a deleted one takes them along', () {
      settings.addCustomRole('Level 1');
      settings.setAccess('Level 1', 'order.settle', AccessRule.manager);
      settings.renameCustomRole('Level 1', 'Level 2');
      expect(settings.accessFor('Level 2', 'order.settle'), AccessRule.manager);
      expect(settings.accessFor('Level 1', 'order.settle'), AccessRule.allow);
      settings.deleteCustomRole('Level 2');
      settings.addCustomRole('Level 2');
      expect(settings.accessFor('Level 2', 'order.settle'), AccessRule.allow);
    });
  });

  testWidgets('the levels screen saves the rule that is tapped', (t) async {
    t.view.physicalSize = const Size(1366, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    var changed = 0;
    await t.pumpWidget(MaterialApp(
      home: AccessRulesScreen(
        settings: settings,
        role: 'cashier',
        roleLabel: 'Cashier',
        onChanged: () => changed++,
      ),
    ));
    await t.tap(find.byKey(const Key('access-screen.reports-hidden')));
    await t.pump();
    await t.tap(find.byKey(const Key('access-screen.shift-manager')));
    await t.pump();
    expect(settings.accessFor('cashier', 'screen.reports'), AccessRule.hidden);
    expect(settings.accessFor('cashier', 'screen.shift'), AccessRule.manager);
    expect(changed, 2);
  });

  group('the order screen', () {
    late PosSession session;
    const pizza = Product(id: 10, name: 'Pizza', price: 100, categoryId: 1);

    setUp(() {
      final cat = CatalogueStore(db);
      cat.replaceAll(
        categories: const [Category(id: 1, name: 'Food')],
        products: const [pizza],
        groups: const [],
        productGroupIds: const {},
        refreshedAt: DateTime.now().toUtc(),
      );
      session = PosSession(
        catalogue: cat,
        orders: OrderStore(db),
        outbox: Outbox(store: SqliteOutboxStore(db), senders: const {}),
        audit: AuditLog(db),
        deviceId: 'till-1',
        cashierId: 'sara',
      );
    });

    Future<void> open(WidgetTester t, AccessPolicy access) async {
      t.view.physicalSize = const Size(1366, 768);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(MaterialApp(
        home: SellScreen(
          session: session,
          settings: settings,
          formatAmount: (v) => v.toStringAsFixed(2),
          onPrintBill: (_) {},
          access: access,
        ),
      ));
      await t.pumpAndSettle();
    }

    testWidgets('a hidden button is not drawn; a hidden Misc item is not offered',
        (t) async {
      session.addProduct(pizza);
      final rules = {
        'order.settle': AccessRule.hidden,
        'omisc.customer': AccessRule.hidden,
      };
      await open(
          t, AccessPolicy(ruleOf: (id) => rules[id] ?? AccessRule.allow));
      expect(find.byKey(const Key('order-action-settle')), findsNothing);
      expect(find.byKey(const Key('order-action-print')), findsOneWidget);
      await t.tap(find.byKey(const Key('order-action-misc')));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('misc-customer')), findsNothing);
      expect(find.byKey(const Key('misc-item-lookup')), findsOneWidget);
    });

    testWidgets('a gated button runs only once a manager approves', (t) async {
      session.addProduct(pizza);
      var asked = 0;
      var approve = false;
      final printed = <String>[];
      t.view.physicalSize = const Size(1366, 768);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(MaterialApp(
        home: SellScreen(
          session: session,
          settings: settings,
          formatAmount: (v) => v.toStringAsFixed(2),
          onPrintBill: (o) => printed.add(o.uuid),
          access: AccessPolicy(
            ruleOf: (id) =>
                id == 'order.print' ? AccessRule.manager : AccessRule.allow,
            approve: (_) async {
              asked++;
              return approve;
            },
          ),
        ),
      ));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('order-action-print')));
      await t.pumpAndSettle();
      expect(asked, 1);
      expect(printed, isEmpty);
      approve = true;
      await t.tap(find.byKey(const Key('order-action-print')));
      await t.pumpAndSettle();
      expect(asked, 2);
      expect(printed, hasLength(1));
    });
  });
}
