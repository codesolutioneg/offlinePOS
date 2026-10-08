import 'delivery.dart';
import 'order.dart';

/// The delivery station's at-a-glance numbers: the bags waiting in the shop by
/// kind and by where they are, and what deliveries have closed today.
class DeliveryBulletin {
  const DeliveryBulletin({
    required this.waiting,
    required this.company,
    required this.store,
    required this.car,
    required this.noDriver,
    required this.onTheWay,
    required this.waitingAmount,
    required this.closedToday,
    required this.salesToday,
  });

  final int waiting;
  final int company;
  final int store;
  final int car;

  /// Store / car bags with nobody assigned to take them yet.
  final int noDriver;
  final int onTheWay;
  final double waitingAmount;
  final int closedToday;
  final double salesToday;

  /// [held] every parked order in the shop (any till, duplicates allowed);
  /// [closedToday] the orders paid today. Only deliveries are counted.
  factory DeliveryBulletin.from({
    required Iterable<Order> held,
    required Iterable<Order> closedToday,
  }) {
    final bags = <String, Order>{
      for (final o in held)
        if (o.type.isDelivery) o.uuid: o,
    }.values.toList();
    final closed = <String, Order>{
      for (final o in closedToday)
        if (o.type.isDelivery) o.uuid: o,
    }.values;
    int of(OrderType t) => bags.where((o) => o.type == t).length;
    return DeliveryBulletin(
      waiting: bags.length,
      company: of(OrderType.deliveryFromCompany),
      store: of(OrderType.storeDelivery),
      car: of(OrderType.carDelivery),
      noDriver: bags
          .where(
            (o) =>
                o.type != OrderType.deliveryFromCompany && o.driverId == null,
          )
          .length,
      onTheWay: bags
          .where((o) => o.deliveryStatus == DeliveryStatus.onTheWay)
          .length,
      waitingAmount: bags.fold(0, (s, o) => s + o.total),
      closedToday: closed.length,
      salesToday: closed.fold(0, (s, o) => s + o.total),
    );
  }

  /// Row id -> the value the board shows.
  Map<String, String> values(String Function(double) money) => {
    'waiting': '$waiting',
    'company': '$company',
    'store': '$store',
    'car': '$car',
    'no-driver': '$noDriver',
    'on-the-way': '$onTheWay',
    'waiting-amount': money(waitingAmount),
    'closed': '$closedToday',
    'sales': money(salesToday),
  };
}
