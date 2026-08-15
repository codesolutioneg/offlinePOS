import 'package:flutter_test/flutter_test.dart';

import '../db/sqlite_loader.dart';
import 'shop.dart';

/// The 86 board as a shop-wide fact.
///
/// The kitchen runs out of one thing, and the till nobody shouted at has to refuse
/// it too. What is proven here is convergence in both directions and that the
/// answer does not depend on which till heard first.
void main() {
  setUpAll(useSystemSqlite);

  late TestShop shop;
  setUp(() => shop = TestShop());
  tearDown(() => shop.close());

  test('an item marked sold out on one till is sold out on the other', () async {
    final a = shop.add('till-a', name: 'Front');
    final b = shop.add('till-b', name: 'Bar');
    shop.introduceAll();

    a.settings.setProductAvailable(7, false);
    await shop.settle();

    expect(b.settings.unavailableProducts, {7});
    // And the till that heard it keeps its own answer: an event is never echoed
    // back to the device that raised it.
    expect(a.settings.unavailableProducts, {7});
    expect(b.refusals.where((r) => r.startsWith('lan.event.refused')), isEmpty);
  });

  test('putting it back on reaches the other till too', () async {
    final a = shop.add('till-a');
    final b = shop.add('till-b');
    shop.introduceAll();

    a.settings.setProductAvailable(7, false);
    await shop.settle();
    expect(b.settings.unavailableProducts, {7});

    a.settings.setProductAvailable(7, true);
    await shop.settle();
    expect(b.settings.unavailableProducts, isEmpty);
  });

  test('a till that was off the LAN catches up on what ran out', () async {
    final a = shop.add('till-a');
    final b = shop.add('till-b');
    shop.introduceAll();
    shop.unreachable.add('till-b');

    a.settings.setProductAvailable(3, false);
    a.settings.setProductAvailable(4, false);
    await shop.settle();
    expect(b.settings.unavailableProducts, isEmpty,
        reason: 'nothing crosses a cut cable');

    shop.unreachable.remove('till-b');
    await shop.settle();
    expect(b.settings.unavailableProducts, {3, 4});
  });

  test('the last shout wins, whichever till made it', () async {
    final a = shop.add('till-a');
    final b = shop.add('till-b');
    shop.introduceAll();

    a.settings.setProductAvailable(9, false);
    await shop.settle();
    // The bar till puts it back on after the kitchen found more.
    b.settings.setProductAvailable(9, true);
    await shop.settle();

    expect(a.settings.unavailableProducts, isEmpty);
    expect(b.settings.unavailableProducts, isEmpty);
  });

  test('the 86 board is per product, so one item off leaves the rest on', () async {
    final a = shop.add('till-a');
    final b = shop.add('till-b');
    shop.introduceAll();

    a.settings.setProductAvailable(1, false);
    b.settings.setProductAvailable(2, false);
    await shop.settle();

    expect(a.settings.unavailableProducts, {1, 2});
    expect(b.settings.unavailableProducts, {1, 2});
  });
}
