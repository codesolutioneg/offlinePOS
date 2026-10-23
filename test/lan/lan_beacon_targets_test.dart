import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/lan/lan_beacon.dart';

/// A till that opened before its Wi-Fi joined has to start announcing on that
/// network once it is up, not only on the adapter it had at launch.
void main() {
  test('a network that comes up after launch is announced on', () async {
    var addresses = ['192.168.1.65'];
    final beacon = LanBeacon(
      deviceId: 'till-a',
      name: 'Front',
      httpPort: 45333,
      port: 0,
      interval: const Duration(milliseconds: 40),
      onPeer: (_) {},
      localAddresses: () async => addresses,
      bind: (address, port) =>
          RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0),
    );
    addTearDown(beacon.stop);

    expect(await beacon.start(), isTrue);
    expect(beacon.targets.map((a) => a.address), ['192.168.1.255']);

    addresses = ['192.168.1.65', '192.168.8.131'];
    await Future<void>.delayed(const Duration(milliseconds: 150));

    expect(beacon.targets.map((a) => a.address),
        containsAll(['192.168.1.255', '192.168.8.255']));
  });
}
