import 'dart:convert';

import 'package:cryptography/cryptography.dart';

import 'update_manifest.dart';

/// Proves who wrote a manifest, which the digest inside it cannot.
///
/// The `sha256` in a manifest is an integrity check on the download and nothing
/// more: the digest and the binary url come out of the same document, so anyone
/// who can answer for the manifest host supplies both halves and the digest
/// matches perfectly. Authenticity has to rest on a key the manifest host does not
/// hold. Without that, an update channel is remote code execution on every till,
/// which is why docs/SECURITY.md makes a signed auto-update a hard rule.
///
/// The signed document wraps the manifest instead of carrying a signature field
/// inside it:
///
/// ```json
/// {"manifest": "<base64 of the manifest json bytes>", "signature": "<base64>"}
/// ```
///
/// A signature covers bytes, so the bytes have to survive the round trip
/// untouched. Re-serialising a decoded map to check a signature would make
/// verification depend on key order, whitespace and number formatting, and a
/// mismatch there is indistinguishable from a forgery.
class ManifestVerifier {
  factory ManifestVerifier(List<int> publicKey) {
    if (publicKey.length != _keyLength) {
      throw ArgumentError.value(
          publicKey.length, 'publicKey', 'an Ed25519 public key is 32 bytes');
    }
    return ManifestVerifier._(
        SimplePublicKey(List.of(publicKey), type: KeyPairType.ed25519));
  }

  ManifestVerifier._(this._key);

  /// The release public key as it is carried in the build.
  ///
  /// A public key is not a secret, so this is not a credential in the binary; it
  /// is the thing that makes the binary refuse anything the release server did
  /// not sign. Throws if the build was configured with a key that is not one,
  /// which is a property of the build rather than of the device: the same
  /// constant is in every copy of that binary, so it cannot start failing in the
  /// field without having failed on the first launch in test.
  factory ManifestVerifier.fromBase64(String encoded) {
    final List<int> bytes;
    try {
      bytes = base64.decode(encoded.trim());
    } on FormatException {
      throw const FormatException('the release public key is not valid base64');
    }
    return ManifestVerifier(bytes);
  }

  static const int _keyLength = 32;
  static final Ed25519 _ed25519 = Ed25519();

  final SimplePublicKey _key;

  /// The manifest [body] carries, or a [FormatException] if the document is
  /// malformed, unsigned, or signed by anyone other than the release key.
  ///
  /// The manifest is parsed only once the signature holds, so the parser is never
  /// handed bytes an attacker chose.
  Future<UpdateManifest> verify(String body) async {
    final Object? document = jsonDecode(body);
    if (document is! Map) {
      throw const FormatException('update document is not an object');
    }

    final payload = _base64Field(document['manifest'], 'manifest');
    final signature = _base64Field(document['signature'], 'signature');

    final signed = await _ed25519.verify(
      payload,
      signature: Signature(signature, publicKey: _key),
    );
    if (!signed) {
      throw const FormatException('manifest signature does not verify');
    }

    return UpdateManifest.fromJson(utf8.decode(payload));
  }

  static List<int> _base64Field(Object? value, String name) {
    if (value is! String || value.isEmpty) {
      throw FormatException('update document has no $name');
    }
    try {
      return base64.decode(value);
    } on FormatException {
      throw FormatException('update document $name is not base64');
    }
  }
}

/// Wraps manifest bytes and a signature into the document a till will accept.
///
/// Here so the shape lives in one place and the release tooling and the tests
/// cannot drift apart on it. Signing happens on the release server with the
/// private half, which never reaches this repository or a device.
String signedManifestDocument({
  required List<int> manifestBytes,
  required List<int> signature,
}) =>
    jsonEncode({
      'manifest': base64.encode(manifestBytes),
      'signature': base64.encode(signature),
    });
