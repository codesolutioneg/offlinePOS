import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:offline_pos/core/updates/manifest_signature.dart';

/// Stands in for the release server's Ed25519 signing key.
///
/// A test holds both halves because it plays both sides. In production only the
/// public half is in the binary and the private half never leaves the release
/// server, which is the whole reason a signature says anything the manifest's own
/// digest cannot.
class ReleaseKey {
  ReleaseKey._(this._pair, this.verifier);

  static final Ed25519 _ed25519 = Ed25519();

  static Future<ReleaseKey> generate() async {
    final pair = await _ed25519.newKeyPair();
    final public = await pair.extractPublicKey();
    return ReleaseKey._(pair, ManifestVerifier(public.bytes));
  }

  final SimpleKeyPair _pair;

  /// What a till would be built with.
  final ManifestVerifier verifier;

  /// The document an update host serves: the bytes, and a signature over exactly
  /// those bytes.
  Future<String> sign(List<int> manifestBytes) async {
    final signature = await _ed25519.sign(manifestBytes, keyPair: _pair);
    return signedManifestDocument(
      manifestBytes: manifestBytes,
      signature: signature.bytes,
    );
  }

  /// A document whose signature was made by somebody else. Structurally perfect
  /// and worthless, which is exactly what an attacker can produce.
  static Future<String> forged(List<int> manifestBytes) async {
    final theirs = await _ed25519.newKeyPair();
    final signature = await _ed25519.sign(manifestBytes, keyPair: theirs);
    return signedManifestDocument(
      manifestBytes: manifestBytes,
      signature: signature.bytes,
    );
  }

  /// A document with no signature at all, as an unsigned channel would serve.
  static String unsigned(List<int> manifestBytes) =>
      jsonEncode({'manifest': base64.encode(manifestBytes)});
}
