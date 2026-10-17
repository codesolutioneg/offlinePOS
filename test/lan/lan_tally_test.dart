import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/audit/audit_log.dart';
import 'package:offline_pos/core/auth/user_store.dart';
import 'package:offline_pos/core/db/database.dart';
import 'package:offline_pos/core/db/order_store.dart';
import 'package:offline_pos/core/db/reservation_store.dart';
import 'package:offline_pos/core/db/schema.dart';
import 'package:offline_pos/core/db/settings_store.dart';
import 'package:offline_pos/core/db/table_assignment_store.dart';
import 'package:offline_pos/core/db/table_store.dart';
import 'package:offline_pos/core/lan/lan_credential.dart';
import 'package:offline_pos/core/lan/lan_event.dart';
import 'package:offline_pos/core/lan/lan_peer.dart';
import 'package:offline_pos/core/lan/lan_tally.dart';
import 'package:offline_pos/core/lan/lan_transport.dart';
import 'package:offline_pos/core/lan/lan_wiring.dart';
import 'package:offline_pos/core/printing/printer_discovery.dart';
import 'package:offline_pos/core/printing/printer_registry.dart';
import 'package:offline_pos/core/sync/odoo_endpoint.dart';
import 'package:offline_pos/domain/order.dart';

import '../db/sqlite_loader.dart';
import 'lan_wiring_test.dart' show FakeDatagramSocket;

class _NoPrinters extends PrinterDiscovery {
  @override
  Future<bool> probe(String host, {int? port}) async => false;

  @override
  Future<List<DiscoveredPrinter>> scan({int? port, Duration? budget}) async =>
      const [];
}

/// The other tills, answered without a network: each one's sale list, or a
/// failure, keyed by device id. Reads come back empty, so the catch-up before
/// the tally has nothing to pull and the tally is what finds the gap.
class _Peers extends LanHttpClient {
  _Peers() : super(credential: LanCredential('the-shop-key'));

  final Map<String, List<String>> holds = {};
  final Set<String> broken = {};
  final List<String> asked = [];
  void Function()? onAsk;

  @override
  Future<LanPage> fetch(LanPeer peer, int since) async => LanPage.empty;

  @override
  Future<void> notify(LanPeer peer, List<LanEvent> events, String deviceId) async {}

  @override
  Future<List<String>> tally(
    LanPeer peer, {
    required String deviceId,
    required DateTime since,
    required DateTime until,
  }) async {
    asked.add(peer.deviceId);
    onAsk?.call();
    if (broken.contains(peer.deviceId)) {
      throw StateError('${peer.deviceId} timed out');
    }
    return holds[peer.deviceId] ?? const [];
  }
}

LanPeer _peer(String id, {DateTime? seen}) => LanPeer(
      deviceId: id,
      name: id.toUpperCase(),
      host: '127.0.0.1',
      port: 45333,
      schemaVersion: Schema.version,
      lastSeenAt: seen ?? DateTime.now().toUtc(),
    );

void main() {
  setUpAll(useSystemSqlite);

  group('tallyGaps', () {
    test('a till whose every sale is held here is not a gap', () {
      final gaps = tallyGaps(
        local: {'a', 'b', 'c'},
        answers: [LanTallyAnswer.counted(_peer('till-b'), {'a', 'b'})],
      );
      expect(gaps, isEmpty);
    });

    test('a sale rung on a till and not held here names that till', () {
      final gaps = tallyGaps(
        local: {'a'},
        answers: [LanTallyAnswer.counted(_peer('till-b'), {'a', 'b'})],
      );
      expect(gaps.single.deviceId, 'till-b');
      expect(gaps.single.name, 'TILL-B');
      expect(gaps.single.reason, '1 sale rung there is not on this till yet');
    });

    test('several missing sales are counted in the reason', () {
      final gaps = tallyGaps(
        local: const {},
        answers: [LanTallyAnswer.counted(_peer('till-b'), {'a', 'b', 'c'})],
      );
      expect(gaps.single.reason, '3 sales rung there are not on this till yet');
    });

    test('a till that could not be asked is a gap in its own words', () {
      final gaps = tallyGaps(
        local: {'a'},
        answers: [LanTallyAnswer.failed(_peer('till-b'), 'timed out')],
      );
      expect(gaps.single.reason, 'could not list its sales: timed out');
    });

    test('sales only this till holds are not a gap anywhere', () {
      // The other till being short is its problem at its own close; this close
      // only has to prove it holds everything the others rang.
      final gaps = tallyGaps(
        local: {'a', 'mine'},
        answers: [LanTallyAnswer.counted(_peer('till-b'), {'a'})],
      );
      expect(gaps, isEmpty);
    });

    test('each till is judged on its own', () {
      final gaps = tallyGaps(
        local: {'a'},
        answers: [
          LanTallyAnswer.counted(_peer('till-b'), {'a'}),
          LanTallyAnswer.counted(_peer('till-c'), {'c'}),
          LanTallyAnswer.failed(_peer('till-d'), 'unreachable'),
        ],
      );
      expect(gaps.map((g) => g.deviceId), ['till-c', 'till-d']);
    });
  });

  group('catchUpBeforeClose asks every till for its sales', () {
    late Db db;
    late OrderStore orders;
    late _Peers peers;
    late LanNode node;
    final since = DateTime.now().toUtc().subtract(const Duration(hours: 8));

    setUp(() {
      db = Db.open(':memory:');
      orders = OrderStore(db, ownDeviceId: 'till-a');
      peers = _Peers();
      node = LanNode.build(
        db: db,
        deviceId: 'till-a',
        deviceName: 'Front',
        shopKey: () => 'the-shop-key',
        orders: orders,
        tables: TableStore(db),
        settings: SettingsStore(db),
        users: UserStore(db),
        printers: PrinterRegistry(discovery: _NoPrinters()),
        endpoints: OdooEndpointStore(db),
        reservations: ReservationStore(db),
        assignments: TableAssignmentStore(db),
        audit: AuditLog(db),
        port: 0,
        beaconPort: 0,
        localAddresses: () async => const [],
        beaconBind: (_, _) async => FakeDatagramSocket(),
        client: peers,
      );
    });
    tearDown(() async {
      await node.dispose();
      db.close();
    });

    Order rung(String device, {DateTime? at, String? uuid}) {
      final o = Order(
        uuid: uuid,
        deviceId: device,
        cashierId: 'sara',
        createdAt: (at ?? DateTime.now()).toUtc(),
      )..lines.add(OrderLine(productId: 1, name: 'Tea', quantity: 1, unitPrice: 10));
      o.payments = [OrderPayment(methodId: 1, amount: o.total, label: 'Cash')];
      o.state = OrderState.paid;
      orders.save(o, announce: false);
      return o;
    }

    test('a till in step with this one leaves no gap', () async {
      final theirs = rung('till-b');
      node.peers.seen(_peer('till-b'));
      peers.holds['till-b'] = [theirs.uuid];

      expect(await node.catchUpBeforeClose(since: since), isEmpty);
      expect(peers.asked, ['till-b']);
    });

    test('a sale the other till rang and this one never received is the gap',
        () async {
      // The pull above came back empty, as it does when the till was read through
      // the primary or a page was cut short: nothing failed, the sale is still
      // not here. Only the tally sees that.
      rung('till-b');
      node.peers.seen(_peer('till-b'));
      peers.holds['till-b'] = ['never-arrived'];

      final gaps = await node.catchUpBeforeClose(since: since);
      expect(gaps.single.deviceId, 'till-b');
      expect(gaps.single.reason, '1 sale rung there is not on this till yet');
    });

    test('a till that cannot answer is named, not assumed level', () async {
      node.peers.seen(_peer('till-b'));
      peers.broken.add('till-b');

      final gaps = await node.catchUpBeforeClose(since: since);
      expect(gaps.single.deviceId, 'till-b');
      expect(gaps.single.reason, startsWith('could not list its sales:'));
    });

    test('a till last seen before the window opened is not asked', () async {
      node.peers.seen(_peer('till-b'));
      final later = DateTime.now().toUtc().add(const Duration(hours: 1));

      expect(await node.catchUpBeforeClose(since: later), isEmpty);
      expect(peers.asked, isEmpty);
    });

    test('a sale that lands while the tills are being asked counts as held',
        () async {
      node.peers.seen(_peer('till-b'));
      peers.holds['till-b'] = ['late-one'];
      // Same uuid as what the peer answers: it arrives between the ask and the
      // local read.
      peers.onAsk = () => rung('till-b',
          uuid: 'late-one', at: since.add(const Duration(hours: 1)));

      expect(await node.catchUpBeforeClose(since: since), isEmpty);
    });

    test('the status line tells the cashier the tills are being checked',
        () async {
      node.peers.seen(_peer('till-b'));
      final seen = <String>[];

      await node.catchUpBeforeClose(since: since, onProgress: seen.add);
      expect(seen, contains('Checking every till handed over its sales...'));
    });
  });
}
