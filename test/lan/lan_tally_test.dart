import 'dart:io';

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
  final Set<String> outdated = {};
  final List<String> asked = [];
  final List<DateTime> windows = [];
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
    windows.add(until);
    onAsk?.call();
    if (broken.contains(peer.deviceId)) {
      throw StateError('${peer.deviceId} timed out');
    }
    if (outdated.contains(peer.deviceId)) {
      // What the client throws when a build without the tally answers.
      throw HttpException(
          '404 from ${peer.baseUrl}/lan/tally: {"error":"unknown path"}');
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
      expect(gaps.single.reason, '1 sale held there is not on this till yet');
    });

    test('several missing sales are counted in the reason', () {
      final gaps = tallyGaps(
        local: const {},
        answers: [LanTallyAnswer.counted(_peer('till-b'), {'a', 'b', 'c'})],
      );
      expect(gaps.single.reason, '3 sales held there are not on this till yet');
    });

    test('a till that could not be asked is a gap in its own words', () {
      final gaps = tallyGaps(
        local: {'a'},
        answers: [LanTallyAnswer.failed(_peer('till-b'), 'timed out')],
      );
      expect(gaps.single.reason, 'could not list its sales: timed out');
    });

    test('a till on an older build is told to be updated', () {
      final gaps = tallyGaps(
        local: {'a'},
        answers: [LanTallyAnswer.outdated(_peer('till-b'))],
      );
      expect(gaps.single.reason, 'runs an older version and has to be updated');
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
      expect(gaps.single.reason, '1 sale held there is not on this till yet');
    });

    test('a till that cannot answer is named, not assumed level', () async {
      node.peers.seen(_peer('till-b'));
      peers.broken.add('till-b');

      final gaps = await node.catchUpBeforeClose(since: since);
      expect(gaps.single.deviceId, 'till-b');
      expect(gaps.single.reason, startsWith('could not list its sales:'));
    });

    test('a till on an older build holds the close and is named to be updated',
        () async {
      node.peers.seen(_peer('till-b'));
      peers.outdated.add('till-b');

      final gaps = await node.catchUpBeforeClose(since: since);
      expect(gaps.single.deviceId, 'till-b');
      expect(gaps.single.reason, 'runs an older version and has to be updated');
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

    test('a close asks the tills up to now', () async {
      node.peers.seen(_peer('till-b'));
      final before = DateTime.now().toUtc();

      await node.catchUpBeforeClose(since: since);
      final after = DateTime.now().toUtc();
      expect(peers.windows.single.isBefore(before), isFalse);
      expect(peers.windows.single.isAfter(after), isFalse);
    });

    test('a resend asks the tills up to the moment the session closed',
        () async {
      // Last night's session sent again this morning: the other tills have
      // rung new sales since, and those belong to today, not to the resend.
      node.peers.seen(_peer('till-b'));
      final closedAt = since.add(const Duration(hours: 7));

      await node.catchUpBeforeClose(since: since, until: closedAt);
      expect(peers.windows.single, closedAt);
    });

    test('the status line tells the cashier the tills are being checked',
        () async {
      node.peers.seen(_peer('till-b'));
      final seen = <String>[];

      await node.catchUpBeforeClose(since: since, onProgress: seen.add);
      expect(seen, contains('Checking every till handed over its sales...'));
    });
  });

  group('LanTallyAnswer.fromError', () {
    test('a 404 from the tally path means the till predates it', () {
      final answer = LanTallyAnswer.fromError(
          _peer('till-b'),
          const HttpException(
              '404 from http://127.0.0.1:45333/lan/tally: {"error":"unknown path"}'));
      expect(answer.outdated, isTrue);
      expect(answer.error, isNull);
    });

    test('a 404 that is not the unknown path keeps its own words', () {
      final answer = LanTallyAnswer.fromError(
          _peer('till-b'),
          const HttpException(
              '404 from http://127.0.0.1:45333/lan/tally: {"error":"no such shift"}'));
      expect(answer.outdated, isFalse);
      expect(answer.error, contains('no such shift'));
    });

    test('any other failure keeps its own words', () {
      final refused = LanTallyAnswer.fromError(_peer('till-b'),
          const HttpException('409 from http://127.0.0.1:45333/lan/tally: no'));
      expect(refused.outdated, isFalse);
      expect(refused.error, startsWith('HttpException: 409'));

      final silent =
          LanTallyAnswer.fromError(_peer('till-b'), StateError('timed out'));
      expect(silent.outdated, isFalse);
      expect(silent.error, contains('timed out'));
    });
  });

  group('gapReasonIn', () {
    String upper(String en) => en.toUpperCase();

    test('every reason the tally gives is translated', () {
      final failed = tallyGaps(local: {}, answers: [
        LanTallyAnswer.failed(_peer('till-b'), 'timed out'),
      ]).single;
      expect(gapReasonIn(failed.reason, upper), isNot(failed.reason));
      for (final short in [1, 3]) {
        final gap = tallyGaps(local: {}, answers: [
          LanTallyAnswer.counted(
              _peer('till-b'), {for (var i = 0; i < short; i++) 's$i'}),
        ]).single;
        expect(gapReasonIn(gap.reason, upper), isNot(gap.reason),
            reason: gap.reason);
      }
    });

    test('a count is kept and put in the translated sentence', () {
      final ar = {
        '{n} sales held there are not on this till yet': '{n} مبيعات',
      };
      expect(gapReasonIn('3 sales held there are not on this till yet',
          (en) => ar[en] ?? en), '3 مبيعات');
      expect(gapReasonIn('1 sale held there is not on this till yet', upper),
          '1 SALE HELD THERE IS NOT ON THIS TILL YET');
    });

    test('a failed listing keeps the error after the translated text', () {
      expect(gapReasonIn('could not list its sales: timed out', upper),
          'COULD NOT LIST ITS SALES: timed out');
    });

    test('an outdated till is translated', () {
      expect(gapReasonIn('runs an older version and has to be updated', upper),
          'RUNS AN OLDER VERSION AND HAS TO BE UPDATED');
    });

    test('the primary missing is translated, anything else is left alone', () {
      expect(gapReasonIn('the primary is not on the network', upper),
          'THE PRIMARY IS NOT ON THE NETWORK');
      expect(gapReasonIn('something new', upper), 'something new');
    });
  });
}
