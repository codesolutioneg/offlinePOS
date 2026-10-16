import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/db/schema.dart';
import 'package:offline_pos/core/lan/lan_credential.dart';
import 'package:offline_pos/core/lan/lan_peer.dart';
import 'package:offline_pos/core/lan/lan_transport.dart';
import 'package:offline_pos/core/lan/lan_update.dart';
import 'package:offline_pos/core/updates/app_build.dart';

import '../db/sqlite_loader.dart';
import 'shop.dart';

void main() {
  setUpAll(useSystemSqlite);

  group('AppBuild', () {
    test('reads a release build and orders by version, then build number', () {
      final a = AppBuild.tryParse('1.1.1+3')!;
      expect(AppBuild.tryParse('1.1.1+4')!.isNewerThan(a), isTrue);
      expect(AppBuild.tryParse('1.2.0+1')!.isNewerThan(a), isTrue);
      expect(AppBuild.tryParse('1.1.1+3')!.isNewerThan(a), isFalse);
      expect(AppBuild.tryParse('1.0.9+99')!.isNewerThan(a), isFalse);
    });

    test('a developer copy is not a build to offer or replace', () {
      expect(AppBuild.tryParse('0.0.0-dev'), isNull);
      expect(AppBuild.tryParse('test'), isNull);
      expect(AppBuild.tryParse(null), isNull);
    });
  });

  test('the real packer zips the program folder and leaves its logs behind', () async {
    final tmp = await Directory.systemTemp.createTemp('lan-pack-test');
    addTearDown(() => tmp.delete(recursive: true));
    final sep = Platform.pathSeparator;
    final from = Directory('${tmp.path}${sep}install')..createSync();
    File('${from.path}${sep}offline_pos.exe').writeAsStringSync('exe');
    File('${from.path}${sep}offline_pos_startup.log').writeAsStringSync('log');
    Directory('${from.path}${sep}data').createSync();
    File('${from.path}${sep}data${sep}app.so').writeAsStringSync('so');
    final zip = File('${tmp.path}${sep}out.zip');

    await LanUpdateOffer.packWithPowerShell(from, zip);

    final out = Directory('${tmp.path}${sep}out')..createSync();
    final r = await Process.run('powershell.exe', [
      '-NoProfile',
      '-Command',
      "Expand-Archive -LiteralPath '${zip.path}' -DestinationPath '${out.path}'",
    ]);
    expect(r.exitCode, 0, reason: '${r.stderr}');
    expect(File('${out.path}${sep}offline_pos.exe').existsSync(), isTrue);
    expect(File('${out.path}${sep}data${sep}app.so').existsSync(), isTrue);
    expect(File('${out.path}${sep}offline_pos_startup.log').existsSync(), isFalse);
  }, skip: !Platform.isWindows, timeout: const Timeout(Duration(minutes: 2)));

  group('the primary offers its build over the shop LAN', () {
    late TestShop shop;
    late TestTill primary;
    late Directory tmp;
    late LanHost host;
    late LanPeer peer;

    setUp(() async {
      shop = TestShop();
      tmp = await Directory.systemTemp.createTemp('lan-update-test');
      primary = shop.add('primary');
      final install = Directory('${tmp.path}${Platform.pathSeparator}install')
        ..createSync();
      primary.updateOffer = LanUpdateOffer(
        version: '1.1.1+4',
        installDirectory: install,
        cacheDirectory: Directory('${tmp.path}${Platform.pathSeparator}cache'),
        pack: (from, to) => to.writeAsString('the zipped build'),
      );
      host = LanHost(
        protocol: primary.protocol,
        port: 0,
        localAddresses: () async => ['127.0.0.1'],
        bind: (_, port) => HttpServer.bind(InternetAddress.loopbackIPv4, port),
      );
      expect(await host.start(), isTrue);
      peer = LanPeer(
        deviceId: 'primary',
        name: 'Primary',
        host: '127.0.0.1',
        port: host.boundPort!,
        schemaVersion: Schema.version,
        lastSeenAt: DateTime.now(),
      );
    });

    tearDown(() async {
      await host.stop();
      shop.close();
      await tmp.delete(recursive: true);
    });

    LanUpdateOffer offer() => primary.updateOffer!;

    test('the first ask starts packing, the next one gets a signed offer', () async {
      final client = LanHttpClient(credential: LanCredential(shop.shopKey));
      addTearDown(client.close);

      final first = await client.updateManifest(peer, deviceId: 'till-b');
      expect(first['ready'], isFalse);
      await offer().packed;

      final manifest = await client.updateManifest(peer, deviceId: 'till-b');
      expect(manifest['ready'], isTrue);
      expect(manifest['version'], '1.1.1+4');
      expect(manifest['size'], 'the zipped build'.length);
      expect(client.offerIsGenuine(manifest), isTrue);
      expect(client.offerIsGenuine({...manifest, 'sha256': 'beef'}), isFalse,
          reason: 'a digest swapped on the way is not what the primary signed');
    });

    test('the package downloads for a paired till, and for nobody else', () async {
      final client = LanHttpClient(credential: LanCredential(shop.shopKey));
      final stranger = LanHttpClient(credential: LanCredential('another-shop'));
      addTearDown(client.close);
      addTearDown(stranger.close);
      await client.updateManifest(peer, deviceId: 'till-b');
      await offer().packed;

      final got = File('${tmp.path}${Platform.pathSeparator}got.zip');
      await client.downloadUpdate(peer, deviceId: 'till-b', to: got);
      expect(await got.readAsString(), 'the zipped build');

      await expectLater(stranger.updateManifest(peer, deviceId: 'guest'),
          throwsA(isA<HttpException>()));
      await expectLater(
          stranger.downloadUpdate(peer,
              deviceId: 'guest', to: File('${tmp.path}${Platform.pathSeparator}no.zip')),
          throwsA(isA<HttpException>()));
    });

    test('a till that offers nothing says so', () async {
      primary.updateOffer = null;
      final client = LanHttpClient(credential: LanCredential(shop.shopKey));
      addTearDown(client.close);

      await expectLater(client.updateManifest(peer, deviceId: 'till-b'),
          throwsA(isA<HttpException>()));
    });
  });
}
