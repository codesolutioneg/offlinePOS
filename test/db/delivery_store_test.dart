import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/db/database.dart';
import 'package:offline_pos/core/db/delivery_store.dart';

import 'sqlite_loader.dart';

/// The three delivery lists a shop keeps on the device. Everything here is local,
/// so every one of these passes with the line down.
void main() {
  late Db db;
  late DeliveryStore delivery;

  setUpAll(useSystemSqlite);
  setUp(() {
    db = Db.open(':memory:');
    delivery = DeliveryStore(db);
  });
  tearDown(() => db.close());

  test('a zone round-trips with its fee', () {
    delivery.addZone(name: 'Maadi', fee: 25);
    final zone = delivery.zones().single;
    expect(zone.name, 'Maadi');
    expect(zone.fee, 25);
  });

  test('a zone fee can be corrected and the zone dropped', () {
    final zone = delivery.addZone(name: 'Maadi', fee: 25);
    delivery.updateZone(zone.id, name: 'Maadi', fee: 30);
    expect(delivery.zones().single.fee, 30);
    delivery.removeZone(zone.id);
    expect(delivery.zones(), isEmpty);
  });

  test('a negative fee is refused rather than credited to the customer', () {
    delivery.addZone(name: 'Nearby', fee: -5);
    expect(delivery.zones().single.fee, 0);
  });

  test('zones keep the order they were typed in', () {
    delivery.addZone(name: 'Zamalek', fee: 20);
    delivery.addZone(name: 'Maadi', fee: 35);
    expect(delivery.zones().map((z) => z.name), ['Zamalek', 'Maadi']);
  });

  test('a channel carries the partner it is invoiced against', () {
    delivery.addChannel(name: 'Talabat', partnerId: 77);
    final channel = delivery.channels().single;
    expect(channel.name, 'Talabat');
    expect(channel.partnerId, 77);
  });

  test('a channel can be a plain label with no partner', () {
    delivery.addChannel(name: 'Phone');
    expect(delivery.channels().single.partnerId, isNull);
  });

  test('a channel can be repointed at another partner and removed', () {
    final channel = delivery.addChannel(name: 'Talabat', partnerId: 77);
    delivery.updateChannel(channel.id, name: 'Talabat', partnerId: 88);
    expect(delivery.channels().single.partnerId, 88);
    delivery.removeChannel(channel.id);
    expect(delivery.channels(), isEmpty);
  });

  test('a driver round-trips and starts active', () {
    delivery.addDriver(name: 'Hany', phone: '0100');
    final driver = delivery.drivers().single;
    expect(driver.name, 'Hany');
    expect(driver.phone, '0100');
    expect(driver.active, isTrue);
  });

  test('an empty phone is stored as nothing rather than as a blank', () {
    delivery.addDriver(name: 'Hany', phone: '  ');
    expect(delivery.drivers().single.phone, isNull);
  });

  test('a driver who left drops out of the picker but stays on file', () {
    final driver = delivery.addDriver(name: 'Hany');
    delivery.setDriverActive(driver.id, false);
    expect(delivery.drivers(activeOnly: true), isEmpty);
    expect(delivery.drivers().single.active, isFalse);
  });

  test('a driver can be edited and deleted outright', () {
    final driver = delivery.addDriver(name: 'Hany', phone: '0100');
    delivery.updateDriver(driver.id, name: 'Hany Samir', phone: '0111', active: true);
    expect(delivery.drivers().single.name, 'Hany Samir');
    expect(delivery.drivers().single.phone, '0111');
    delivery.removeDriver(driver.id);
    expect(delivery.drivers(), isEmpty);
  });

  test('the picker lists active drivers by name', () {
    delivery.addDriver(name: 'Sami');
    delivery.addDriver(name: 'Adel');
    expect(delivery.drivers(activeOnly: true).map((d) => d.name), ['Adel', 'Sami']);
  });
}
