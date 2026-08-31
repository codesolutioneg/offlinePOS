import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/db/schema.dart';
import 'package:offline_pos/core/lan/lan_credential.dart';
import 'package:offline_pos/core/lan/lan_transport.dart';

import '../db/sqlite_loader.dart';
import 'shop.dart';

/// Rotating the shop key is what a manager does after handing it to someone who
/// should not have it, so it has to bite now and not at the next restart: an
/// unpairing that waits for a reboot is not an unpairing.
void main() {
  setUpAll(useSystemSqlite);

  late TestShop shop;
  setUp(() => shop = TestShop());
  tearDown(() => shop.close());

  Map<String, String> pullQuery() =>
      {'since': '0', 'schema': '${Schema.version}'};

  String stampFor(LanCredential credential) => credential.stamp(
      method: 'GET',
      path: LanProtocol.eventsPath,
      query: LanCredential.canonicalQuery(pullQuery()));

  LanReply pull(TestTill till, String? auth) =>
      till.protocol.handleGet(LanProtocol.eventsPath, pullQuery(), auth: auth);

  test('a rotated key decides the very next request, with nothing rebuilt', () {
    final till = shop.add('till-a', name: 'Front');
    final onTheOldKey = stampFor(till.credential);
    expect(pull(till, onTheOldKey).status, 200);

    till.shopKey = 'the-new-shop-key';

    // Same node, same protocol, same credential object: what changed is only what
    // the key field says, and that is enough.
    expect(pull(till, onTheOldKey).status, 401);
    expect(pull(till, stampFor(till.credential)).status, 200);
  });

  test('a peer still holding the old key is turned away as another shop', () {
    final till = shop.add('till-a');
    final peer = LanCredential(shop.shopKey);
    expect(pull(till, stampFor(peer)).status, 200);

    till.shopKey = 'the-new-shop-key';

    final reply = pull(till, stampFor(peer));
    expect(reply.status, 401);
    expect(reply.body['error'], LanAuth.wrongKey.name);
    // A device on the previous key is an outsider, and the log has to say so: this
    // is the case support is looking at when half the shop stopped sharing.
    expect(till.refusals.any((r) => r.contains('another shop')), isTrue);
  });

  test('two tills rotated to the same new key keep replicating', () async {
    final a = shop.add('till-a', name: 'Front');
    final b = shop.add('till-b', name: 'Bar');
    shop.introduceAll();
    final before = heldOrder('till-a', table: '5');
    a.orders.save(before);
    await shop.settle();
    expect(b.orders.heldAnywhere().map((o) => o.uuid), [before.uuid]);

    final rotated = LanCredential.newKey();
    a.shopKey = rotated;
    b.shopKey = rotated;

    final after = heldOrder('till-b', table: '9');
    b.orders.save(after);
    await shop.settle();

    expect(a.orders.heldAnywhere().map((o) => o.uuid).toSet(),
        {before.uuid, after.uuid});
    expect(a.errors, isEmpty);
    expect(b.errors, isEmpty);
  });

  test('a till rotated alone stops sharing until the others are given the key',
      () async {
    final a = shop.add('till-a');
    final b = shop.add('till-b');
    shop.introduceAll();

    a.shopKey = 'only-on-till-a';
    final tab = heldOrder('till-a', table: '5');
    a.orders.save(tab);
    await shop.settle();

    // The half-rotated shop is the state a manager is in between typing the key
    // into the first till and the last one, and it has to be a refusal rather than
    // a quiet acceptance.
    expect(b.orders.byUuid(tab.uuid), isNull);
    expect(a.errors.any((e) => e.contains('401')), isTrue);

    b.shopKey = 'only-on-till-a';
    await shop.settle();

    expect(b.orders.byUuid(tab.uuid), isNotNull);
  });

  test('a drifted clock is still named a clock problem after a rotation', () {
    final till = shop.add('till-a');
    till.shopKey = 'the-new-shop-key';
    final drifted = LanCredential.rotating(() => till.shopKey,
        now: () => DateTime.now().toUtc().subtract(const Duration(minutes: 30)));

    final reply = pull(till, stampFor(drifted));

    expect(reply.status, 401);
    expect(reply.body['error'], LanAuth.staleClock.name);
    expect(till.refusals.any((r) => r.contains('clocks is wrong')), isTrue);
  });

  test('a stamp inside the tolerance still verifies after a rotation', () {
    final till = shop.add('till-a');
    till.shopKey = 'the-new-shop-key';
    final nearly = LanCredential.rotating(() => till.shopKey,
        now: () => DateTime.now().toUtc().subtract(const Duration(minutes: 14)));

    expect(pull(till, stampFor(nearly)).status, 200);
  });

  test('a digest is still compared whole, whichever key it was made with', () {
    final till = shop.add('till-a');
    till.shopKey = 'the-new-shop-key';
    final stamp = stampFor(till.credential);
    final split = stamp.indexOf('.');
    final at = stamp.substring(0, split);
    final digest = stamp.substring(split + 1);

    // One character out, same length: nothing may answer early on the first
    // difference, so this reads as a wrong key and not as a near miss.
    final tweaked = digest.substring(0, digest.length - 1) +
        (digest.endsWith('0') ? '1' : '0');
    expect(pull(till, '$at.$tweaked').body['error'], LanAuth.wrongKey.name);
    // A short digest is refused on length before a character is compared.
    expect(pull(till, '$at.${digest.substring(0, 10)}').body['error'],
        LanAuth.wrongKey.name);
  });

  test('the key is read per operation, so nothing holds the previous one', () {
    var reads = 0;
    var key = 'the-shop-key';
    final credential = LanCredential.rotating(() {
      reads++;
      return key;
    });

    final stamp = credential.stamp(method: 'GET', path: LanProtocol.eventsPath);
    expect(reads, 1);
    expect(credential.check(stamp, method: 'GET', path: LanProtocol.eventsPath),
        LanAuth.ok);
    expect(reads, 2);
    expect(credential.key, key);

    key = 'the-new-shop-key';

    expect(credential.check(stamp, method: 'GET', path: LanProtocol.eventsPath),
        LanAuth.wrongKey);
    expect(credential.key, 'the-new-shop-key');
  });

  test('a credential built on a fixed key still keeps that key', () {
    final credential = LanCredential('the-shop-key');
    final stamp = credential.stamp(method: 'GET', path: LanProtocol.eventsPath);

    expect(credential.key, 'the-shop-key');
    expect(credential.check(stamp, method: 'GET', path: LanProtocol.eventsPath),
        LanAuth.ok);
  });
}
