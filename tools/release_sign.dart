// Signs a release so tills will take it from the update server.
//
//   dart run tools/release_sign.dart keygen
//   dart run tools/release_sign.dart sign <zip> <version> <url> <out manifest.json>
//
// The private key lives in %USERPROFILE%\.offlinepos\release-signing-key.txt and
// never in this repository. Lose it and every till has to be updated by hand
// once with a build carrying a new public key, so keep a copy somewhere safe.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';
import 'package:offline_pos/core/updates/manifest_signature.dart';

final _ed25519 = Ed25519();

File get _keyFile {
  final home = Platform.environment['USERPROFILE'] ?? Platform.environment['HOME']!;
  return File('$home${Platform.pathSeparator}.offlinepos'
      '${Platform.pathSeparator}release-signing-key.txt');
}

Future<SimpleKeyPair> _loadKey() async {
  if (!_keyFile.existsSync()) {
    stderr.writeln('No signing key at ${_keyFile.path}. Run keygen first.');
    exit(2);
  }
  final seed = base64.decode(_keyFile.readAsStringSync().trim());
  return _ed25519.newKeyPairFromSeed(seed);
}

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('usage: keygen | public | sign <zip> <version> <url> <out>');
    exit(64);
  }
  switch (args.first) {
    case 'keygen':
      if (_keyFile.existsSync()) {
        stderr.writeln('A key already exists at ${_keyFile.path}; not replacing it.');
      } else {
        final pair = await _ed25519.newKeyPair();
        final seed = await pair.extractPrivateKeyBytes();
        _keyFile.parent.createSync(recursive: true);
        _keyFile.writeAsStringSync(base64.encode(seed));
        stderr.writeln('Wrote ${_keyFile.path}');
      }
      final public = await (await _loadKey()).extractPublicKey();
      stdout.writeln(base64.encode(public.bytes));
    case 'public':
      final public = await (await _loadKey()).extractPublicKey();
      stdout.writeln(base64.encode(public.bytes));
    case 'sign':
      if (args.length != 5) {
        stderr.writeln('usage: sign <zip> <version> <url> <out>');
        exit(64);
      }
      final zip = File(args[1]);
      final version = args[2];
      final url = args[3];
      final out = File(args[4]);
      final digest = (await crypto.sha256.bind(zip.openRead()).first).toString();
      final manifest = utf8.encode(jsonEncode({
        'version': version,
        'build_number': int.tryParse(version.split('+').last) ?? 0,
        'url': url,
        'sha256': digest,
        'size': zip.lengthSync(),
      }));
      final signature = await _ed25519.sign(manifest, keyPair: await _loadKey());
      out.writeAsStringSync(signedManifestDocument(
        manifestBytes: manifest,
        signature: signature.bytes,
      ));
      stdout.writeln('Signed $version ($digest) into ${out.path}');
    default:
      stderr.writeln('unknown command ${args.first}');
      exit(64);
  }
}
