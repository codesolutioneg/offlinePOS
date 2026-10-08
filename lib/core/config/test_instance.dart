import 'dart:io';

/// A second copy of the till on the same computer, for trying a two-till shop
/// without a second machine.
///
/// Set `OFFLINE_POS_INSTANCE` (for example `2`) in the environment before launch.
/// That copy keeps its own database in a subfolder and serves the shop network on
/// its own port; the beacon port stays shared, because that is how the two find
/// each other. The Windows runner reads the same variable for its one-copy lock.
/// Never set on a real till.
class TestInstance {
  const TestInstance._();

  static const String variable = 'OFFLINE_POS_INSTANCE';

  /// How far the fabric port moves, clear of the beacon port just above the base.
  static const int portOffset = 100;

  static String? get name {
    final value = Platform.environment[variable]?.trim();
    return value == null || value.isEmpty ? null : value;
  }

  /// Where this copy keeps its data: [base] for the real till, a subfolder of it
  /// for a test copy.
  static Directory dataDirectory(Directory base) {
    final n = name;
    if (n == null) return base;
    final dir = Directory('${base.path}${Platform.pathSeparator}instance-$n');
    dir.createSync(recursive: true);
    return dir;
  }

  static int lanPort(int base) => name == null ? base : base + portOffset;
}
