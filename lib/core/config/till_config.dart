import '../updates/manifest_signature.dart';

/// Everything about an installation that is decided by whoever ships or installs
/// the till, rather than by whatever the shop LAN happens to say.
///
/// Read from `--dart-define` at build time. These are compile-time constants, so
/// they are in the binary and therefore public, which is fine for all of them: a
/// shop name, a tax id, an update url and a public key are not secrets. Nothing
/// that would be a secret belongs here. See docs/SECURITY.md.
///
/// Absent values mean the feature is off, never a guessed default. A till with no
/// update channel configured does not check for updates; it does not fall back to
/// an unpinned or unsigned one.
class TillConfig {
  const TillConfig({
    this.shopName = '',
    this.taxId,
    this.receiptFooter,
    this.updateManifestUrl,
    this.updatePublicKey = '',
    this.updateCertificatePins = const {},
    this.soleTill = true,
  });

  factory TillConfig.fromEnvironment() {
    const manifestUrl = String.fromEnvironment('UPDATE_MANIFEST_URL');
    const pins = String.fromEnvironment('UPDATE_CERT_PINS');
    return TillConfig(
      shopName: const String.fromEnvironment('SHOP_NAME'),
      taxId: _orNull(const String.fromEnvironment('SHOP_TAX_ID')),
      receiptFooter: _orNull(const String.fromEnvironment('RECEIPT_FOOTER')),
      updateManifestUrl: manifestUrl.isEmpty ? null : Uri.parse(manifestUrl),
      updatePublicKey: const String.fromEnvironment('UPDATE_PUBLIC_KEY'),
      updateCertificatePins: {
        for (final pin in pins.split(',').map((p) => p.trim()))
          if (pin.isNotEmpty) pin,
      },
      // A single-till shop is the assumption that costs nothing when wrong the
      // other way: assuming a second till exists is how a shop ends up with no
      // way to sell during a restart.
      soleTill: const bool.fromEnvironment('SOLE_TILL', defaultValue: true),
    );
  }

  /// Printed at the top of every receipt. Empty until an installer sets it, which
  /// is visible on the paper rather than hidden behind a plausible placeholder.
  final String shopName;

  /// Required on a receipt in most jurisdictions, so it is configuration and not
  /// something the code can invent.
  final String? taxId;

  final String? receiptFooter;

  /// Where the signed update document lives. Null switches updates off entirely.
  final Uri? updateManifestUrl;

  /// Base64 Ed25519 key the release server signs manifests with.
  final String updatePublicKey;

  /// Hex sha256 of the DER certificates the update host may present.
  final Set<String> updateCertificatePins;

  /// Whether this is the only till that can take money in the shop. Feeds the
  /// update gate: a mandatory update may override the clock, but not if going down
  /// means the shop cannot sell at all.
  final bool soleTill;

  /// True only when the channel is completely specified. A partly configured
  /// channel is a build mistake, and running with the missing half filled in by a
  /// default is how an unsigned or unpinned update path gets shipped by accident.
  bool get hasUpdateChannel =>
      updateManifestUrl != null &&
      updatePublicKey.isNotEmpty &&
      updateCertificatePins.isNotEmpty;

  /// Throws if the configured key is not an Ed25519 public key. That is a property
  /// of the build rather than of the device, so it fails on the first launch of a
  /// misconfigured binary and never selectively in the field.
  ManifestVerifier get updateVerifier =>
      ManifestVerifier.fromBase64(updatePublicKey);

  static String? _orNull(String value) => value.isEmpty ? null : value;
}
