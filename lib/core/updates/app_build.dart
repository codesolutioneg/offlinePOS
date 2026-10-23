/// A build as the release names it, `1.2.3+45`, comparable so one till can tell
/// whether another runs something newer.
class AppBuild implements Comparable<AppBuild> {
  const AppBuild(this.major, this.minor, this.patch, this.number);

  final int major;
  final int minor;
  final int patch;
  final int number;

  /// Null for anything that is not a release build (`0.0.0-dev`, `test`), so a
  /// developer's copy never offers itself or asks to be replaced.
  static AppBuild? tryParse(String? text) {
    final m = RegExp(r'^(\d+)\.(\d+)\.(\d+)\+(\d+)$').firstMatch(text?.trim() ?? '');
    if (m == null) return null;
    return AppBuild(int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!),
        int.parse(m[4]!));
  }

  bool isNewerThan(AppBuild other) => compareTo(other) > 0;

  @override
  int compareTo(AppBuild other) {
    for (final (a, b) in [
      (major, other.major),
      (minor, other.minor),
      (patch, other.patch),
      (number, other.number),
    ]) {
      if (a != b) return a.compareTo(b);
    }
    return 0;
  }

  @override
  String toString() => '$major.$minor.$patch+$number';
}
