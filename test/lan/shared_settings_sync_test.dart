import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/auth/access.dart';
import 'package:offline_pos/core/auth/permissions.dart';
import 'package:offline_pos/core/auth/user_store.dart';
import 'package:offline_pos/core/db/database.dart';
import 'package:offline_pos/core/db/settings_store.dart';
import 'package:offline_pos/core/lan/lan_event.dart';

import '../db/sqlite_loader.dart';

typedef Sent = ({LanEventKind kind, String uuid, Map<String, dynamic> payload});

/// Everything a manager sets up (levels, button bars, the Bulletin, staff) is
/// announced from whichever till it was changed on, and lands on the others
/// without echoing back.
void main() {
  late Db dbA, dbB;
  late SettingsStore primary, secondary;
  late List<Sent> fromA, fromB;

  setUpAll(useSystemSqlite);
  setUp(() {
    dbA = Db.open(':memory:');
    dbB = Db.open(':memory:');
    primary = SettingsStore(dbA);
    secondary = SettingsStore(dbB);
    fromA = [];
    fromB = [];
    primary.publish = (k, u, p) => fromA.add((kind: k, uuid: u, payload: p));
    secondary.publish = (k, u, p) => fromB.add((kind: k, uuid: u, payload: p));
  });
  tearDown(() {
    dbA.close();
    dbB.close();
  });

  Future<void> settle() => Future<void>.delayed(Duration.zero);

  test('a level set up on one till reaches the other with its rules', () async {
    primary.addCustomRole('Level 1');
    primary.setRolePermission('Level 1', Permission.refund, true);
    primary.setAccess('Level 1', 'floor.flash', AccessRule.hidden);
    primary.setAccess('Level 1', 'screen.reports', AccessRule.manager);
    await settle();

    expect(fromA, hasLength(1), reason: 'one change, one announcement');
    expect(fromA.single.kind, LanEventKind.shopBundle);

    secondary.applyShopBundle(fromA.single.payload);
    await settle();
    expect(secondary.customRoles, ['Level 1']);
    expect(secondary.roleCan('Level 1', Permission.refund), isTrue);
    expect(secondary.accessFor('Level 1', 'floor.flash'), AccessRule.hidden);
    expect(secondary.accessFor('Level 1', 'screen.reports'), AccessRule.manager);
    expect(fromB, isEmpty, reason: 'what arrived is not announced back');
  });

  test('bars and the Bulletin travel too', () async {
    primary.floorActionsHidden = {'flash', 'quit'};
    primary.orderActionBarEnabled = false;
    primary.floorBulletinHidden = {'sales'};
    await settle();
    secondary.applyShopBundle(fromA.last.payload);
    expect(secondary.floorActionsHidden, {'flash', 'quit'});
    expect(secondary.orderActionBarEnabled, isFalse);
    expect(secondary.floorBulletinHidden, {'sales'});
  });

  test('a change made on a secondary goes back the other way', () async {
    secondary.setAccess('cashier', 'order.settle', AccessRule.manager);
    await settle();
    expect(fromB, hasLength(1));
    primary.applyShopBundle(fromB.single.payload);
    expect(primary.accessFor('cashier', 'order.settle'), AccessRule.manager);
  });

  test('writes that are not shop settings announce nothing', () async {
    primary.setString('last_sync_at', DateTime.now().toIso8601String());
    primary.setString('lan_primary_device_id', 'abc');
    await settle();
    expect(fromA, isEmpty);
  });

  test('a received bundle changes the revision the shell redraws on', () {
    final before = secondary.sharedRevision;
    secondary.applyShopBundle(primary.exportShopBundle());
    expect(secondary.sharedRevision, before + 1);
  });

  group('staff', () {
    test('an account added or moved to a level is announced; setup is not', () {
      final users = UserStore(dbA);
      final sent = <Sent>[];
      users.publish = (k, u, p) => sent.add((kind: k, uuid: u, payload: p));
      users.upsert(const Cashier(
          id: 'omar', name: 'Omar', pinSalt: 's', pinHash: 'h', role: 'Level 1'));
      users.upsert(const Cashier(
          id: 'setup', name: 'Setup', pinSalt: 's', pinHash: 'h'));
      expect(sent, hasLength(1));
      expect(sent.single.kind, LanEventKind.userUpsert);
      expect(sent.single.uuid, 'user-omar');

      final other = UserStore(dbB);
      final echoed = <Sent>[];
      other.publish = (k, u, p) => echoed.add((kind: k, uuid: u, payload: p));
      other.applyRemote(sent.single.payload);
      expect(other.byId('omar')?.role, 'Level 1');
      expect(echoed, isEmpty);
    });
  });
}
