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
      groups = await _searchReadOptional(
        'product.modifier.category',
        ['id', 'name', 'sequence', 'min_selection', 'max_selection', 'selection_type',
         'product_template_ids'],
        ['auto_add'],
        [
          ['active', '=', true]
        ],
      );
      modifiers = await _searchReadOptional(
        'product.modifier',
        ['id', 'name', 'category_id', 'price', 'price_type', 'sequence', 'product_id'],
        ['is_default'],
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
            isDefault: m['is_default'] == true,
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
        autoAdd: g['auto_add'] == true,
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

  /// Partners matching [term] by name or phone, straight from the server.
  ///
  /// The pull above is bounded at 500 partners, which is a menu-sized list and not
  /// a customer book: a shop with more of them cannot find the rest on the till.
  /// This is the way back to them, and it is a read of a standard model through the
  /// same call_kw the catalogue uses, so it needs nothing new on the server.
  ///
  /// Deliberately not on any selling path: it answers a picker, and a caller that
  /// cannot reach the server gets an exception to swallow rather than a wait.
  Future<List<Customer>> searchCustomers(String term, {int limit = 20}) async {
    final q = term.trim();
    if (q.isEmpty) return const [];
    final raw = await call('res.partner', 'search_read', [
      [
        ['customer_rank', '>', 0],
        '|',
        '|',
        ['name', 'ilike', q],
        ['phone', 'ilike', q],
        ['mobile', 'ilike', q],
      ],
      ['id', 'name', 'phone', 'mobile']
    ], {
      'limit': limit,
      'order': 'name'
    });
    if (raw is! List) return const [];
    return raw
        .whereType<Map>()
        .map((e) => e.cast<String, dynamic>())
        .map((c) => Customer(
              id: c['id'] as int,
              name: (c['name'] ?? '') as String,
              phone: c['phone'] is String
                  ? c['phone'] as String
                  : (c['mobile'] is String ? c['mobile'] as String : null),
            ))
        .toList();
  }

  Future<List<Map<String, dynamic>>> _searchRead(
      String model, List<String> fields, List<dynamic> domain) async {
    final res = await call(model, 'search_read', [domain, fields], {});
    if (res is! List) return const [];
    return res.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList();
  }

  /// A read that also asks for [optional] fields and retries without them when the
  /// server does not have them. An add-on older than a flag must still give up its
  /// modifiers: losing the whole menu to gain a default would be a bad trade.
  Future<List<Map<String, dynamic>>> _searchReadOptional(String model,
      List<String> fields, List<String> optional, List<dynamic> domain) async {
    try {
      return await _searchRead(model, [...fields, ...optional], domain);
    } catch (_) {
      return _searchRead(model, fields, domain);
    }
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
