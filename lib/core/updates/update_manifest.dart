import 'dart:convert';
import 'dart:math' as math;

/// A version, ordered the way releases actually run.
///
/// Comparing the strings instead sorts '1.10.0' before '1.9.0', so a till on 1.9.0
/// would treat the newer build as older and never take it again.
class AppVersion implements Comparable<AppVersion> {
  const AppVersion._(this.parts, this.preRelease, this.raw);

  /// Major, minor, patch and anything after it. Missing positions count as zero,
  /// so '1.2' and '1.2.0' are the same release.
  final List<int> parts;

  /// Dot-separated identifiers after a '-'. Present means unfinished.
  final List<String> preRelease;

  final String raw;

  static final RegExp _digits = RegExp(r'\d+');

  factory AppVersion.parse(String text) {
    // Build metadata never affects ordering, so '1.2.0+9' and '1.2.0+10' tie and
    // the build number decides nothing on its own.
    var body = text.trim().split('+').first;
    var pre = const <String>[];
    final dash = body.indexOf('-');
    if (dash >= 0) {
      pre = body
          .substring(dash + 1)
          .split('.')
          .where((p) => p.isNotEmpty)
          .toList(growable: false);
      body = body.substring(0, dash);
    }
    final parts = body
        .split('.')
        .map((p) => int.tryParse(_digits.stringMatch(p) ?? '') ?? 0)
        .toList(growable: false);
    return AppVersion._(parts, pre, text.trim());
  }

  @override
  int compareTo(AppVersion other) {
    final width = math.max(parts.length, other.parts.length);
    for (var i = 0; i < width; i++) {
      final a = i < parts.length ? parts[i] : 0;
      final b = i < other.parts.length ? other.parts[i] : 0;
      if (a != b) return a.compareTo(b);
    }
    if (preRelease.isEmpty && other.preRelease.isEmpty) return 0;
    // A release beats its own pre-releases: '1.2.0' is newer than '1.2.0-rc1'.
    if (preRelease.isEmpty) return 1;
    if (other.preRelease.isEmpty) return -1;
    final width2 = math.max(preRelease.length, other.preRelease.length);
    for (var i = 0; i < width2; i++) {
      if (i >= preRelease.length) return -1;
      if (i >= other.preRelease.length) return 1;
      final c = _compareIdentifier(preRelease[i], other.preRelease[i]);
      if (c != 0) return c;
    }
    return 0;
  }

  static int _compareIdentifier(String a, String b) {
    final na = int.tryParse(a);
    final nb = int.tryParse(b);
    if (na != null && nb != null) return na.compareTo(nb);
    // 'rc' outranks '2', so 1.0.0-rc is newer than 1.0.0-2.
    if (na != null) return -1;
    if (nb != null) return 1;
    return a.compareTo(b);
  }

  bool operator >(AppVersion other) => compareTo(other) > 0;
  bool operator <(AppVersion other) => compareTo(other) < 0;
  bool operator >=(AppVersion other) => compareTo(other) >= 0;
  bool operator <=(AppVersion other) => compareTo(other) <= 0;

  @override
  bool operator ==(Object other) =>
      other is AppVersion && compareTo(other) == 0;

  @override
  int get hashCode {
    // Trailing zeros are dropped so '1.2' and '1.2.0', which compare equal, also
    // land in the same bucket.
    final trimmed = List<int>.of(parts);
    while (trimmed.length > 1 && trimmed.last == 0) {
      trimmed.removeLast();
    }
    return Object.hashAll([...trimmed, preRelease.join('.')]);
  }

  @override
  String toString() => raw;
}

/// What the server advertises as the next build for this till.
class UpdateManifest {
  const UpdateManifest({
    required this.version,
    required this.buildNumber,
    required this.url,
    required this.sha256,
    this.minimumSupportedVersion,
    this.releaseNotes = '',
    this.mandatory = false,
  });

  final String version;
  final int buildNumber;

  /// Where the binary lives.
  final Uri url;

  /// Lowercase hex digest of the binary. Nothing is installed without it matching,
  /// both when it is downloaded and again against the file on disk at the moment
  /// of install.
  ///
  /// This is an integrity check, not an authenticity one. It is worth something
  /// only because the release key signed the manifest carrying it; see
  /// `ManifestVerifier`. On its own it proves the bytes are the bytes the manifest
  /// described, and whoever served the manifest chose both.
  final String sha256;

  /// The oldest build the sync API still speaks to. A till below this is stranded:
  /// it can still sell, but its sales will be refused, so the update stops being
  /// optional.
  final String? minimumSupportedVersion;

  final String releaseNotes;

  /// Set by the server for a security fix. Buys an exception from the clock, never
  /// from unsynced sales.
  final bool mandatory;

  AppVersion get semver => AppVersion.parse(version);

  bool isNewerThan(String currentVersion) =>
      semver > AppVersion.parse(currentVersion);

  /// True when [currentVersion] has fallen out of the supported window.
  bool strands(String currentVersion) {
    final floor = minimumSupportedVersion;
    if (floor == null) return false;
    return AppVersion.parse(currentVersion) < AppVersion.parse(floor);
  }

  /// A stranded till is treated exactly like a mandatory update, because a till the
  /// server no longer accepts is already losing sales.
  bool isMandatoryFor(String currentVersion) =>
      mandatory || strands(currentVersion);

  static final RegExp _hex64 = RegExp(r'^[0-9a-f]{64}$');

  factory UpdateManifest.fromMap(Map<String, dynamic> map) {
    final version = (map['version'] as String?)?.trim() ?? '';
    if (version.isEmpty) throw const FormatException('manifest has no version');

    final url = Uri.tryParse((map['url'] as String?)?.trim() ?? '');
    // https only. The signature already says the release server chose this url, so
    // this is about the hop that fetches it: over plain http anyone on the path
    // substitutes the binary, and the digest check then rejects a download the
    // shop has already paid for over its line.
    if (url == null || url.scheme != 'https' || url.host.isEmpty) {
      throw const FormatException('manifest url is not https');
    }

    final digest = ((map['sha256'] as String?) ?? '').trim().toLowerCase();
    if (!_hex64.hasMatch(digest)) {
      throw const FormatException('manifest has no usable sha256');
    }

    return UpdateManifest(
      version: version,
      buildNumber: (map['build_number'] as num?)?.toInt() ?? 0,
      url: url,
      sha256: digest,
      minimumSupportedVersion:
          (map['minimum_supported_version'] as String?)?.trim(),
      releaseNotes: (map['release_notes'] as String?) ?? '',
      mandatory: map['mandatory'] == true,
    );
  }

  factory UpdateManifest.fromJson(String body) {
    final decoded = jsonDecode(body);
    if (decoded is! Map) throw const FormatException('manifest is not an object');
    return UpdateManifest.fromMap(decoded.cast<String, dynamic>());
  }

  Map<String, dynamic> toMap() => {
        'version': version,
        'build_number': buildNumber,
        'url': url.toString(),
        'sha256': sha256,
        'minimum_supported_version': minimumSupportedVersion,
        'release_notes': releaseNotes,
        'mandatory': mandatory,
      };
}
