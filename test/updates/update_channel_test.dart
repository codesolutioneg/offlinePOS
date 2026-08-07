import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/config/till_config.dart';
import 'package:offline_pos/core/updates/manifest_signature.dart';

import 'release_key.dart';

void main() {
  test('a key that is not an Ed25519 public key is refused, not truncated', () {
    expect(() => ManifestVerifier(List.filled(31, 0)), throwsArgumentError);
    expect(() => ManifestVerifier(const []), throwsArgumentError);
    expect(() => ManifestVerifier.fromBase64('not base64!!'),
        throwsA(isA<FormatException>()));
  });

  test('a document that is not a signed manifest is refused', () async {
    final release = await ReleaseKey.generate();
    final v = release.verifier;

    // A captive portal, a login page, an error body: all of them arrive looking
    // like this, and none of them may reach the manifest parser.
    expect(() => v.verify('<html>login</html>'), throwsA(isA<FormatException>()));
    expect(() => v.verify('{}'), throwsA(isA<FormatException>()));
    expect(() => v.verify(jsonEncode({'manifest': 'not base64!!', 'signature': 'x'})),
        throwsA(isA<FormatException>()));
  });

  group('an update channel is all or nothing', () {
    const url = 'https://updates.example/manifest.json';
    const key = 'cv1YzfPI48DKhfF67wnH/xsoU8wa6EcAHoM0NKUian8=';
    final pin = {'aa' * 32};

    test('fully specified, it is on', () {
      expect(
        TillConfig(
          updateManifestUrl: null,
          updatePublicKey: key,
          updateCertificatePins: pin,
        ).hasUpdateChannel,
        isFalse,
      );
      expect(
        TillConfig(
          updateManifestUrl: Uri.parse(url),
          updatePublicKey: key,
          updateCertificatePins: pin,
        ).hasUpdateChannel,
        isTrue,
      );
    });

    test('half specified, it is off rather than filled in with a default', () {
      // A missing release key or a missing pin filled in by a default is an
      // unsigned or unpinned auto-update, which docs/SECURITY.md calls remote code
      // execution on every till. Off is the only safe reading of "not configured".
      expect(
        TillConfig(updateManifestUrl: Uri.parse(url), updateCertificatePins: pin)
            .hasUpdateChannel,
        isFalse,
      );
      expect(
        TillConfig(updateManifestUrl: Uri.parse(url), updatePublicKey: key)
            .hasUpdateChannel,
        isFalse,
      );
    });

    test('nothing configured means no update channel at all', () {
      expect(const TillConfig().hasUpdateChannel, isFalse);
    });
  });

  test('a shop name is never invented', () {
    // A plausible placeholder on the paper hides from the installer that nobody
    // ever set the shop's name or its tax id, and a receipt without them is not a
    // legal receipt in most places.
    const config = TillConfig();
    expect(config.shopName, isEmpty);
    expect(config.taxId, isNull);
    expect(config.receiptFooter, isNull);
  });
}
