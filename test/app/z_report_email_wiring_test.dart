import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/app/pos_app.dart';
import 'package:offline_pos/core/audit/audit_log.dart';
import 'package:offline_pos/core/auth/auth_service.dart';
import 'package:offline_pos/core/auth/user_store.dart';
import 'package:offline_pos/core/config/till_config.dart';
import 'package:offline_pos/core/db/attendance_store.dart';
import 'package:offline_pos/core/db/catalogue_store.dart';
import 'package:offline_pos/core/db/customer_store.dart';
import 'package:offline_pos/core/db/database.dart';
import 'package:offline_pos/core/db/order_store.dart';
import 'package:offline_pos/core/db/settings_store.dart';
import 'package:offline_pos/core/db/shift_store.dart';
import 'package:offline_pos/core/db/sqlite_outbox_store.dart';
import 'package:offline_pos/core/db/table_store.dart';
import 'package:offline_pos/core/email/email_outbox.dart';
import 'package:offline_pos/core/email/email_service.dart';
import 'package:offline_pos/core/email/smtp_client.dart';
import 'package:offline_pos/core/email/smtp_config.dart';
import 'package:offline_pos/core/onboarding/wizard_id.dart';
import 'package:offline_pos/core/onboarding/wizard_store.dart';
import 'package:offline_pos/core/printing/printer_discovery.dart';
import 'package:offline_pos/core/printing/printer_registry.dart';
import 'package:offline_pos/core/sync/odoo_endpoint.dart';
import 'package:offline_pos/core/sync/odoo_wiring.dart';
import 'package:offline_pos/core/sync/outbox.dart';
import 'package:offline_pos/core/sync/sync_service.dart';
import 'package:offline_pos/features/sell/sell_screen.dart';
import 'package:offline_pos/features/shift/shift_screen.dart';

import '../db/sqlite_loader.dart';
import '../ui/fake_pin_hasher.dart';

class _NoPrinters extends PrinterDiscovery {
  @override
  Future<bool> probe(String host, {int? port}) async => false;

  @override
  Future<List<DiscoveredPrinter>> scan({int? port, Duration? budget}) async => const [];
}

/// The Z report by mail, as a closing cashier meets it.
///
/// The sender and the queue have their own tests. What is covered here is the
/// seam and the promise around it: the shell has to hand the closed Z over, and
/// nothing about mail may be able to hold up or fail a cash-up.
void main() {
  late Db db;
  late OrderStore orders;
  late SettingsStore settings;
  late ShiftStore shifts;
  late UserStore users;
  late AuditLog audit;
  late List<EmailMessage> sent;
  late bool mailDown;
  late bool mailExplodes;
  late DateTime clock;

  setUpAll(useSystemSqlite);
  setUp(() async {
    db = Db.open(':memory:');
    orders = OrderStore(db);
    settings = SettingsStore(db);
    shifts = ShiftStore(db);
    users = UserStore(db);
    audit = AuditLog(db);
    sent = [];
    mailDown = false;
    mailExplodes = false;
    clock = DateTime.utc(2026, 3, 1, 23);
    await AuthService(users: users, hasher: FakePinHasher(), audit: audit)
        .enrol(id: 'sara', name: 'Sara', pin: '1234', role: 'manager');
    WizardStore(db).dismiss(WizardId.firstSale, 'sara');
    WizardStore(db).dismiss(WizardId.setupChecklist, 'sara');
  });
  tearDown(() => db.close());

  /// A shop that has asked for the report.
  void mailConfigured() {
    settings.smtpHost = 'mail.shop.example';
    settings.smtpSecurity = SmtpSecurity.ssl;
    settings.smtpFrom = 'till@shop.example';
    settings.smtpUsername = 'till@shop.example';
    settings.smtpPassword = 'hunter2';
    settings.zReportRecipients = ['owner@shop.example'];
    settings.emailZReport = true;
  }

  late EmailService emailer;

  Widget app() {
    final outbox = Outbox(store: SqliteOutboxStore(db), senders: {});
    emailer = EmailService(
      queue: EmailOutbox(db),
      config: () => settings.smtp,
      audit: audit,
      now: () => clock,
      transport: (config, message) async {
        if (mailExplodes) throw StateError('the mail layer fell over');
        if (mailDown) throw SmtpFailure('no route to the mail server');
        sent.add(message);
      },
    );
    return PosApp(
      auth: AuthService(users: users, hasher: FakePinHasher(), audit: audit),
      users: users,
      catalogue: CatalogueStore(db),
      orders: orders,
      outbox: outbox,
      audit: audit,
      sync: SyncService(
        outbox: outbox,
        catalogue: CatalogueStore(db),
        outboxStore: SqliteOutboxStore(db),
        deviceId: 'till-1',
        appVersion: 'test',
      ),
      outboxStore: SqliteOutboxStore(db),
      printers: PrinterRegistry(discovery: _NoPrinters()),
      wizards: WizardStore(db),
      shifts: shifts,
      deviceId: 'till-1',
      endpoints: OdooEndpointStore(db),
      odoo: OdooWiring(outbox: outbox),
      tables: TableStore(db),
      settings: settings,
      customers: CustomerStore(db),
      attendance: AttendanceStore(db),
      emailer: emailer,
      config: const TillConfig(shopName: 'Corner Cafe'),
    );
  }

  Future<void> signIn(WidgetTester t) async {
    await t.tap(find.byKey(const Key('user-sara')));
    await t.pumpAndSettle();
    for (final d in '1234'.split('')) {
      await t.tap(find.byKey(Key('key-$d')));
      await t.pump();
    }
    await t.tap(find.byKey(const Key('pin-ok')));
    for (var i = 0; i < 20; i++) {
      await t.pump(const Duration(milliseconds: 50));
      if (find.byType(SellScreen).evaluate().isNotEmpty) break;
    }
    await t.pumpAndSettle();
  }

  Future<void> openShiftScreen(WidgetTester t) async {
    await t.tap(find.byKey(const Key('floor-takeaway')));
    await t.pumpAndSettle();
    await t.tap(find.byTooltip('Open navigation menu'));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('nav-shift')));
    await t.pumpAndSettle();
    expect(find.byType(ShiftScreen), findsOneWidget);
  }

  /// Type an amount on the till's number pad and accept it.
  Future<void> keyIn(WidgetTester t, String digits) async {
    for (final d in digits.split('')) {
      await t.tap(find.byKey(Key('key-$d')));
      await t.pump();
    }
    await t.tap(find.byKey(const Key('keypad-ok')));
    await t.pumpAndSettle();
  }

  /// The whole cash-up, from the Close button to the Z on screen.
  Future<void> closeTheShift(WidgetTester t) async {
    await t.tap(find.byKey(const Key('close-shift')));
    await t.pumpAndSettle();
    await keyIn(t, '100');
    await t.tap(find.byKey(const Key('confirm-close-shift')));
    await t.pumpAndSettle();
  }

  testWidgets('closing the shift sends the day to the owner', (t) async {
    mailConfigured();
    shifts.openShift(openingFloat: 100, cashierId: 'sara');

    await t.pumpWidget(app());
    await signIn(t);
    await openShiftScreen(t);
    await closeTheShift(t);

    expect(sent, hasLength(1), reason: 'the shell must hand the closed Z over');
    expect(sent.single.to, ['owner@shop.example']);
    expect(sent.single.subject, contains('Corner Cafe'));
    expect(sent.single.subject, contains('Z report'));
    // The figures a shop owner is waiting for, not a bare "shift closed".
    expect(sent.single.body, contains('Expected in drawer'));
    expect(sent.single.body, contains('Counted'));
    expect(sent.single.body, contains('Variance'));
    expect(shifts.currentOpenShift(), isNull);
  });

  testWidgets('a shop that never asked for mail gets none', (t) async {
    shifts.openShift(openingFloat: 100, cashierId: 'sara');

    await t.pumpWidget(app());
    await signIn(t);
    await openShiftScreen(t);
    await closeTheShift(t);

    expect(sent, isEmpty);
    expect(emailer.pending, 0, reason: 'nothing queued that can never be sent');
    expect(shifts.currentOpenShift(), isNull);
  });

  testWidgets('a mail server that is down does not stop the cash-up', (t) async {
    mailConfigured();
    mailDown = true;
    shifts.openShift(openingFloat: 100, cashierId: 'sara');

    await t.pumpWidget(app());
    await signIn(t);
    await openShiftScreen(t);
    await closeTheShift(t);

    // The close went through and the cashier was shown the Z, mail or no mail.
    expect(shifts.currentOpenShift(), isNull);
    expect(find.text('Z report'), findsWidgets);
    expect(sent, isEmpty);
    expect(emailer.pending, 1, reason: 'the report is queued, not lost');
  });

  testWidgets('a sender that throws outright still cannot fail a close',
      (t) async {
    mailConfigured();
    mailExplodes = true;
    shifts.openShift(openingFloat: 100, cashierId: 'sara');

    await t.pumpWidget(app());
    await signIn(t);
    await openShiftScreen(t);
    await closeTheShift(t);

    expect(shifts.currentOpenShift(), isNull);
    expect(t.takeException(), isNull,
        reason: 'a throwing sender must not surface as a crash mid cash-up');
  });

  testWidgets('a queued report goes out on its own once the line is back',
      (t) async {
    mailConfigured();
    mailDown = true;
    shifts.openShift(openingFloat: 100, cashierId: 'sara');

    await t.pumpWidget(app());
    await signIn(t);
    await openShiftScreen(t);
    await closeTheShift(t);
    expect(emailer.pending, 1);

    // The line comes back and the background catch-up lane finds it, with
    // nobody tapping anything.
    mailDown = false;
    clock = clock.add(const Duration(minutes: 6));
    // The catch-up lane runs on its own timer; nobody taps anything.
    await t.pump(const Duration(seconds: 31));
    await t.pumpAndSettle();

    expect(sent, hasLength(1));
    expect(emailer.pending, 0);
  });

  testWidgets('the settings screen is reachable and saves what is typed',
      (t) async {
    t.view.physicalSize = const Size(1000, 3200);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    shifts.openShift(openingFloat: 100, cashierId: 'sara');

    await t.pumpWidget(app());
    await signIn(t);
    await t.tap(find.byKey(const Key('floor-takeaway')));
    await t.pumpAndSettle();
    await t.tap(find.byTooltip('Open navigation menu'));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('nav-settings')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('set-email')));
    await t.pumpAndSettle();

    await t.enterText(find.byKey(const Key('email-recipients')),
        'owner@shop.example, accounts@shop.example');
    await t.enterText(find.byKey(const Key('email-from')), 'till@shop.example');
    await t.enterText(find.byKey(const Key('email-host')), 'mail.shop.example');
    await t.tap(find.byKey(const Key('email-enabled')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('email-save')));
    await t.pumpAndSettle();

    expect(settings.zReportRecipients,
        ['owner@shop.example', 'accounts@shop.example']);
    expect(settings.smtp, isNotNull, reason: 'the till can now send');
    expect(settings.smtp!.host, 'mail.shop.example');
  });
}
