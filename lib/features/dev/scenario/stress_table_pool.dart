import '../../../core/db/order_store.dart';
import '../../../core/db/table_store.dart';
import '../stress_lab_store.dart';

/// The tables a full-day run seats its guests at, shared by every virtual
/// cashier on this till.
///
/// A table is free when no tab sits on it anywhere in the shop, read live like
/// the floor reads it, so a table the other till just seated is skipped exactly
/// as a cashier would skip it. Two tills grabbing the same table in the same
/// instant is a real race, and the run leaves it to the checks to catch.
///
/// Each till starts its walk of the floor at its own place, worked out from
/// [deviceId]: two tills running at once and walking from the same first table
/// spent every take fighting over the same few tables while the rest stood empty.
class StressTablePool {
  StressTablePool({required this.orders, required this.tables, String deviceId = ''})
      : _offset = deviceId.codeUnits.fold(0, (a, b) => a + b);

  final OrderStore orders;
  final TableStore tables;
  final int _offset;
  final Set<String> _taken = {};
  bool _added = false;

  /// A free table, or null when the floor is full even after the lab adds its own.
  String? take() {
    final busy = {
      for (final o in orders.occupyingAnywhere())
        if (o.tableLabel != null) o.tableLabel!,
    };
    final floor = [
      for (final t in tables.all())
        if (!t.isDivider) t.name,
    ];
    for (var i = 0; i < floor.length; i++) {
      final name = floor[(i + _offset) % floor.length];
      if (busy.contains(name) || _taken.contains(name)) continue;
      _taken.add(name);
      return name;
    }
    if (_added) return null;
    _added = true;
    for (var i = 1; i <= 30; i++) {
      tables.add(name: 'S$i', section: kStressSection);
    }
    return take();
  }

  void release(String? table) {
    if (table != null) _taken.remove(table);
  }
}
