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
    this.cost = 0,
  });

  final int id;
  final String name;
  final double price;
  final int? categoryId;
  final String? barcode;
  final bool active;
  final bool soldByWeight;
  final double taxRate;

  /// What the dish costs the shop, as the server last stated it. Zero means the
  /// server never said, which the margin reports read as unknown rather than free.
  /// Never shown to a customer and never printed: this is a manager's number.
  final double cost;
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
    this.isDefault = false,
  });

  final int id;
  final int groupId;
  final String name;
  final double price;
  final ModifierPriceType priceType;
  final int sequence;

  /// The stock item consumed when this modifier is chosen, when there is one.
  final int? productId;

  /// Whether this option is what the dish comes with unless someone says otherwise
  /// (the standard sauce, the regular size). Only meaningful inside a group the
  /// shop lets resolve itself.
  final bool isDefault;

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
    this.autoAdd = false,
    this.modifiers = const [],
  });

  final int id;
  final String name;
  final int sequence;
  final int minSelection;

  /// 0 means no ceiling.
  final int maxSelection;
  final bool required;

  /// Whether this group answers itself from its defaults instead of asking. A shop
  /// that has one standard sauce does not want a sheet in front of every tap; a
  /// group with a real choice in it must keep asking.
  final bool autoAdd;

  final List<Modifier> modifiers;

  ModifierGroup withModifiers(List<Modifier> m) => ModifierGroup(
        id: id, name: name, sequence: sequence, minSelection: minSelection,
        maxSelection: maxSelection, required: required, autoAdd: autoAdd,
        modifiers: m,
      );

  /// The options this group would apply on its own: its defaults, capped at what
  /// [maxSelection] allows so a mis-configured group cannot add five sauces.
  List<Modifier> get defaults {
    final picked = modifiers.where((m) => m.isDefault).toList();
    return maxSelection > 0 && picked.length > maxSelection
        ? picked.sublist(0, maxSelection)
        : picked;
  }

  /// Whether this group can be settled without asking the cashier: the shop marked
  /// it auto-add, and what it would apply is a valid answer for it. A required
  /// group with no default still has to be asked.
  bool get resolvesItself => autoAdd && isSatisfiedBy(defaults.length);

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

/// A guest that can be attached to a sale, synced from Odoo res.partner.
class Customer {
  const Customer({required this.id, required this.name, this.phone});
  final int id;
  final String name;
  final String? phone;

  Map<String, dynamic> toMap() => {'id': id, 'name': name, 'phone': phone};
  factory Customer.fromMap(Map<String, dynamic> m) => Customer(
        id: m['id'] as int,
        name: (m['name'] ?? '') as String,
        phone: m['phone'] as String?,
      );
}
