import '../../../domain/delivery.dart';
import '../../../domain/order.dart';
import 'stress_cashier.dart';
import 'stress_trace.dart';

const List<OrderType> _kDeliveryTypes = [
  OrderType.storeDelivery,
  OrderType.deliveryFromCompany,
  OrderType.carDelivery,
];

/// Stand-ins when the till has no drivers on file. Only stamped on lab orders,
/// which never leave the till.
const List<Driver> _kStandInDrivers = [
  Driver(id: 'stress-driver-1', name: 'Stress driver 1', phone: '0100000001'),
  Driver(id: 'stress-driver-2', name: 'Stress driver 2', phone: '0100000002'),
  Driver(id: 'stress-driver-3', name: 'Stress driver 3', phone: '0100000003'),
];

/// A delivery from the phone to the door: customer, zone, driver, kitchen, bag
/// slip, parked while it is out, then paid and delivered.
Future<void> deliveryScenario(StressCashier c, OrderTrace t) async {
  final type = _kDeliveryTypes[t.index % _kDeliveryTypes.length];
  await c.step(
    t,
    'new order',
    () => c.session.startFresh(type),
    where: type.name,
  );
  await c.step(t, 'customer', () {
    c.session.setDeliveryCustomer(
      name: 'Stress guest ${t.index}',
      phone: '01${(10000000 + t.index).toString()}',
      address: 'Lab street ${t.index}',
    );
  });
  final zones = c.deps.zones?.call() ?? const <DeliveryZone>[];
  if (zones.isNotEmpty) {
    final zone = zones[t.index % zones.length];
    await c.step(
      t,
      'zone',
      () => c.session.setShippingZone(zone),
      where: zone.name,
    );
  }
  await c.ring(t, 2 + c.nextInt(3));
  final listed = c.deps.drivers?.call() ?? const <Driver>[];
  final drivers = listed.isEmpty ? _kStandInDrivers : listed;
  final driver = drivers[t.index % drivers.length];
  await c.step(
    t,
    'driver',
    () => c.session.setDriver(driver),
    where: driver.name,
  );
  final order = c.session.current;
  await c.kitchen(t, order);
  final bag = c.deps.printBagSlip;
  if (bag != null) {
    await c.step(t, 'bag slip', () => bag(order), where: 'delivery printer');
  }
  final uuid = await c.hold(t);
  await c.pause();
  await _status(c, t, uuid, DeliveryStatus.onTheWay);
  await c.pause();
  await c.recall(t, uuid);
  final sale = await c.payAll(t);
  await _status(c, t, sale.uuid, DeliveryStatus.delivered);
}

Future<void> _status(
  StressCashier c,
  OrderTrace t,
  String uuid,
  DeliveryStatus s,
) => c.step(t, 'status', () {
  final o = c.deps.orders.byUuid(uuid);
  if (o == null) throw StateError('order $uuid is gone');
  c.session.setDeliveryStatus(o, s);
  t.expect(o);
}, where: s.label);
