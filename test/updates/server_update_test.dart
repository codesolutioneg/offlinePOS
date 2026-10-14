import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/updates/server_update.dart';

import 'release_key.dart';

void main() {
  late HttpServer server;
  late String document;
  late ReleaseKey key;

  List<int> manifest(String version) => utf8.encode(jsonEncode({
        'version': version,
        'url': 'https://updates.example/offline-pos/$version.zip',
        'sha256': 'a' * 64,
        'size': 1234,
      }));

  setUp(() async {
    key = await ReleaseKey.generate();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) {
      request.response
        ..statusCode = 200
        ..write(document);
      request.response.close();
    });
  });

  tearDown(() => server.close(force: true));

  ServerUpdateChannel channel() => ServerUpdateChannel(
        manifestUrl: Uri.parse('http://127.0.0.1:${server.port}/manifest.json'),
        verifier: key.verifier,
      );

  test('a newer signed release is offered with its size', () async {
    document = await key.sign(manifest('1.1.1+9'));
    final release = await channel().check('1.1.1+7');
    expect(release, isNotNull);
    expect(release!.version, '1.1.1+9');
    expect(release.size, 1234);
  });

  test('the same or an older build is not offered', () async {
    document = await key.sign(manifest('1.1.1+7'));
    expect(await channel().check('1.1.1+7'), isNull);
    expect(await channel().check('1.1.2+1'), isNull);
  });

  test('a release signed by anyone else is refused', () async {
    document = await ReleaseKey.forged(manifest('1.1.1+9'));
    await expectLater(channel().check('1.1.1+7'), throwsFormatException);
    document = ReleaseKey.unsigned(manifest('1.1.1+9'));
    await expectLater(channel().check('1.1.1+7'), throwsFormatException);
  });

  test('an unreachable server is no update, not an error', () async {
    final port = server.port;
    await server.close(force: true);
    final offline = ServerUpdateChannel(
      manifestUrl: Uri.parse('http://127.0.0.1:$port/manifest.json'),
      verifier: key.verifier,
      timeout: const Duration(seconds: 2),
    );
    expect(await offline.check('1.1.1+7'), isNull);
  });

  test('the built-in release key is a usable Ed25519 key', () {
    expect(() => ServerUpdateChannel.release(), returnsNormally);
  });
}
