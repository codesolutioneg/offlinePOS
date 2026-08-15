import 'dart:convert';
import 'dart:typed_data';

import '../../domain/catalogue.dart';
import 'database.dart';

/// The catalogue on disk.
///
/// Every read the selling screen needs is answerable from here with no network, which
/// is what lets the till start cold during an outage. Writes come from a periodic
/// refresh, never from the critical path of a sale.
class CatalogueStore {
  CatalogueStore(this._db);

  final Db _db;

  // ── refresh ──────────────────────────────────────────────────────

  /// Replace the catalogue with a freshly pulled one, in a single transaction.
  ///
  /// All-or-nothing on purpose: a partial catalogue is worse than a stale one,
  /// because a stale one at least prices consistently. If this throws, the till
  /// keeps selling from what it already had.
  void replaceAll({
    required List<Category> categories,
    required List<Product> products,
    required List<ModifierGroup> groups,
    required Map<int, List<int>> productGroupIds,
    List<PaymentMethod> paymentMethods = const [],
    List<Customer> customers = const [],
    Map<int, Uint8List> productImages = const {},
    DateTime? refreshedAt,
  }) {
    _db.raw.execute('BEGIN');
    try {
      for (final t in ['product_modifier_groups', 'modifiers', 'modifier_groups', 'products', 'categories']) {
        _db.raw.execute('DELETE FROM $t');
      }
      for (final c in categories) {
        _db.raw.execute(
            'INSERT INTO categories (id, name, sequence, parent_id) VALUES (?,?,?,?)',
            [c.id, c.name, c.sequence, c.parentId]);
      }
      for (final p in products) {
        _db.raw.execute(
            'INSERT INTO products (id, name, price, category_id, barcode, active, sold_by_weight, tax_rate, cost, image) '
            'VALUES (?,?,?,?,?,?,?,?,?,?)',
            [p.id, p.name, p.price, p.categoryId, p.barcode, p.active ? 1 : 0,
             p.soldByWeight ? 1 : 0, p.taxRate, p.cost, productImages[p.id]]);
      }
      // A refresh replaces the products, so whatever was held in memory describes a
      // menu that no longer exists.
      _images = null;
      for (final g in groups) {
        _db.raw.execute(
            'INSERT INTO modifier_groups (id, name, sequence, min_selection, max_selection, required, auto_add) '
            'VALUES (?,?,?,?,?,?,?)',
            [g.id, g.name, g.sequence, g.minSelection, g.maxSelection,
             g.required ? 1 : 0, g.autoAdd ? 1 : 0]);
        for (final m in g.modifiers) {
          _db.raw.execute(
              'INSERT INTO modifiers (id, group_id, name, price, price_type, sequence, product_id, is_default) '
              'VALUES (?,?,?,?,?,?,?,?)',
              [m.id, g.id, m.name, m.price, m.priceType.name, m.sequence,
               m.productId, m.isDefault ? 1 : 0]);
        }
      }
      productGroupIds.forEach((productId, groupIds) {
        for (final gid in groupIds) {
          _db.raw.execute(
              'INSERT OR IGNORE INTO product_modifier_groups (product_id, group_id) VALUES (?,?)',
              [productId, gid]);
        }
      });
      _db.raw.execute(
          "INSERT INTO catalogue_meta (key, value) VALUES ('refreshed_at', ?) "
          "ON CONFLICT(key) DO UPDATE SET value = excluded.value",
          [(refreshedAt ?? DateTime.now().toUtc()).toIso8601String()]);
      _db.raw.execute(
          "INSERT INTO catalogue_meta (key, value) VALUES ('payment_methods', ?) "
          "ON CONFLICT(key) DO UPDATE SET value = excluded.value",
          [jsonEncode(paymentMethods.map((m) => m.toMap()).toList())]);
      _db.raw.execute(
          "INSERT INTO catalogue_meta (key, value) VALUES ('customers', ?) "
          "ON CONFLICT(key) DO UPDATE SET value = excluded.value",
          [jsonEncode(customers.map((c) => c.toMap()).toList())]);
      _db.raw.execute('COMMIT');
    } catch (_) {
      _db.raw.execute('ROLLBACK');
      rethrow;
    }
  }

  /// When the catalogue was last pulled, or null if it never has been.
  DateTime? get refreshedAt {
    final rows = _db.raw
        .select("SELECT value FROM catalogue_meta WHERE key = 'refreshed_at'");
    if (rows.isEmpty) return null;
    return DateTime.parse(rows.first['value'] as String);
  }

  /// How stale the prices are. The UI should say so rather than hide it.
  Duration? stalenessAt(DateTime now) {
    final at = refreshedAt;
    return at == null ? null : now.difference(at);
  }

  bool get isEmpty =>
      (_db.raw.select('SELECT COUNT(*) c FROM products').first['c'] as int) == 0;

  // ── reads ────────────────────────────────────────────────────────

  /// Payment methods synced from the till's point of sale, for the tender screen.
  /// Empty until the first sync that carried them; the tender screen falls back
  /// to a plain cash tender in that case.
  List<PaymentMethod> paymentMethods() {
    final rows = _db.raw
        .select("SELECT value FROM catalogue_meta WHERE key = 'payment_methods'");
    if (rows.isEmpty) return const [];
    try {
      final list = jsonDecode(rows.first['value'] as String) as List;
      return list
          .map((e) => PaymentMethod.fromMap((e as Map).cast<String, dynamic>()))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  /// Customers synced from Odoo, optionally filtered by name or phone.
  List<Customer> customers({String? search, int limit = 50}) {
    final rows =
        _db.raw.select("SELECT value FROM catalogue_meta WHERE key = 'customers'");
    if (rows.isEmpty) return const [];
    try {
      final all = (jsonDecode(rows.first['value'] as String) as List)
          .map((e) => Customer.fromMap((e as Map).cast<String, dynamic>()));
      final q = (search ?? '').trim().toLowerCase();
      final filtered = q.isEmpty
          ? all
          : all.where((c) =>
              c.name.toLowerCase().contains(q) || (c.phone ?? '').contains(q));
      return filtered.take(limit).toList();
    } catch (_) {
      return const [];
    }
  }

  /// Every product's cost, by product id, for the margin reports. One read of a
  /// column the selling queries never touch; a product the server gave no cost for
  /// is absent rather than present as zero, so a report can tell "free" from
  /// "nobody said".
  Map<int, double> costsById() => {
        for (final r in _db.raw
            .select('SELECT id, cost FROM products WHERE cost > 0'))
          r['id'] as int: (r['cost'] as num).toDouble(),
      };

  /// The product pictures held on this till, by product id.
  ///
  /// Read once and kept, because the grid asks for them on every rebuild and a
  /// query per tile per frame is how a menu with photos would start costing a
  /// cashier taps. Dropped when the catalogue is replaced, and re-read when another
  /// instance of this store did the replacing, which is what the stamp is for.
  Map<int, Uint8List> images() {
    final stamp = refreshedAt;
    if (_images != null && _imagesStamp == stamp) return _images!;
    _imagesStamp = stamp;
    return _images = {
      for (final r in _db.raw
          .select('SELECT id, image FROM products WHERE image IS NOT NULL'))
        r['id'] as int: r['image'] as Uint8List,
    };
  }

  Map<int, Uint8List>? _images;
  DateTime? _imagesStamp;

  List<Category> categories() => _db.raw
      .select('SELECT * FROM categories ORDER BY sequence, name')
      .map((r) => Category(
            id: r['id'] as int,
            name: r['name'] as String,
            sequence: r['sequence'] as int,
            parentId: r['parent_id'] as int?,
          ))
      .toList();

  List<Product> products({int? categoryId, String? search, int limit = 200}) {
    final where = <String>['active = 1'];
    final args = <Object?>[];
    if (categoryId != null) {
      where.add('category_id = ?');
      args.add(categoryId);
    }
    if (search != null && search.trim().isNotEmpty) {
      where.add('(name LIKE ? OR barcode = ?)');
      args..add('%${search.trim()}%')..add(search.trim());
    }
    args.add(limit);
    return _db.raw
        .select('SELECT $_productColumns FROM products WHERE ${where.join(' AND ')} '
                'ORDER BY name LIMIT ?', args)
        .map(_product)
        .toList();
  }

  Product? byBarcode(String barcode) {
    final rows = _db.raw.select(
        'SELECT $_productColumns FROM products WHERE barcode = ? AND active = 1 LIMIT 1',
        [barcode]);
    return rows.isEmpty ? null : _product(rows.first);
  }

  Product? byId(int id) {
    final rows = _db.raw
        .select('SELECT $_productColumns FROM products WHERE id = ?', [id]);
    return rows.isEmpty ? null : _product(rows.first);
  }

  /// Named rather than `*`: the picture column is kilobytes a product, and every
  /// query here answers a tap on the selling screen. Pictures are fetched on their
  /// own, once, by [images].
  static const _productColumns =
      'id, name, price, category_id, barcode, active, sold_by_weight, tax_rate, cost';

  /// Modifier groups for a product, each with its options, ordered for display.
  ///
  /// One indexed join, no per-tap network call. This is the read that Odoo's POS
  /// answered with a server round trip on every product tap.
  List<ModifierGroup> modifierGroupsFor(int productId) {
    final groups = _db.raw.select(
      'SELECT g.* FROM modifier_groups g '
      'JOIN product_modifier_groups pg ON pg.group_id = g.id '
      'WHERE pg.product_id = ? ORDER BY g.sequence, g.name',
      [productId],
    );
    return groups.map((g) {
      final gid = g['id'] as int;
      final mods = _db.raw
          .select('SELECT * FROM modifiers WHERE group_id = ? ORDER BY sequence, name', [gid])
          .map((m) => Modifier(
                id: m['id'] as int,
                groupId: gid,
                name: m['name'] as String,
                price: (m['price'] as num).toDouble(),
                priceType: ModifierPriceType.values.byName(m['price_type'] as String),
                sequence: m['sequence'] as int,
                productId: m['product_id'] as int?,
                isDefault: (m['is_default'] as int? ?? 0) == 1,
              ))
          .toList();
      return ModifierGroup(
        id: gid,
        name: g['name'] as String,
        sequence: g['sequence'] as int,
        minSelection: g['min_selection'] as int,
        maxSelection: g['max_selection'] as int,
        required: (g['required'] as int) == 1,
        autoAdd: (g['auto_add'] as int? ?? 0) == 1,
        modifiers: mods,
      );
    }).toList();
  }

  bool hasModifiers(int productId) =>
      (_db.raw.select(
                  'SELECT COUNT(*) c FROM product_modifier_groups WHERE product_id = ?',
                  [productId])
              .first['c'] as int) >
          0;

  Product _product(Map<String, Object?> r) => Product(
        id: r['id'] as int,
        name: r['name'] as String,
        price: (r['price'] as num).toDouble(),
        categoryId: r['category_id'] as int?,
        barcode: r['barcode'] as String?,
        active: (r['active'] as int) == 1,
        soldByWeight: (r['sold_by_weight'] as int) == 1,
        taxRate: (r['tax_rate'] as num).toDouble(),
        cost: (r['cost'] as num?)?.toDouble() ?? 0,
      );
}
