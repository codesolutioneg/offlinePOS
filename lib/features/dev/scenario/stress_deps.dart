import '../../../app/pos_session.dart';
import '../../../core/db/catalogue_store.dart';
import '../../../core/db/database.dart';
import '../../../core/db/order_store.dart';
import '../../../core/db/table_store.dart';
import '../../../core/printing/kitchen_ticket.dart';
import '../../../core/printing/print_probe.dart';
import '../../../domain/delivery.dart';
import '../../../domain/order.dart';

/// What a full-day run needs from the till, handed over by `PosApp` so the run
/// rings, prints and fires through exactly the code a cashier's taps reach.
///
/// The printing hooks are null in tests and when the run is told not to print:
/// the kitchen is then simulated by marking lines fired, so the rest of the flow
/// (and every check on it) still runs.
class StressDeps {
  const StressDeps({
    required this.db,
    required this.deviceId,
    required this.orders,
    required this.tables,
    required this.catalogue,
    required this.newSession,
    this.fireKitchen,
    this.printReceipt,
    this.printBagSlip,
    this.voidToKitchen,
    this.fireDueTimed,
    this.drivers,
    this.zones,
    this.attachProbe,
    this.heldPrints,
    this.reserveSeat,
  });

  final Db db;
  final String deviceId;
  final OrderStore orders;
  final TableStore tables;
  final CatalogueStore catalogue;

  /// A fresh session for one virtual cashier, numbering orders the way the till
  /// does and tagging every order it creates as a lab order.
  final PosSession Function(String cashierId) newSession;

  final Future<KitchenFireResult> Function(Order order)? fireKitchen;
  final Future<void> Function(Order order)? printReceipt;
  final Future<void> Function(Order order)? printBagSlip;
  final Future<KitchenFireResult> Function(
    Order order,
    OrderLine line,
    String reason,
  )?
  voidToKitchen;

  /// The till's own course-timer tick: fires every due timed line on the floor.
  final void Function()? fireDueTimed;

  final List<Driver> Function()? drivers;
  final List<DeliveryZone> Function()? zones;

  final void Function(PrintProbe? probe)? attachProbe;
  final int Function()? heldPrints;

  /// Asks the shop's primary for a table, the way the floor does before seating
  /// one. False when another till has just taken it. Null seats without asking.
  final Future<bool> Function(String table)? reserveSeat;

  /// The same till with printing switched off for one run.
  StressDeps withoutPrinting() => StressDeps(
    db: db,
    deviceId: deviceId,
    orders: orders,
    tables: tables,
    catalogue: catalogue,
    newSession: newSession,
    drivers: drivers,
    zones: zones,
    reserveSeat: reserveSeat,
  );

  bool get prints => fireKitchen != null;
}
