import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/db/schema.dart';
import 'package:offline_pos/core/lan/lan_peer.dart';
import 'package:offline_pos/domain/table_section_config.dart';

void main() {
  test('beacon map carries role for primary', () {
    final peer = LanPeer(
      deviceId: 'p1',
      name: 'Master',
      host: '10.0.0.2',
      port: 45333,
      schemaVersion: Schema.version,
      lastSeenAt: DateTime.utc(2026, 1, 1),
      role: DeviceRole.primary,
    );
    expect(peer.toMap()['role'], 'primary');
    final round = LanPeer.fromMap(peer.toMap(),
        host: '10.0.0.2', at: DateTime.utc(2026, 1, 1));
    expect(round.role, DeviceRole.primary);
  });

  test('primaryReached prefers stored device id', () {
    final master = LanPeer(
      deviceId: 'master-1',
      name: 'Master',
      host: '10.0.0.2',
      port: 45333,
      schemaVersion: Schema.version,
      lastSeenAt: DateTime.now().toUtc(),
      role: DeviceRole.primary,
    );
    final other = LanPeer(
      deviceId: 'till-b',
      name: 'Till B',
      host: '10.0.0.3',
      port: 45333,
      schemaVersion: Schema.version,
      lastSeenAt: DateTime.now().toUtc(),
      role: DeviceRole.secondary,
    );
    expect(
      primaryReached(activePeers: [other], primaryDeviceId: 'master-1'),
      isFalse,
    );
    expect(
      primaryReached(activePeers: [master, other], primaryDeviceId: 'master-1'),
      isTrue,
    );
  });

  test('primaryReached falls back to role when id unknown', () {
    final master = LanPeer(
      deviceId: 'p',
      name: 'Master',
      host: '10.0.0.2',
      port: 45333,
      schemaVersion: Schema.version,
      lastSeenAt: DateTime.now().toUtc(),
      role: DeviceRole.primary,
    );
    expect(
      primaryReached(activePeers: [master], primaryDeviceId: null),
      isTrue,
    );
    expect(
      primaryReached(activePeers: const [], primaryDeviceId: null),
      isFalse,
    );
  });
}
