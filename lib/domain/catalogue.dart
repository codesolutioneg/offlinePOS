// The things the till sells, as held on the device.

class Category {
  const Category({required this.id, required this.name, this.sequence = 0, this.parentId});

  final int id;
  final String name;
  final int sequence;
  final int? parentId;
}

class Product {
  const Product({
    required this.id,
    required this.name,
    required this.price,
    this.categoryId,
    this.barcode,
    this.active = true,
    this.soldByWeight = false,
    this.taxRate = 0,
  });

  final int id;
  final String name;
  final double price;
  final int? categoryId;
  final String? barcode;
  final bool active;
  final bool soldByWeight;
  final double taxRate;
}

enum ModifierPriceType { fixed, percentage, free }

class Modifier {
  const Modifier({
    required this.id,
    required this.groupId,
    required this.name,
    required this.price,
    this.priceType = ModifierPriceType.fixed,
    this.sequence = 0,
    this.productId,
  });

  final int id;
  final int groupId;
  final String name;
  final double price;
  final ModifierPriceType priceType;
  final int sequence;

  /// The stock item consumed when this modifier is chosen, when there is one.
  final int? productId;

  /// A percentage modifier is a share of the parent price, not a flat amount.
  /// Getting this wrong is how a 10% option ends up billing 10.
  double priceFor(double parentUnitPrice) => switch (priceType) {
        ModifierPriceType.free => 0,
        ModifierPriceType.percentage => parentUnitPrice * price / 100,
        ModifierPriceType.fixed => price,
      };
}

class ModifierGroup {
  const ModifierGroup({
    required this.id,
    required this.name,
    this.sequence = 0,
    this.minSelection = 0,
    this.maxSelection = 0,
    this.required = false,
    this.modifiers = const [],
  });

  final int id;
  final String name;
  final int sequence;
  final int minSelection;

  /// 0 means no ceiling.
  final int maxSelection;
  final bool required;
  final List<Modifier> modifiers;

  ModifierGroup withModifiers(List<Modifier> m) => ModifierGroup(
        id: id, name: name, sequence: sequence, minSelection: minSelection,
        maxSelection: maxSelection, required: required, modifiers: m,
      );

  /// Whether a chosen quantity satisfies this group. Enforced on the till, because
  /// the server is not there to enforce it.
  bool isSatisfiedBy(int chosen) {
    if (required && chosen < (minSelection == 0 ? 1 : minSelection)) return false;
    if (chosen < minSelection) return false;
    if (maxSelection > 0 && chosen > maxSelection) return false;
    return true;
  }
}

/// A way a sale can be paid, as configured on the till's point of sale in Odoo.
class PaymentMethod {
  const PaymentMethod({required this.id, required this.name, this.isCash = false});
  final int id;
  final String name;
  final bool isCash;

  Map<String, dynamic> toMap() => {'id': id, 'name': name, 'is_cash': isCash};
  factory PaymentMethod.fromMap(Map<String, dynamic> m) => PaymentMethod(
        id: m['id'] as int,
        name: (m['name'] ?? '') as String,
        isCash: m['is_cash'] == true,
      );
}
