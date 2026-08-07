import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/sync/device_status.dart';
import 'package:offline_pos/core/updates/update_gate.dart';

/// Default hours: trading 08:00 until 04:00, so 05:15 is the quiet window and
/// 13:30 is the middle of service.
const gate = UpdateGate();
final quietHours = DateTime(2026, 3, 4, 5, 15);
final midService = DateTime(2026, 3, 4, 13, 30);

TillState till({
  required DateTime at,
  int pending = 0,
  int rejected = 0,
  bool selling = false,
  bool sole = true,
}) =>
    TillState(
      localTime: at,
      pendingSales: pending,
      rejectedSales: rejected,
      saleInProgress: selling,
      soleTill: sole,
    );

void main() {
  test('a quiet till outside trading hours may install', () {
    final decision = gate.evaluate(till(at: quietHours));
    expect(decision.allowed, isTrue);
    expect(decision.holds, isEmpty);
  });

  test('a till holding unsynced sales is never updated, even for a mandatory '
      'security update', () {
    final decision =
        gate.evaluate(till(at: quietHours, pending: 3), mandatory: true);
    expect(decision.allowed, isFalse);
    expect(decision.blockers, contains(UpdateBlocker.unsyncedSales));
    expect(decision.reason, contains('3 sales'));
  });

  test('a mandatory update still waits for the sale on screen', () {
    final decision =
        gate.evaluate(till(at: quietHours, selling: true), mandatory: true);
    expect(decision.allowed, isFalse);
    expect(decision.primary!.blocker, UpdateBlocker.saleInProgress);
  });

  test('sales the server refused hold the update until support has seen them', () {
    final decision =
        gate.evaluate(till(at: quietHours, rejected: 1), mandatory: true);
    expect(decision.allowed, isFalse);
    expect(decision.needsSupport, isTrue);
    expect(decision.reason, contains('1 sale has'));
  });

  test('a routine update waits until the shop stops trading', () {
    final decision = gate.evaluate(till(at: midService));
    expect(decision.allowed, isFalse);
    expect(decision.primary!.blocker, UpdateBlocker.serviceHours);
    // Nobody has to do anything: this one clears tonight on its own.
    expect(decision.clearsOnItsOwn, isTrue);
    expect(decision.needsSupport, isFalse);
  });

  test('the same update installs once service is over', () {
    expect(gate.evaluate(till(at: quietHours)).allowed, isTrue);
  });

  test('a mandatory security update overrides trading hours when another till '
      'can keep selling', () {
    final decision =
        gate.evaluate(till(at: midService, sole: false), mandatory: true);
    expect(decision.allowed, isTrue);
  });

  test('the only till in the shop never restarts mid-service, even for a '
      'security update', () {
    final decision =
        gate.evaluate(till(at: midService, sole: true), mandatory: true);
    expect(decision.allowed, isFalse);
    expect(decision.primary!.blocker, UpdateBlocker.soleTillInService);
  });

  test('every wait is explained, most serious reason first', () {
    final decision = gate.evaluate(
      till(at: midService, pending: 2, rejected: 1, selling: true),
    );
    expect(decision.holds.map((h) => h.blocker), [
      UpdateBlocker.unsyncedSales,
      UpdateBlocker.rejectedSales,
      UpdateBlocker.saleInProgress,
      UpdateBlocker.serviceHours,
    ]);
    expect(decision.reason, contains('2 sales have not reached the server'));
    expect(decision.reason, contains('A sale is open'));
  });

  test('trading hours that run past midnight still count as service', () {
    const hours = ServiceHours(opensAtHour: 8, closesAtHour: 4);
    expect(hours.contains(DateTime(2026, 3, 4, 1)), isTrue);
    expect(hours.contains(DateTime(2026, 3, 4, 23)), isTrue);
    expect(hours.contains(DateTime(2026, 3, 4, 4)), isFalse);
    expect(hours.contains(DateTime(2026, 3, 4, 7, 59)), isFalse);
  });

  test('a shop that never closes is never a safe moment on its own', () {
    const alwaysOpen = UpdateGate(hours: ServiceHours(opensAtHour: 0, closesAtHour: 0));
    expect(alwaysOpen.evaluate(till(at: quietHours)).allowed, isFalse);
    // A second till is what makes the restart survivable there.
    expect(
      alwaysOpen
          .evaluate(till(at: quietHours, sole: false), mandatory: true)
          .allowed,
      isTrue,
    );
  });

  test('the gate counts the same sales the heartbeat reports', () {
    final status = DeviceStatus(
      deviceId: 'till-1',
      appVersion: '1.0.0',
      at: DateTime.utc(2026, 3, 4, 5),
      pending: 2,
      dead: 1,
      unsyncedAudit: 0,
    );
    final decision = gate.evaluate(
      TillState.fromDeviceStatus(status, localTime: quietHours),
      mandatory: true,
    );
    expect(decision.blockers, {
      UpdateBlocker.unsyncedSales,
      UpdateBlocker.rejectedSales,
    });
  });
}
