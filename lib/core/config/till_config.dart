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
    this.syncCertificatePins = const {},
    this.soleTill = true,
    this.lanFabric = false,
    this.kdsMode = false,
    this.displayMode = false,
    this.lanPort = 45333,
  });

  factory TillConfig.fromEnvironment() {
    const manifestUrl = String.fromEnvironment('UPDATE_MANIFEST_URL');
    return TillConfig(
      shopName: const String.fromEnvironment('SHOP_NAME'),
      taxId: _orNull(const String.fromEnvironment('SHOP_TAX_ID')),
      receiptFooter: _orNull(const String.fromEnvironment('RECEIPT_FOOTER')),
      updateManifestUrl: manifestUrl.isEmpty ? null : Uri.parse(manifestUrl),
      updatePublicKey: const String.fromEnvironment('UPDATE_PUBLIC_KEY'),
      updateCertificatePins:
          _pinSet(const String.fromEnvironment('UPDATE_CERT_PINS')),
      syncCertificatePins:
          _pinSet(const String.fromEnvironment('SYNC_CERT_PINS')),
      // A single-till shop is the assumption that costs nothing when wrong the
      // other way: assuming a second till exists is how a shop ends up with no
      // way to sell during a restart.
      soleTill: const bool.fromEnvironment('SOLE_TILL', defaultValue: true),
      // Off unless the shop was sold a second device. The fabric is the only
      // feature here that opens a listening socket, so it is the one that has to
      // be asked for rather than assumed.
      lanFabric: const bool.fromEnvironment('LAN_FABRIC'),
      kdsMode: const bool.fromEnvironment('KDS_MODE'),
      displayMode: const bool.fromEnvironment('DISPLAY_MODE'),
      lanPort: const int.fromEnvironment('LAN_PORT', defaultValue: 45333),
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

  /// Hex sha256 of the DER certificates the Odoo host may present, for the calls
  /// that carry the integration login and the day's takings.
  ///
  /// Empty means the platform trust store decides, which is what every till already
  /// installed runs on. Unlike the update channel this cannot be all-or-nothing: a
  /// pin invented here for a shop that was never given one is a till that can never
  /// reach its own server, and a till that cannot sync is a shop that cannot bank
  /// its day. Pinning the API is still the rule for a build that ships one, and
  /// docs/SECURITY.md asks for it.
  final Set<String> syncCertificatePins;

  /// Whether this is the only till that can take money in the shop. Feeds the
  /// update gate: a mandatory update may override the clock, but not if going down
  /// means the shop cannot sell at all.
  final bool soleTill;

  /// Whether this build starts out sharing state with the other devices in the
  /// shop over the LAN. Only the default: the device's own setting wins, so a shop
  /// that adds a second till does not need a new build to switch it on.
  final bool lanFabric;

  /// This device is a kitchen screen and nothing else: it boots straight into the
  /// board, sells nothing, and needs no shift open. A build-time decision because
  /// it is a decision about what the hardware is for, not a preference.
  final bool kdsMode;

  /// This device is a customer-facing display and nothing else: it shows the cart
  /// being rung at the counter and can neither sell nor be typed into. A build-time
  /// decision for the same reason [kdsMode] is: it is a decision about what the
  /// hardware is for, not a preference.
  final bool displayMode;

  /// The port the fabric serves on. The beacon announces on the next port up, so
  /// an installer who has to move it past a busy port only sets one number.
  final int lanPort;

  int get lanBeaconPort => lanPort + 1;

  /// What the device's own LAN switch falls back to when nobody has set it.
  ///
  /// A kitchen screen counts as asking for the fabric whether or not the LAN flag
  /// was passed with it: it rings up nothing, so every ticket it shows arrived from
  /// another device, and a KDS build off the LAN is a blank screen. A customer
  /// display is the same case for the same reason. The device setting still
  /// overrides this either way.
  bool get lanDefault => lanFabric || kdsMode || displayMode;

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

  /// One comma-separated list of digests, parsed the same way for both channels so
  /// an installer never has to remember which pin takes which spelling.
  static Set<String> _pinSet(String raw) => {
        for (final pin in raw.split(',').map((p) => p.trim()))
          if (pin.isNotEmpty) pin,
      };
}
