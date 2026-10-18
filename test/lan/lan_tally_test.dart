import 'dart:async';
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

  /// What each till reads on its clock as it answers; a day ahead when not set,
  /// past any bound a test asks for. A null entry is a build that sends none.
  final Map<String, DateTime?> clocks = {};
  final Map<String, Duration> offsets = {};
  final Map<String, Duration> spreads = {};

  @override
  Future<LanPage> fetch(LanPeer peer, int since) async => LanPage.empty;

  @override
  Future<void> notify(LanPeer peer, List<LanEvent> events, String deviceId) async {}

  @override
  Future<LanTallyReply> tally(
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
    return LanTallyReply(
      holds[peer.deviceId] ?? const [],
      clock: clocks.containsKey(peer.deviceId)
          ? clocks[peer.deviceId]
          : DateTime.now().toUtc().add(const Duration(days: 1)),
      clockOffset: offsets[peer.deviceId],
      clockSpread: spreads[peer.deviceId] ?? Duration.zero,
    );
  }
}

LanPeer _peer(String id, {DateTime? seen, Duration? clock}) => LanPeer(
      deviceId: id,
      name: id.toUpperCase(),
      host: '127.0.0.1',
      port: 45333,
      schemaVersion: Schema.version,
      lastSeenAt: seen ?? DateTime.now().toUtc(),
      clockOffset: clock,
    );

void main() {
  setUpAll(useSystemSqlite);

  group('a close bounded on every till\'s clock', () {
    final now = DateTime.utc(2026, 10, 17, 22);

    test('with the clocks in step it waits only the margin', () {
      final cut = closeCutoffFor(now, [Duration.zero]);
      expect(cut.at, now.add(kCloseClockMargin));
      expect(cut.askAfter, cut.at.add(kCloseClockMargin));
    });

    test('a sale rung now on a till ahead is inside, and every till has passed '
        'the bound when they are asked', () {
      const ahead = Duration(seconds: 5);
      const behind = Duration(seconds: 3);
      final cut = closeCutoffFor(now, [ahead, -behind, null]);

      // The sale is rung at this till's now; the till ahead stamps it 5s later.
      expect(now.add(ahead).isAfter(cut.at), isFalse);
      // When this till's clock reads askAfter, the slowest till reads 3s less,
      // and that is still past the bound: nothing can be stamped inside it.
      expect(cut.askAfter.subtract(behind).isAfter(cut.at), isTrue);
    });

    test('a till more than a minute out is named and not waited for', () {
      final far = _peer('till-b', clock: const Duration(minutes: 3));
      final cut = closeCutoffFor(now, [far.clockOffset]);
      expect(cut.at, now.add(kCloseClockMargin));
      final gaps = clockGaps(
          [far, _peer('till-c', clock: const Duration(seconds: 10))],
          (p) => p.clockOffset);
      expect(gaps.single.deviceId, 'till-b');
      expect(gaps.single.reason, 'its clock is more than a minute out');
    });

    test('a till is named when its clock had not passed the bound as it '
        'listed its sales, or did not say', () {
      final till = _peer('till-b');
      expect(clockShortGap(till, now.add(const Duration(milliseconds: 1)), now),
          isNull);
      expect(clockShortGap(till, now, now)!.reason,
          'its clock had not reached the close yet');
      expect(clockShortGap(till, null, now), isNotNull);
    });

    test('a till is named when it ran further ahead than the bound allowed '
        'for, and not when its offset was unknown', () {
      final till = _peer('till-b');
      const cover = Duration(seconds: 2);
      expect(clockAheadGap(till, cover, cover), isNull);
      expect(clockAheadGap(till, null, cover), isNull);
      // Half a slow round trip either way could put it past the bound.
      expect(
          clockAheadGap(till, const Duration(seconds: 1), cover,
              spread: const Duration(milliseconds: 1001)),
          isNotNull);
      expect(
          clockAheadGap(till, cover + const Duration(milliseconds: 1), cover)!
              .reason,
          'its clock ran ahead of the close');
    });
  });

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

    test('at the close a till more than a minute out is named and still '
        'asked, so what it holds is not hidden', () async {
      node.peers.seen(_peer('till-b', clock: const Duration(minutes: -2)));
      peers.holds['till-b'] = ['s1', 's2'];
      final until = DateTime.now().toUtc();

      final gaps = await node.catchUpBeforeClose(
          since: since, until: until, closing: true);
      expect([for (final g in gaps) g.reason], [
        'its clock is more than a minute out',
        '2 sales held there are not on this till yet',
      ]);
      expect(peers.asked, ['till-b']);
    });

    test('a check that is not the close does not hold on a till\'s clock',
        () async {
      node.peers.seen(_peer('till-b', clock: const Duration(minutes: 3)));
      peers.clocks['till-b'] = since;

      // The check before the count, and a resend of a session long closed.
      expect(await node.catchUpBeforeClose(since: since), isEmpty);
      expect(
          await node.catchUpBeforeClose(
              since: since, until: since.add(const Duration(hours: 7))),
          isEmpty);
    });

    test('a till whose clock had not reached the close as it answered is named',
        () async {
      node.peers.seen(_peer('till-b'));
      node.peers.seen(_peer('till-c'));
      final until = DateTime.now().toUtc();
      peers.clocks['till-b'] = until.subtract(const Duration(seconds: 1));
      peers.clocks['till-c'] = null;

      final gaps = await node.catchUpBeforeClose(
          since: since, until: until, closing: true);
      expect({for (final g in gaps) g.deviceId: g.reason}, {
        'till-b': 'its clock had not reached the close yet',
        'till-c': 'its clock had not reached the close yet',
      });
    });

    test('a till found at the close further ahead than the bound allowed for '
        'is named', () async {
      // Heard only from its requests, so the bound was chosen without it.
      node.peers.heard('till-b', host: '127.0.0.1', port: 45333);
      final until = await node.settleCloseCutoff(since);
      peers.offsets['till-b'] = const Duration(seconds: 5);

      final gaps = await node.catchUpBeforeClose(
          since: since, until: until, closing: true);
      expect(gaps.single.reason, 'its clock ran ahead of the close');
    });

    test('a till that may be past the bound once a slow answer is allowed for '
        'is named', () async {
      node.peers.heard('till-b', host: '127.0.0.1', port: 45333);
      final until = await node.settleCloseCutoff(since);
      peers.offsets['till-b'] = const Duration(seconds: 1);
      peers.spreads['till-b'] = const Duration(milliseconds: 1500);

      final gaps = await node.catchUpBeforeClose(
          since: since, until: until, closing: true);
      expect(gaps.single.reason, 'its clock ran ahead of the close');
    });

    test('a close not at the settled bound does not hold on how far ahead a '
        'till is', () async {
      node.peers.heard('till-b', host: '127.0.0.1', port: 45333);
      final settled = await node.settleCloseCutoff(since);
      peers.offsets['till-b'] = const Duration(seconds: 5);

      expect(
          await node.catchUpBeforeClose(
              since: since,
              until: settled!.subtract(const Duration(seconds: 1)),
              closing: true),
          isEmpty);
    });

    test('a till inside the bound it was settled for is not named', () async {
      node.peers.seen(_peer('till-b', clock: const Duration(milliseconds: 300)));
      final until = await node.settleCloseCutoff(since);
      peers.offsets['till-b'] = const Duration(milliseconds: 500);

      expect(
          await node.catchUpBeforeClose(
              since: since, until: until, closing: true),
          isEmpty);
    });

    test('a till whose beacon does not reach here is waited for by the offset '
        'its last answer showed', () async {
      // Heard only from its requests, so it carries no offset of its own.
      node.peers.heard('till-b', host: '127.0.0.1', port: 45333);
      expect(node.peers.all.single.clockOffset, isNull);
      peers.offsets['till-b'] = const Duration(milliseconds: 400);
      await node.catchUpBeforeClose(since: since);

      final started = DateTime.now().toUtc();
      final at = (await node.settleCloseCutoff(since))!;
      expect(
        at.isBefore(started
            .add(const Duration(milliseconds: 400))
            .add(kCloseClockMargin)),
        isFalse,
      );
    });

    test('the wait says when it ends, and a cancel stops it with no bound',
        () async {
      node.peers.seen(_peer('till-b', clock: const Duration(seconds: 20)));
      final cancel = Completer<void>();
      DateTime? readyAt;
      final started = DateTime.now().toUtc();

      final settling = node.settleCloseCutoff(since,
          onWait: (at) => readyAt = at, cancelled: cancel.future);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      cancel.complete();

      expect(await settling, isNull);
      expect(
          DateTime.now().toUtc().difference(started) < const Duration(seconds: 2),
          isTrue,
          reason: 'a cancel must not sit out the 20s wait');
      expect(readyAt!.isAfter(started.add(const Duration(seconds: 20))), isTrue);
    });

    test('with no other till on the network a close does not wait', () async {
      final started = DateTime.now().toUtc();
      final at = (await node.settleCloseCutoff(since))!;
      expect(at.difference(started) < const Duration(milliseconds: 500), isTrue);
    });

    test('the bound a close settles on is past every till\'s clock', () async {
      node.peers.seen(
        _peer('till-b', clock: const Duration(milliseconds: 300)),
      );
      node.peers.seen(
        _peer('till-c', clock: const Duration(milliseconds: -200)),
      );
      final started = DateTime.now().toUtc();

      final at = (await node.settleCloseCutoff(since))!;

      final done = DateTime.now().toUtc();
      expect(
        at.isBefore(started
            .add(const Duration(milliseconds: 300))
            .add(kCloseClockMargin)),
        isFalse,
      );
      // till-c, 200ms behind, is past the bound and the margin by then.
      expect(
        done
            .subtract(const Duration(milliseconds: 200))
            .subtract(kCloseClockMargin)
            .isBefore(at),
        isFalse,
      );
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

    test('the reasons a till\'s clock gives are translated', () {
      final far = clockGaps([_peer('till-b', clock: const Duration(hours: 1))],
              (p) => p.clockOffset)
          .single;
      final short = clockShortGap(_peer('till-b'), null, DateTime.utc(2026))!;
      final ahead = clockAheadGap(
          _peer('till-b'), const Duration(seconds: 5), Duration.zero)!;
      for (final gap in [far, short, ahead]) {
        expect(gapReasonIn(gap.reason, upper), gap.reason.toUpperCase());
      }
    });

    test('the primary missing is translated, anything else is left alone', () {
      expect(gapReasonIn('the primary is not on the network', upper),
          'THE PRIMARY IS NOT ON THE NETWORK');
      expect(gapReasonIn('something new', upper), 'something new');
    });
  });
}
