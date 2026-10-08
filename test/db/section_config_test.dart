import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/db/database.dart';
import 'package:offline_pos/core/db/settings_store.dart';
import 'package:offline_pos/domain/order.dart';
import 'package:offline_pos/domain/table_preorder.dart';
import 'package:offline_pos/domain/table_section_config.dart';

import 'sqlite_loader.dart';

void main() {
  setUpAll(useSystemSqlite);

  late SettingsStore settings;

  setUp(() {
    settings = SettingsStore(Db.open(':memory:'));
  });

  test('section config round-trips categories, payments and staff flag', () {
    settings.deviceRole = DeviceRole.primary;
    settings.setSectionConfig(const TableSectionConfig(
      name: 'staff meals',
      isStaffSection: true,
      allowedCategoryIds: [10, 20],
      allowedPaymentMethodIds: [3],
      employeeAllowedCategories: {
        'Sara': ['10'],
        'Ali': [TableSectionConfig.allCategoriesSentinel],
      },
    ));
    final cfg = settings.sectionConfig('staff meals');
    expect(cfg.isStaffSection, isTrue);
    expect(cfg.allowedCategoryIds, [10, 20]);
    expect(cfg.allowedPaymentMethodIds, [3]);
    expect(cfg.getCategoriesForEmployee('Sara'), [10]);
    expect(cfg.getCategoriesForEmployee('Ali'), isEmpty);
    expect(cfg.getCategoriesForEmployee('Other'), [10, 20]);
  });

  test('renameSectionSettings moves preorders and config keys', () {
    settings.deviceRole = DeviceRole.primary;
    settings.setSectionPreorders('old', [
      const TablePreorder(productId: 1, quantity: 1),
    ]);
    settings.setSectionConfig(const TableSectionConfig(
      name: 'old',
      allowedCategoryIds: [7],
    ));
    settings.renameSectionSettings('old', 'new');
    expect(settings.sectionPreorders('old'), isEmpty);
    expect(settings.sectionPreorders('new'), hasLength(1));
    expect(settings.sectionConfig('old').allowedCategoryIds, isEmpty);
    expect(settings.sectionConfig('new').allowedCategoryIds, [7]);
  });

  test('primary can mint and consume a join PIN once', () {
    settings.deviceRole = DeviceRole.primary;
    final pin = settings.issueJoinPin();
    expect(pin, isNotNull);
    expect(pin!.length, 6);
    expect(settings.joinPinBankCount, 1);
    expect(settings.consumeJoinPin(pin), isTrue);
    expect(settings.consumeJoinPin(pin), isFalse);
    expect(settings.joinPinBankCount, 0);
  });

  test('secondary cannot mint join PINs', () {
    settings.deviceRole = DeviceRole.secondary;
    expect(settings.issueJoinPin(), isNull);
  });

  test('secondary cannot overwrite section config locally', () {
    settings.deviceRole = DeviceRole.primary;
    settings.setSectionConfig(const TableSectionConfig(
      name: 'e',
      allowedCategoryIds: [1],
    ));
    settings.deviceRole = DeviceRole.secondary;
    settings.setSectionConfig(const TableSectionConfig(
      name: 'e',
      allowedCategoryIds: [99],
    ));
    expect(settings.sectionConfig('e').allowedCategoryIds, [1]);
  });

  test('applySectionConfigSnapshot replaces the map', () {
    settings.applySectionConfigSnapshot({
      'officer': {
        'name': 'officer',
        'is_staff_section': true,
        'allowed_category_ids': [5],
        'allowed_payment_method_ids': [2],
        'employee_allowed_categories': <String, List<String>>{},
      },
    });
    expect(settings.sectionConfig('officer').allowedCategoryIds, [5]);
    expect(settings.sectionConfig('officer').isStaffSection, isTrue);
  });

  test('section default order type and guest prompt round-trip', () {
    settings.deviceRole = DeviceRole.primary;
    settings.setSectionConfig(const TableSectionConfig(
      name: 'TOGO',
      defaultOrderType: OrderType.toGo,
      requireGuestCount: false,
    ));
    final cfg = settings.sectionConfig('TOGO');
    expect(cfg.defaultOrderType, OrderType.toGo);
    expect(cfg.requireGuestCount, isFalse);
  });

  test('moving a table before kitchen is allowed until the shop turns the gate on', () {
    expect(settings.moveRequiresKitchen, isFalse);
    settings.moveRequiresKitchen = true;
    expect(settings.moveRequiresKitchen, isTrue);
  });

  test('shop bundle round-trips dishflow mirror fields', () {
    settings.dishflowMirrorEnabled = true;
    settings.dishflowProjectId = 'odc-chat';
    settings.dishflowApiKey = 'secret-key';
    settings.dishflowOdooConnectionId = 'conn-42';
    settings.dishflowBranchId = 'b1';
    settings.dishflowBranchName = 'Main';
    final bundle = settings.exportShopBundle();
    expect(bundle['dishflow_mirror_enabled'], isTrue);
    expect(bundle['dishflow_project_id'], 'odc-chat');
    expect(bundle['dishflow_api_key'], 'secret-key');
    expect(bundle['dishflow_odoo_connection_id'], 'conn-42');
    expect(bundle['dishflow_branch_id'], 'b1');
    expect(bundle['dishflow_branch_name'], 'Main');

    final otherDb = Db.open(':memory:');
    final other = SettingsStore(otherDb);
    other.applyShopBundle(bundle);
    expect(other.dishflowMirrorReady, isTrue);
    expect(other.dishflowProjectId, 'odc-chat');
    expect(other.dishflowApiKey, 'secret-key');
    expect(other.dishflowOdooConnectionId, 'conn-42');
    expect(other.dishflowBranchId, 'b1');
    expect(other.dishflowBranchName, 'Main');
    otherDb.close();
  });
}
