// The things the till sells, as held on the device.

/// Who owns a menu row: a catalogue pull, or a person standing at this till.
///
/// The whole point of the distinction is precedence. A pull is seeding, never an
/// owner: it may create, replace and remove [odoo] rows, and it must never touch a
/// [local] one. Editing a pulled row on the till moves it to [local], so a shop that
/// starts from Odoo and then corrects a price here does not lose the correction on
/// the next refresh.
enum CatalogueSource {
  odoo,
  local;

  static CatalogueSource fromName(String? v) =>
      v == local.name ? local : odoo;
}

class Category {
  const Category({
    required this.id,
    required this.name,
    this.sequence = 0,
    this.parentId,
    this.odooId,
    this.source = CatalogueSource.odoo,
    this.active = true,
  });

  final int id;
  final String name;
  final int sequence;
  final int? parentId;

  /// The `pos.category` this stands for in Odoo, when it stands for one. Null on a
  /// category typed here that nobody has linked yet.
  final int? odooId;
  final CatalogueSource source;

  /// Archived categories stay on disk so the products filed under them and the sales
  /// that name them still resolve; they simply leave the strip.
  final bool active;

  Category copyWith({
    String? name,
    int? sequence,
    Object? parentId = _keep,
    Object? odooId = _keep,
    CatalogueSource? source,
    bool? active,
  }) =>
      Category(
        id: id,
        name: name ?? this.name,
        sequence: sequence ?? this.sequence,
        parentId: parentId == _keep ? this.parentId : parentId as int?,
        odooId: odooId == _keep ? this.odooId : odooId as int?,
        source: source ?? this.source,
        active: active ?? this.active,
      );
}

/// Sentinel for a `copyWith` that has to tell "leave it" from "set it to null".
const Object _keep = Object();

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
    this.odooId,
    this.source = CatalogueSource.odoo,
    this.color,
  });

  final int id;
  final String name;
  final double price;
  final int? categoryId;
  final String? barcode;
  final bool active;
  final bool soldByWeight;
  final double taxRate;

  /// The `product.product` this sells as in Odoo, or null for a product typed on the
  /// till that nobody has linked yet. Captured onto the order line at the moment of
  /// sale, so relinking a product later cannot rewrite what was already booked.
  final int? odooId;
  final CatalogueSource source;

  /// A tile colour of this product's own, overriding its category's. Null is the
  /// normal case and leaves the grid looking exactly as it does today.
  final int? color;

  /// What the dish costs the shop, as the server last stated it. Zero means the
  /// server never said, which the margin reports read as unknown rather than free.
  /// Never shown to a customer and never printed: this is a manager's number.
  final double cost;

  /// Whether a sale of this can name a real Odoo product. An unlinked product still
  /// sells and still prints; what it books against is decided when the sale is
  /// turned into a payload.
  bool get isLinked => odooId != null;

  Product copyWith({
    String? name,
    double? price,
    Object? categoryId = _keep,
    Object? barcode = _keep,
    bool? active,
    bool? soldByWeight,
    double? taxRate,
    double? cost,
    Object? odooId = _keep,
    CatalogueSource? source,
    Object? color = _keep,
  }) =>
      Product(
        id: id,
        name: name ?? this.name,
        price: price ?? this.price,
        categoryId: categoryId == _keep ? this.categoryId : categoryId as int?,
        barcode: barcode == _keep ? this.barcode : barcode as String?,
        active: active ?? this.active,
        soldByWeight: soldByWeight ?? this.soldByWeight,
        taxRate: taxRate ?? this.taxRate,
        cost: cost ?? this.cost,
        odooId: odooId == _keep ? this.odooId : odooId as int?,
        source: source ?? this.source,
        color: color == _keep ? this.color : color as int?,
      );
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
    this.source = CatalogueSource.odoo,
  });

  final int id;
  final int groupId;
  final String name;
  final double price;
  final ModifierPriceType priceType;
  final int sequence;
  final CatalogueSource source;

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
    this.source = CatalogueSource.odoo,
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
  final CatalogueSource source;

  ModifierGroup withModifiers(List<Modifier> m) => ModifierGroup(
        id: id, name: name, sequence: sequence, minSelection: minSelection,
        maxSelection: maxSelection, required: required, autoAdd: autoAdd,
        source: source, modifiers: m,
      );

  /// The options this group would apply on its own: its defaults, capped at what
  /// [maxSelection] allows so a mis-configured group cannot add five sauces.
  List<Modifier> get defaults {
    final picked = modifiers.where((m) => m.isDefault).toList();
    return maxSelection > 0 && picked.length > maxSelection
        ? picked.sublist(0, maxSelection)
        : picked;
  }

  /// Whether this group can be settled without asking the cashier.
  ///
  /// Three things have to be true, and the third is the one that was missing: the
  /// shop marked it auto-add, what it would apply is a valid answer for it, and its
  /// defaults have filled the group right up to its ceiling so there is nothing left
  /// anybody could add. Without that last clause an "Extras" group with no ceiling,
  /// or a pick-three with one default, counted as answered and the sheet never
  /// opened, so the cashier could not add the second topping a customer had just
  /// asked for and had no way to tell why. Skipping a sheet is only ever safe when
  /// the sheet could not have changed the order.
  bool get resolvesItself =>
      autoAdd &&
      maxSelection > 0 &&
      defaults.length >= maxSelection &&
      isSatisfiedBy(defaults.length);

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
