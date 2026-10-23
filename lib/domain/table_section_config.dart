import 'order.dart';

/// Per-floor-section rules: which menu categories and payment methods appear,
/// and (for staff sections) optional per-employee category overrides.
///
/// Empty [allowedCategoryIds] / [allowedPaymentMethodIds] means unrestricted —
/// same semantics as Dishflow. Employee overrides use [allCategoriesSentinel]
/// so "inherit section", "all categories", and "these ids" stay distinct in JSON.
class TableSectionConfig {
  const TableSectionConfig({
    required this.name,
    this.isStaffSection = false,
    this.allowedCategoryIds = const [],
    this.allowedPaymentMethodIds = const [],
    this.employeeAllowedCategories = const {},
    this.requireGuestCount,
    this.defaultOrderType,
  });

  final String name;
  final bool isStaffSection;
  final List<int> allowedCategoryIds;
  final List<int> allowedPaymentMethodIds;

  /// Employee display name → category id strings, or a single [allCategoriesSentinel].
  final Map<String, List<String>> employeeAllowedCategories;

  /// Whether seating this section asks for covers. Null inherits the shop toggle.
  final bool? requireGuestCount;

  /// Order type applied when a free table in this section is seated, when that
  /// type is offered on the till. Null keeps whatever the waiter already picked.
  final OrderType? defaultOrderType;

  /// Explicit "every category" for one employee (not the same as a missing key).
  static const String allCategoriesSentinel = '__ALL__';

  /// Effective category allow-list for [employeeName].
  ///
  /// Empty list = no filter. Missing employee key inherits the section list.
  List<int> getCategoriesForEmployee(String employeeName) {
    final key = employeeName.trim();
    if (key.isEmpty) return allowedCategoryIds;
    if (!employeeAllowedCategories.containsKey(key)) {
      return allowedCategoryIds;
    }
    final override = employeeAllowedCategories[key]!;
    if (override.length == 1 && override.first == allCategoriesSentinel) {
      return const [];
    }
    return [
      for (final raw in override)
        if (int.tryParse(raw) != null) int.parse(raw),
    ];
  }

  bool hasEmployeeOverride(String employeeName) =>
      employeeAllowedCategories.containsKey(employeeName.trim());

  TableSectionConfig copyWith({
    String? name,
    bool? isStaffSection,
    List<int>? allowedCategoryIds,
    List<int>? allowedPaymentMethodIds,
    Map<String, List<String>>? employeeAllowedCategories,
    bool? requireGuestCount,
    bool clearRequireGuestCount = false,
    OrderType? defaultOrderType,
    bool clearDefaultOrderType = false,
  }) =>
      TableSectionConfig(
        name: name ?? this.name,
        isStaffSection: isStaffSection ?? this.isStaffSection,
        allowedCategoryIds: allowedCategoryIds ?? this.allowedCategoryIds,
        allowedPaymentMethodIds:
            allowedPaymentMethodIds ?? this.allowedPaymentMethodIds,
        employeeAllowedCategories:
            employeeAllowedCategories ?? this.employeeAllowedCategories,
        requireGuestCount: clearRequireGuestCount
            ? null
            : (requireGuestCount ?? this.requireGuestCount),
        defaultOrderType: clearDefaultOrderType
            ? null
            : (defaultOrderType ?? this.defaultOrderType),
      );

  Map<String, dynamic> toMap() => {
        'name': name,
        'is_staff_section': isStaffSection,
        'allowed_category_ids': allowedCategoryIds,
        'allowed_payment_method_ids': allowedPaymentMethodIds,
        'employee_allowed_categories': employeeAllowedCategories,
        if (requireGuestCount != null) 'require_guest_count': requireGuestCount,
        if (defaultOrderType != null) 'default_order_type': defaultOrderType!.name,
      };

  factory TableSectionConfig.fromMap(Map<String, dynamic> m) {
    List<int> ints(dynamic raw) {
      if (raw is! List) return const [];
      return [
        for (final e in raw)
          if (e is int)
            e
          else if (e is num)
            e.toInt()
          else if (int.tryParse('$e') != null)
            int.parse('$e'),
      ];
    }

    Map<String, List<String>> employees(dynamic raw) {
      if (raw is! Map) return const {};
      return {
        for (final e in raw.entries)
          '${e.key}': [
            for (final v in (e.value is List ? e.value as List : const []))
              '$v',
          ],
      };
    }

    bool? asBool(dynamic raw) {
      if (raw is bool) return raw;
      return null;
    }

    final typeRaw = m['default_order_type'] as String?;
    return TableSectionConfig(
      name: '${m['name'] ?? ''}',
      isStaffSection: m['is_staff_section'] == true,
      allowedCategoryIds: ints(m['allowed_category_ids']),
      allowedPaymentMethodIds: ints(m['allowed_payment_method_ids']),
      employeeAllowedCategories: employees(m['employee_allowed_categories']),
      requireGuestCount: asBool(m['require_guest_count']),
      defaultOrderType:
          typeRaw == null || typeRaw.isEmpty ? null : OrderTypeLabel.parse(typeRaw),
    );
  }
}

/// Till role on the shop LAN: who mints join PINs and owns shop config writes.
enum DeviceRole {
  unset,
  primary,
  secondary;

  static DeviceRole fromWire(String? raw) {
    switch (raw) {
      case 'primary':
        return DeviceRole.primary;
      case 'secondary':
        return DeviceRole.secondary;
      default:
        return DeviceRole.unset;
    }
  }

  String get wire => name;
}

/// What this physical device is for in the shop (local to the PC — not LAN-synced).
///
/// [delivery] receives ecommerce store-order alerts; [counter] does not (manual
/// Store orders menu still works on every station).
enum StationType {
  counter,
  delivery;

  static StationType fromWire(String? raw) {
    switch (raw) {
      case 'delivery':
        return StationType.delivery;
      default:
        return StationType.counter;
    }
  }

  String get wire => name;
}
