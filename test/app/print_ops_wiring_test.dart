import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/app/pos_app.dart';
import 'package:offline_pos/core/audit/audit_log.dart';
import 'package:offline_pos/core/auth/auth_service.dart';
import 'package:offline_pos/core/auth/user_store.dart';
import 'package:offline_pos/core/db/attendance_store.dart';
import 'package:offline_pos/core/db/catalogue_store.dart';
import 'package:offline_pos/core/db/customer_store.dart';
import 'package:offline_pos/core/db/database.dart';
import 'package:offline_pos/core/db/order_store.dart';
import 'package:offline_pos/core/db/settings_store.dart';
import 'package:offline_pos/core/db/shift_store.dart';
import 'package:offline_pos/core/db/sqlite_outbox_store.dart';
import 'package:offline_pos/core/db/table_store.dart';
import 'package:offline_pos/core/onboarding/wizard_store.dart';
import 'package:offline_pos/core/printing/printer_discovery.dart';
import 'package:offline_pos/core/printing/printer_logo.dart';
import 'package:offline_pos/core/printing/printer_registry.dart';
import 'package:offline_pos/core/printing/printer_transport.dart';
import 'package:offline_pos/core/printing/spool_store.dart';
import 'package:offline_pos/core/sync/odoo_endpoint.dart';
import 'package:offline_pos/core/sync/odoo_wiring.dart';
import 'package:offline_pos/core/sync/outbox.dart';
import 'package:offline_pos/core/sync/sync_service.dart';
import 'package:offline_pos/domain/catalogue.dart';
import 'package:offline_pos/features/sell/sell_screen.dart';
import 'package:offline_pos/features/tables/table_floor_screen.dart';

import '../db/sqlite_loader.dart';
import '../ui/fake_pin_hasher.dart';

/// Nothing answers a sweep, so every slip lands in the spool instead of on paper,
/// which is how a test reads what the printer would have produced.
class _NoPrinters extends PrinterDiscovery {
  @override
  Future<bool> probe(String host, {int? port}) async => false;

  @override
  Future<List<DiscoveredPrinter>> scan({int? port, Duration? budget}) async => const [];
}

/// Only these hosts are switched on. A sweep finds nothing, because a test shop has
/// no subnet.
class _Subnet extends PrinterDiscovery {
  _Subnet(this.answering);

  final Set<String> answering;

  @override
  Future<bool> probe(String host, {int? port}) async => answering.contains(host);

  @override
  Future<List<DiscoveredPrinter>> scan({int? port, Duration? budget}) async => const [];
}

/// A printer that keeps what it was handed instead of burning it.
class _Paper implements PrinterTransport {
  final List<Uint8List> jobs = [];

  @override
  Future<void> send(Uint8List bytes) async => jobs.add(bytes);
}

/// Printers do not answer a reverse lookup here, and a real one would put a DNS
/// round trip in the middle of every sale.
Future<String?> _anonymous(String host, int port) async => null;

/// The printed text of a job, with the control bytes taken out.
String printed(Uint8List bytes) {
  final out = <int>[];
  var i = 0;
  while (i < bytes.length) {
    final b = bytes[i];
    if (b == 0x1b) {
      final cmd = i + 1 < bytes.length ? bytes[i + 1] : 0;
      i += switch (cmd) {
        0x40 => 2,
        0x61 || 0x45 || 0x21 || 0x74 => 3,
        0x70 => 5,
        _ => 2,
      };
      continue;
    }
    if (b == 0x1d) {
      i += 4;
      continue;
    }
    out.add(b);
    i++;
  }
  return String.fromCharCodes(out);
}

/// What a cashier's sale actually puts on paper, rung on a real app shell.
///
/// The layouts are covered in test/printing. What is covered here is the seam: a
/// setting nobody reads at print time is a feature that ships dead, so each of these
/// configures the shop and then sells something.
void main() {
  late Db db;
  late OrderStore orders;
  late SqliteOutboxStore outboxStore;
  late AuditLog audit;
  late SettingsStore settings;
  late MemorySpoolStore spool;

  /// Replaced by a test that wants printers that actually answer.
  late PrinterRegistry printers;

  setUpAll(useSystemSqlite);
  setUp(() async {
    db = Db.open(':memory:');
    // The till refuses to start an order with no shift open, so a test that
    // sells opens the drawer first.
    ShiftStore(db).openShift(openingFloat: 100, cashierId: 'sara');
    orders = OrderStore(db, ownDeviceId: 'till-1');
    outboxStore = SqliteOutboxStore(db);
    audit = AuditLog(db);
    settings = SettingsStore(db);
    spool = MemorySpoolStore();
    printers = PrinterRegistry(discovery: _NoPrinters());
    CatalogueStore(db).replaceAll(
      categories: const [Category(id: 1, name: 'Food')],
      products: const [Product(id: 10, name: 'Pizza', price: 250, categoryId: 1)],
      groups: const [],
      productGroupIds: const {},
      paymentMethods: const [
        PaymentMethod(id: 1, name: 'Cash', isCash: true),
        PaymentMethod(id: 2, name: 'Card'),
      ],
      refreshedAt: DateTime.now().toUtc(),
    );
  });
  tearDown(() => db.close());

  Future<AuthService> cashierOnTheTill() async {
    final auth = AuthService(
        users: UserStore(db), hasher: FakePinHasher(), audit: AuditLog(db));
    await auth.enrol(id: 'sara', name: 'Sara', pin: '1234', role: 'manager');
    return auth;
  }

  Widget app(AuthService auth) {
    final outbox = Outbox(store: outboxStore, senders: {});
    return PosApp(
      auth: auth,
      users: UserStore(db),
      catalogue: CatalogueStore(db),
      orders: orders,
      outbox: outbox,
      audit: audit,
      sync: SyncService(
        outbox: outbox,
        catalogue: CatalogueStore(db),
        outboxStore: outboxStore,
        deviceId: 'till-1',
        appVersion: 'test',
      ),
      outboxStore: outboxStore,
      printers: printers,
      wizards: WizardStore(db),
      shifts: ShiftStore(db),
      deviceId: 'till-1',
      endpoints: OdooEndpointStore(db),
      odoo: OdooWiring(outbox: outbox),
      tables: TableStore(db),
      settings: settings,
      customers: CustomerStore(db),
      attendance: AttendanceStore(db),
      receiptSpool: spool,
    );
  }

  /// What the printer would have produced, by spool reference prefix.
  Future<List<String>> slipsMatching(String prefix) async {
    final jobs = await spool.oldestFirst(limit: 100);
    return jobs
        .where((j) => (j.reference ?? '').startsWith(prefix))
        .map((j) => String.fromCharCodes(j.bytes))
        .toList();
  }

  /// The raw bytes of the one slip whose reference starts with [prefix].
  Future<List<int>> bytesMatching(String prefix) async {
    final jobs = await spool.oldestFirst(limit: 100);
    return jobs
        .firstWhere((j) => (j.reference ?? '').startsWith(prefix))
        .bytes
        .toList();
  }

  /// Whether [needle] appears anywhere in [haystack], which is how a command is
  /// found in a document that is mostly text.
  bool containsBytes(List<int> haystack, List<int> needle) {
    for (var i = 0; i + needle.length <= haystack.length; i++) {
      var hit = true;
      for (var j = 0; j < needle.length; j++) {
        if (haystack[i + j] != needle[j]) {
          hit = false;
          break;
        }
      }
      if (hit) return true;
    }
    return false;
  }

  Future<void> signIn(WidgetTester t) async {
    await t.tap(find.byKey(const Key('user-sara')));
    await t.pump();
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
    if (find.byType(TableFloorScreen).evaluate().isNotEmpty) {
      await t.pageBack();
      await t.pumpAndSettle();
    }
    await t.tap(find.byKey(const Key('wizard-skip')));
    await t.pumpAndSettle();
  }

  /// One pizza, tendered on the card, exactly as a cashier rings it.
  Future<void> sellAPizza(WidgetTester t, {int method = 2}) async {
    await t.binding.setSurfaceSize(const Size(1280, 1000));
    addTearDown(() => t.binding.setSurfaceSize(null));
    await t.pumpWidget(app(await cashierOnTheTill()));
    await signIn(t);
    await t.tap(find.byKey(const Key('product-10')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('pay')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(Key('method-$method')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('confirm-payment')));
    await t.pumpAndSettle();
  }

  group('the copy for the pass', () {
    testWidgets('a sale prints a second, priceless slip to the chosen station',
        (t) async {
      settings.subReceiptStation = 'kitchen';

      await sellAPizza(t);

      final copies = await slipsMatching('subreceipt-');
      expect(copies, hasLength(1),
          reason: 'the shell must send the copy, or the setting is dead');
      // The pass gets the order, not the money: names and quantities, no amounts.
      expect(copies.single, contains('Pizza'));
      expect(copies.single, isNot(contains('250.00')));
      // And the customer's own slip is untouched by any of it.
      final sale = orders.recent(limit: 1).single;
      final receipt = await slipsMatching(sale.uuid);
      expect(receipt.single, contains('250.00'));
    });

    testWidgets('with prices left on, the copy carries them', (t) async {
      settings.subReceiptStation = 'kitchen';
      settings.subReceiptHidePrices = false;

      await sellAPizza(t);

      final copies = await slipsMatching('subreceipt-');
      expect(copies.single, contains('250.00'));
    });

    testWidgets('no station configured prints the customer slip and nothing else',
        (t) async {
      await sellAPizza(t);

      expect(await slipsMatching('subreceipt-'), isEmpty);
      final sale = orders.recent(limit: 1).single;
      expect(await slipsMatching(sale.uuid), hasLength(1));
    });
  });

  group('the shop logo', () {
    testWidgets('a sale asks the printer for the mark it is holding', (t) async {
      settings.receiptPrintLogo = true;

      await sellAPizza(t);

      final sale = orders.recent(limit: 1).single;
      final bytes = await bytesMatching(sale.uuid);
      // FS p 1 0: print stored image 1. Four bytes, no picture on the wire.
      expect(containsBytes(bytes, const [0x1c, 0x70, 1, 0]), isTrue,
          reason: 'the shell must read the logo setting at print time');
    });

    testWidgets('the fallback sends the dots themselves', (t) async {
      settings.receiptPrintLogo = true;
      settings.receiptLogoRaster = true;
      settings.receiptLogo =
          PrinterLogo(widthDots: 8, heightDots: 8, bits: Uint8List(8)..[0] = 0x80);

      await sellAPizza(t);

      final sale = orders.recent(limit: 1).single;
      final bytes = await bytesMatching(sale.uuid);
      expect(containsBytes(bytes, const [0x1c, 0x70, 1, 0]), isFalse);
      // GS v 0, one byte across, eight dots down.
      expect(containsBytes(bytes, const [0x1d, 0x76, 0x30, 0x00, 1, 0, 8, 0]), isTrue);
    });

    testWidgets('a till with no logo prints exactly what it always printed',
        (t) async {
      await sellAPizza(t);

      final sale = orders.recent(limit: 1).single;
      final bytes = await bytesMatching(sale.uuid);
      expect(containsBytes(bytes, const [0x1c, 0x70, 1, 0]), isFalse);
      expect(containsBytes(bytes, const [0x1d, 0x76, 0x30, 0x00]), isFalse);
    });
  });

  group('what a tender is called', () {
    testWidgets('the printed name overrides the method name on the slip',
        (t) async {
      settings.setPaymentMethodLabel(2, 'Visa / Mastercard');

      await sellAPizza(t);

      final sale = orders.recent(limit: 1).single;
      final receipt = (await slipsMatching(sale.uuid)).single;
      expect(receipt, contains('Visa / Mastercard'));
      expect(receipt, isNot(contains('Card ')));
    });

    testWidgets('the sale itself and what goes to the server are untouched',
        (t) async {
      settings.setPaymentMethodLabel(2, 'Visa / Mastercard');

      await sellAPizza(t);

      final sale = orders.recent(limit: 1).single;
      // The tender keeps the id it was rung with and the name it was rung under,
      // so every report and the booking still see the method itself.
      expect(sale.payments.single.methodId, 2);
      expect(sale.payments.single.label, 'Card');
      final queued = await outboxStore.pending();
      final payments = queued.single.payload['payments'] as List;
      expect((payments.single as Map)['method_id'], 2);
      expect((payments.single as Map)['label'], 'Card');
    });

    testWidgets('with no override the method prints as it always did', (t) async {
      await sellAPizza(t);

      final sale = orders.recent(limit: 1).single;
      expect((await slipsMatching(sale.uuid)).single, contains('Card'));
    });
  });

  group('when the receipt printer is off', () {
    testWidgets('the sale prints on the spare, and the paper says so', (t) async {
      final papers = <String, _Paper>{};
      // The receipt printer is dead; the spare in the office is not.
      printers = PrinterRegistry(
        discovery: _Subnet({'10.0.0.9'}),
        identify: _anonymous,
        open: (host, port) => papers.putIfAbsent(host, () => _Paper()),
      );
      printers.remember('receipt', host: '10.0.0.5', backup: 'spare');
      printers.remember('spare', host: '10.0.0.9');

      await sellAPizza(t);

      expect(papers['10.0.0.5'], isNull, reason: 'the dead printer took nothing');
      final onTheSpare =
          (papers['10.0.0.9']?.jobs ?? const <Uint8List>[]).map(printed).toList();
      final receipt = onTheSpare.where((j) => j.contains('TOTAL')).toList();
      expect(receipt, hasLength(1),
          reason: 'the sale slip must reach the spare, not only the spool');
      expect(receipt.single, contains('REROUTED FROM RECEIPT'));
      // Nothing is held: the paper exists, so there is nothing to reprint.
      expect(await spool.oldestFirst(), isEmpty);
    });

    testWidgets('with no spare the sale is held for the printer it belongs to',
        (t) async {
      final papers = <String, _Paper>{};
      printers = PrinterRegistry(
        discovery: _Subnet({'10.0.0.9'}),
        identify: _anonymous,
        open: (host, port) => papers.putIfAbsent(host, () => _Paper()),
      );
      printers.remember('receipt', host: '10.0.0.5');
      printers.remember('spare', host: '10.0.0.9');

      await sellAPizza(t);

      expect(papers['10.0.0.9'], isNull, reason: 'nothing reroutes unasked');
      final sale = orders.recent(limit: 1).single;
      expect(await slipsMatching(sale.uuid), hasLength(1));
    });
  });
}
