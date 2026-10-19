import '../../domain/catalogue.dart';
import '../../domain/order.dart';
import 'restaurant_analytics.dart';

/// One menu group (Food / Beverages / …) inside a driver's block.
class DriverGroupSales {
  DriverGroupSales(this.groupName);
  final String groupName;
  double sales = 0;
  double qty = 0;
}

/// One driver's delivery sales for the Employee Sales Analysis layout.
class DriverSalesBlock {
  DriverSalesBlock({
    required this.driverId,
    required this.driverName,
  });

  final String driverId;
  final String driverName;
  int checks = 0;
  int customers = 0;
  final Map<String, DriverGroupSales> _groups = {};

  List<DriverGroupSales> get groups {
    final list = _groups.values.toList()
      ..sort((a, b) => b.sales.compareTo(a.sales));
    return list;
  }

  double get totalSales =>
      _groups.values.fold(0.0, (s, g) => s + g.sales);

  double get totalQty =>
      _groups.values.fold(0.0, (s, g) => s + g.qty);

  double get salesPerCheck => checks == 0 ? 0 : totalSales / checks;
  double get salesPerCustomer =>
      customers == 0 ? 0 : totalSales / customers;
  double get qtyPerCustomer =>
      customers == 0 ? 0 : totalQty / customers;
  double get avgItem => totalQty == 0 ? 0 : totalSales / totalQty;

  void _addLine(String group, double lineSales, double lineQty) {
    final g = _groups.putIfAbsent(group, () => DriverGroupSales(group));
    g.sales += lineSales;
    g.qty += lineQty;
  }
}

/// Whether [order] belongs to the driver picked in a report (id, or name when
/// the id was missing / remapped across tills).
bool orderBelongsToDriver(Order order, {required String driverId, String? driverName}) {
  final oid = order.driverId?.trim();
  if (oid != null && oid.isNotEmpty && oid == driverId) return true;
  final wanted = (driverName ?? '').trim().toLowerCase();
  if (wanted.isEmpty) return false;
  return (order.driverName ?? '').trim().toLowerCase() == wanted;
}

/// Delivery orders only, with a driver, rolled up like Dishflow Employee Sales
/// Analysis (Revenue Center = Delivery). [driverId] null = every driver.
List<DriverSalesBlock> driverSalesAnalysis(
  List<Order> orders,
  List<Category> categories, {
  String? driverId,
  String? driverName,
}) {
  final byId = {for (final c in categories) c.id: c};
  final blocks = <String, DriverSalesBlock>{};

  for (final o in orders) {
    if (!o.type.isDelivery) continue;
    final id = o.driverId?.trim();
    final name = (o.driverName ?? '').trim();
    if ((id == null || id.isEmpty) && name.isEmpty) continue;
    if (driverId != null &&
        !orderBelongsToDriver(o, driverId: driverId, driverName: driverName)) {
      continue;
    }

    // Prefer a stable id; fall back to the stamped name so name-only rows still
    // group instead of vanishing from "All drivers".
    final key = (id != null && id.isNotEmpty) ? id : 'name:$name';
    final block = blocks.putIfAbsent(
      key,
      () => DriverSalesBlock(
        driverId: key,
        driverName: name.isEmpty ? key : name,
      ),
    );
    block.checks += 1;
    block.customers += (o.guestCount != null && o.guestCount! > 0)
        ? o.guestCount!
        : 1;

    for (final l in o.lines) {
      // Parent type (Food / Beverages) matches the RM "Group name" column.
      final group = categoryPath(l.categoryId, byId).type;
      block._addLine(group, l.total, l.quantity);
    }
  }

  final list = blocks.values.toList()
    ..sort((a, b) => b.totalSales.compareTo(a.totalSales));
  return list;
}

int driverAnalysisChecks(List<DriverSalesBlock> blocks) =>
    blocks.fold(0, (s, b) => s + b.checks);

int driverAnalysisCustomers(List<DriverSalesBlock> blocks) =>
    blocks.fold(0, (s, b) => s + b.customers);
