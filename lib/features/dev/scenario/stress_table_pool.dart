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
class StressTablePool {
  StressTablePool({required this.orders, required this.tables});

  final OrderStore orders;
  final TableStore tables;
  final Set<String> _taken = {};
  bool _added = false;

  /// A free table, or null when the floor is full even after the lab adds its own.
  String? take() {
    final busy = {
      for (final o in orders.occupyingAnywhere())
        if (o.tableLabel != null) o.tableLabel!,
    };
    for (final t in tables.all()) {
      if (t.isDivider || busy.contains(t.name) || _taken.contains(t.name)) {
        continue;
      }
      _taken.add(t.name);
      return t.name;
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
