import '../../domain/catalogue.dart';

/// Fetches the catalogue from Odoo and maps it into local models.
///
/// The counterpart to [OdooSender]. Runs on a schedule and never on the path of a
/// sale, so a slow or absent server delays a refresh but never a customer.
class OdooPuller {
  OdooPuller({required this.call});

  /// Performs one Odoo `call_kw`. Injected so this is testable without a socket.
  final Future<dynamic> Function(String model, String method, List<dynamic> args,
      Map<String, dynamic> kwargs) call;

  Future<CataloguePull> pull() async {
    final categories = await _searchRead(
      'pos.category',
      ['id', 'name', 'sequence', 'parent_id'],
      [],
    );
    final products = await _searchRead(
      'product.product',
      ['id', 'display_name', 'lst_price', 'pos_categ_ids', 'barcode', 'active', 'to_weight',
       'taxes_id', 'product_tmpl_id'],
      [
        ['available_in_pos', '=', true]
      ],
    );
    // Resolve each product's tax to a percent, so the till can show a tax
    // breakdown. Optional: an Odoo that refuses account.tax simply leaves tax at
    // zero rather than losing the catalogue.
    final taxRate = <int, double>{};
    try {
      final taxes = await _searchRead('account.tax',
          ['id', 'amount', 'amount_type'], [['amount_type', '=', 'percent']]);
      for (final t in taxes) {
        taxRate[t['id'] as int] = _num(t['amount']);
      }
    } catch (_) {
      // no tax data; taxRate stays empty
    }
    // Modifiers come from an optional add-on. On an Odoo without it, asking for
    // these models errors; degrade to no modifiers rather than losing the whole
    // catalogue (products and categories must still load).
    List<Map<String, dynamic>> groups = const [];
    List<Map<String, dynamic>> modifiers = const [];
    try {
      groups = await _searchRead(
        'product.modifier.category',
        ['id', 'name', 'sequence', 'min_selection', 'max_selection', 'selection_type',
         'product_template_ids'],
        [
          ['active', '=', true]
        ],
      );
      modifiers = await _searchRead(
        'product.modifier',
        ['id', 'name', 'category_id', 'price', 'price_type', 'sequence', 'product_id'],
        [
          ['active', '=', true]
        ],
      );
    } catch (_) {
      groups = const [];
      modifiers = const [];
    }

    // Payment methods for the tender screen. Optional: an Odoo that does not
    // expose them just leaves the till on its cash default.
    List<Map<String, dynamic>> methods = const [];
    try {
      methods = await _searchRead('pos.payment.method', ['id', 'name', 'is_cash_count'], [
        ['active', '=', true]
      ]);
    } catch (_) {
      methods = const [];
    }

    // Customers for attaching a guest to a sale. Bounded so a large partner list
    // cannot bloat the till; optional like the rest.
    List<Map<String, dynamic>> partners = const [];
    try {
      final raw = await call('res.partner', 'search_read', [
        [['customer_rank', '>', 0]],
        ['id', 'name', 'phone', 'mobile']
      ], {'limit': 500, 'order': 'name'});
      partners = raw is List
          ? raw.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList()
          : const [];
    } catch (_) {
      partners = const [];
    }

    final byGroup = <int, List<Modifier>>{};
    for (final m in modifiers) {
      final gid = _id(m['category_id']);
      if (gid == null) continue;
      byGroup.putIfAbsent(gid, () => []).add(Modifier(
            id: m['id'] as int,
            groupId: gid,
            name: (m['name'] ?? '') as String,
            price: _num(m['price']),
            priceType: _priceType(m['price_type']),
            sequence: (m['sequence'] ?? 0) as int,
            productId: _id(m['product_id']),
          ));
    }

    // Odoo links groups to product *templates*; the till sells variants. Map the
    // template ids onto the product ids we actually loaded, or a product with
    // modifiers upstream would arrive with none here.
    final templateToProducts = <int, List<int>>{};
    for (final p in products) {
      final tmpl = _id(p['product_tmpl_id']) ?? p['id'] as int;
      templateToProducts.putIfAbsent(tmpl, () => []).add(p['id'] as int);
    }

    final productGroupIds = <int, List<int>>{};
    final mappedGroups = <ModifierGroup>[];
    for (final g in groups) {
      final gid = g['id'] as int;
      mappedGroups.add(ModifierGroup(
        id: gid,
        name: (g['name'] ?? '') as String,
        sequence: (g['sequence'] ?? 0) as int,
        minSelection: (g['min_selection'] ?? 0) as int,
        maxSelection: (g['max_selection'] ?? 0) as int,
        required: g['selection_type'] == 'required',
        modifiers: byGroup[gid] ?? const [],
      ));
      for (final tmplId in _ids(g['product_template_ids'])) {
        for (final pid in templateToProducts[tmplId] ?? const <int>[]) {
          productGroupIds.putIfAbsent(pid, () => []).add(gid);
        }
      }
    }

    return CataloguePull(
      categories: categories
          .map((c) => Category(
                id: c['id'] as int,
                name: (c['name'] ?? '') as String,
                sequence: (c['sequence'] ?? 0) as int,
                parentId: _id(c['parent_id']),
              ))
          .toList(),
      products: products
          .map((p) => Product(
                id: p['id'] as int,
                name: (p['display_name'] ?? p['name'] ?? '') as String,
                price: _num(p['lst_price']),
                categoryId: _ids(p['pos_categ_ids']).firstOrNull,
                barcode: p['barcode'] is String ? p['barcode'] as String : null,
                active: p['active'] != false,
                soldByWeight: p['to_weight'] == true,
                // First percent tax on the product, or 0 when none is resolvable.
                taxRate: _ids(p['taxes_id'])
                    .map((id) => taxRate[id])
                    .whereType<double>()
                    .firstOrNull ??
                    0,
              ))
          .toList(),
      groups: mappedGroups,
      productGroupIds: productGroupIds,
      paymentMethods: methods
          .map((m) => PaymentMethod(
                id: m['id'] as int,
                name: (m['name'] ?? '') as String,
                isCash: m['is_cash_count'] == true,
              ))
          .toList(),
      customers: partners
          .map((c) => Customer(
                id: c['id'] as int,
                name: (c['name'] ?? '') as String,
                phone: c['phone'] is String
                    ? c['phone'] as String
                    : (c['mobile'] is String ? c['mobile'] as String : null),
              ))
          .toList(),
    );
  }

  Future<List<Map<String, dynamic>>> _searchRead(
      String model, List<String> fields, List<dynamic> domain) async {
    final res = await call(model, 'search_read', [domain, fields], {});
    if (res is! List) return const [];
    return res.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList();
  }

  /// Odoo returns a many2one as `[id, label]`, or `false` when unset.
  static int? _id(dynamic v) {
    if (v is int) return v;
    if (v is List && v.isNotEmpty && v.first is int) return v.first as int;
    return null;
  }

  static List<int> _ids(dynamic v) =>
      v is List ? v.whereType<int>().toList() : const [];

  static double _num(dynamic v) => v is num ? v.toDouble() : 0;

  static ModifierPriceType _priceType(dynamic v) => switch (v) {
        'percentage' => ModifierPriceType.percentage,
        'free' => ModifierPriceType.free,
        _ => ModifierPriceType.fixed,
      };
}

class CataloguePull {
  const CataloguePull({
    required this.categories,
    required this.products,
    required this.groups,
    required this.productGroupIds,
    this.paymentMethods = const [],
    this.customers = const [],
  });

  final List<Category> categories;
  final List<Product> products;
  final List<ModifierGroup> groups;
  final Map<int, List<int>> productGroupIds;
  final List<PaymentMethod> paymentMethods;
  final List<Customer> customers;

  /// A pull with no products is refused rather than written: replacing a working
  /// catalogue with an empty one would leave the till unable to sell.
  bool get isUsable => products.isNotEmpty;
}
