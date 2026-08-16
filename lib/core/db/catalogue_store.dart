import 'dart:convert';
import 'dart:typed_data';

import '../../domain/catalogue.dart';
import 'database.dart';

/// The catalogue on disk.
///
/// Every read the selling screen needs is answerable from here with no network, which
/// is what lets the till start cold during an outage. Writes come from two places and
/// neither is on the critical path of a sale: a periodic refresh, and the menu editor
/// a manager types into. Which of the two owns a given row is what `source` records,
/// and [replaceAll] explains the precedence in full.
class CatalogueStore {
  CatalogueStore(this._db);

  final Db _db;

  // ── refresh ──────────────────────────────────────────────────────

  /// Take in a freshly pulled catalogue, in a single transaction.
  ///
  /// All-or-nothing on purpose: a partial catalogue is worse than a stale one,
  /// because a stale one at least prices consistently. If this throws, the till
  /// keeps selling from what it already had.
  ///
  /// ## A pull is seeding, never an owner
  ///
  /// This used to delete the menu and write the server's copy over the top, which
  /// is the right thing for a shop whose menu is maintained in Odoo and destroys the
  /// work of one that types its own. The rule now, in three lines:
  ///
  /// 1. A row whose `source` is `local` is never deleted and never overwritten. A
  ///    person standing at the counter outranks a background refresh, always. That
  ///    covers rows typed here and pulled rows that were edited here, because an
  ///    edit flips the row to `local`.
  /// 2. An incoming Odoo record that a local row already claims through its
  ///    `odoo_id` is skipped, so linking a local dish to an Odoo product makes the
  ///    till book correctly instead of putting the same dish on the grid twice.
  /// 3. Everything else is replaced exactly as before: pull-owned rows that the
  ///    server no longer sends are removed, and the ones it does send are rewritten.
  ///
  /// The cost of the rule is that a price corrected on the till stops tracking Odoo
  /// for that one item until somebody unlinks it. That is the trade a shop asked
  /// for, and it is the safe direction: losing an edit silently is worse than
  /// keeping one too long, because only one of the two is visible to the manager.
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
      // Rows the till owns, by the Odoo record they claim and by the id they sit on.
      // An incoming record in here is already represented locally and must be
      // skipped rather than written, and it is skipped explicitly rather than by
      // letting the insert fail quietly: a pull that genuinely contradicts itself
      // still has to roll back and leave the till selling from what it had.
      final claimedProducts = _claimed('products');
      final claimedCategories = _claimed('categories');
      // Only pull-owned rows go. Local rows, and the links that attach a local
      // modifier group to a product, survive every refresh.
      _db.raw.execute("DELETE FROM product_modifier_groups WHERE source = 'odoo'");
      _db.raw.execute("DELETE FROM modifiers WHERE source = 'odoo'");
      _db.raw.execute("DELETE FROM modifier_groups WHERE source = 'odoo'");
      _db.raw.execute("DELETE FROM products WHERE source = 'odoo'");
      _db.raw.execute("DELETE FROM categories WHERE source = 'odoo'");
      for (final c in categories) {
        if (claimedCategories.contains(c.id)) continue;
        _db.raw.execute(
            'INSERT INTO categories (id, name, sequence, parent_id, odoo_id, source, active) '
            "VALUES (?,?,?,?,?,'odoo',1)",
            [c.id, c.name, c.sequence, c.parentId, c.id]);
      }
      for (final p in products) {
        if (claimedProducts.contains(p.id)) continue;
        _db.raw.execute(
            'INSERT INTO products (id, name, price, category_id, barcode, active, sold_by_weight, tax_rate, cost, image, odoo_id, source) '
            "VALUES (?,?,?,?,?,?,?,?,?,?,?,'odoo')",
            [p.id, p.name, p.price, p.categoryId, p.barcode, p.active ? 1 : 0,
             p.soldByWeight ? 1 : 0, p.taxRate, p.cost, productImages[p.id], p.id]);
      }
      for (final g in groups) {
        _db.raw.execute(
            'INSERT INTO modifier_groups (id, name, sequence, min_selection, max_selection, required, auto_add, source) '
            "VALUES (?,?,?,?,?,?,?,'odoo')",
            [g.id, g.name, g.sequence, g.minSelection, g.maxSelection,
             g.required ? 1 : 0, g.autoAdd ? 1 : 0]);
        for (final m in g.modifiers) {
          _db.raw.execute(
              'INSERT INTO modifiers (id, group_id, name, price, price_type, sequence, product_id, is_default, source) '
              "VALUES (?,?,?,?,?,?,?,?,'odoo')",
              [m.id, g.id, m.name, m.price, m.priceType.name, m.sequence,
               m.productId, m.isDefault ? 1 : 0]);
        }
      }
      productGroupIds.forEach((productId, groupIds) {
        for (final gid in groupIds) {
          _db.raw.execute(
              "INSERT OR IGNORE INTO product_modifier_groups (product_id, group_id, source) VALUES (?,?,'odoo')",
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
      // The products are gone, so whatever pictures were held in memory describe a
      // menu that no longer exists.
      _images = null;
    } catch (_) {
      _db.raw.execute('ROLLBACK');
      rethrow;
    }
  }

  /// The Odoo record ids a pull must not write a row for, because the till already
  /// has one standing for them.
  ///
  /// Two ways a local row lays claim, and both matter. The `odoo_id` is the link a
  /// manager set, and skipping it is what stops a linked dish appearing twice on the
  /// grid. The row's own `id` matters for the other direction: a pulled item edited
  /// here keeps the Odoo id it was given, and if somebody then clears the link the
  /// row still sits on that id, so a pull that re-sent the record would collide with
  /// it and take the whole refresh down.
  Set<int> _claimed(String table) {
    final claimed = <int>{};
    for (final r
        in _db.raw.select("SELECT id, odoo_id FROM $table WHERE source = 'local'")) {
      claimed.add(r['id'] as int);
      final linked = r['odoo_id'] as int?;
      if (linked != null) claimed.add(linked);
    }
    return claimed;
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

  /// Keep [found] alongside the customers the last pull brought down, so a partner
  /// looked up once on the server is pickable again with the line down. Matched on
  /// the partner id: a customer already held is refreshed, not duplicated. The next
  /// full pull replaces the lot, which is what keeps this from growing forever.
  void mergeCustomers(List<Customer> found) {
    if (found.isEmpty) return;
    final byId = {for (final c in customers(limit: 1 << 30)) c.id: c};
    for (final c in found) {
      byId[c.id] = c;
    }
    _db.raw.execute(
        "INSERT INTO catalogue_meta (key, value) VALUES ('customers', ?) "
        "ON CONFLICT(key) DO UPDATE SET value = excluded.value",
        [jsonEncode(byId.values.map((c) => c.toMap()).toList())]);
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

  /// The categories the grid offers. Archived ones are held back by default: they
  /// stay on disk so the products filed under them and the sales that name them
  /// still resolve, and only the menu editor asks to see them.
  List<Category> categories({bool includeArchived = false}) => _db.raw
      .select('SELECT * FROM categories'
          '${includeArchived ? '' : ' WHERE active = 1'}'
          ' ORDER BY sequence, name')
      .map(_category)
      .toList();

  Category? categoryById(int id) {
    final rows = _db.raw.select('SELECT * FROM categories WHERE id = ?', [id]);
    return rows.isEmpty ? null : _category(rows.first);
  }

  Category _category(Map<String, Object?> r) => Category(
        id: r['id'] as int,
        name: r['name'] as String,
        sequence: r['sequence'] as int,
        parentId: r['parent_id'] as int?,
        odooId: r['odoo_id'] as int?,
        source: CatalogueSource.fromName(r['source'] as String?),
        active: (r['active'] as int? ?? 1) == 1,
      );

  List<Product> products(
      {int? categoryId, String? search, int limit = 200, bool includeArchived = false}) {
    final where = <String>[if (!includeArchived) 'active = 1'];
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
    final filter = where.isEmpty ? '1 = 1' : where.join(' AND ');
    return _db.raw
        .select('SELECT $_productColumns FROM products WHERE $filter '
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
      'id, name, price, category_id, barcode, active, sold_by_weight, tax_rate, cost, '
      'odoo_id, source, color';

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
        source: CatalogueSource.fromName(g['source'] as String?),
        modifiers: mods,
      );
    }).toList();
  }

  /// How many modifier groups each product carries, and whether any of them has to
  /// be answered, so the grid can mark those tiles.
  ///
  /// One grouped read of a small join table answers the whole grid. Asked per build
  /// rather than cached: a manager who adds a group in the editor must see the mark
  /// appear when they come back, and a cache keyed on the last pull would not notice
  /// an edit made here. The alternative, one lookup per tile per frame, is how a
  /// menu with photos starts costing a cashier taps.
  Map<int, ModifierMark> modifierMarks() => {
        for (final r in _db.raw.select(
            'SELECT pg.product_id AS id, COUNT(*) AS groups, MAX(g.required) AS req '
            'FROM product_modifier_groups pg '
            'JOIN modifier_groups g ON g.id = pg.group_id '
            'GROUP BY pg.product_id'))
          r['id'] as int: ModifierMark(
            groups: r['groups'] as int,
            required: (r['req'] as int? ?? 0) == 1,
          ),
      };

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
        odooId: r['odoo_id'] as int?,
        source: CatalogueSource.fromName(r['source'] as String?),
        color: r['color'] as int?,
      );

  // ── the menu editor ──────────────────────────────────────────────
  //
  // Everything below writes `source = 'local'`, which is what takes the row out of
  // the pull's hands for good. There is no separate "dirty" bit: owning the row and
  // having been touched here are the same fact, and one word is harder to get wrong
  // than two.

  /// Create a category on the till. Returns the new row.
  Category addCategory({
    required String name,
    int sequence = 0,
    int? odooId,
  }) {
    final id = _nextLocalId('categories');
    _db.raw.execute(
        "INSERT INTO categories (id, name, sequence, parent_id, odoo_id, source, active) "
        "VALUES (?,?,?,NULL,?,'local',1)",
        [id, name, sequence, odooId]);
    return categoryById(id)!;
  }

  /// Rename, reorder, relink or archive a category. Whatever it was, it is the
  /// till's from here on.
  void saveCategory(Category c) {
    _db.raw.execute(
        "UPDATE categories SET name = ?, sequence = ?, odoo_id = ?, active = ?, "
        "source = 'local' WHERE id = ?",
        [c.name, c.sequence, c.odooId, c.active ? 1 : 0, c.id]);
  }

  /// Take a category off the strip.
  ///
  /// Archived, not deleted, and for two reasons: the products filed under it and the
  /// sales that name it must still resolve, and a hard delete of a pulled row would
  /// simply be undone by the next refresh. Reversible from the editor.
  void archiveCategory(int id) =>
      _db.raw.execute("UPDATE categories SET active = 0, source = 'local' WHERE id = ?", [id]);

  /// Create a product on the till. [odooId] is the Odoo product it books against,
  /// or null for one nobody has linked yet.
  Product addProduct({
    required String name,
    required double price,
    int? categoryId,
    int? odooId,
    int? color,
    double taxRate = 0,
    String? barcode,
    bool soldByWeight = false,
    bool active = true,
  }) {
    final id = _nextLocalId('products');
    _db.raw.execute(
        'INSERT INTO products (id, name, price, category_id, barcode, active, '
        "sold_by_weight, tax_rate, cost, odoo_id, source, color) "
        "VALUES (?,?,?,?,?,?,?,?,0,?,'local',?)",
        [id, name, price, categoryId, barcode, active ? 1 : 0,
         soldByWeight ? 1 : 0, taxRate, odooId, color]);
    _images = null;
    return byId(id)!;
  }

  /// Write a product back. The picture column is deliberately not touched: it is
  /// kilobytes the editor never reads, and a save must not blank it.
  void saveProduct(Product p) {
    _db.raw.execute(
        'UPDATE products SET name = ?, price = ?, category_id = ?, barcode = ?, '
        "active = ?, sold_by_weight = ?, tax_rate = ?, odoo_id = ?, color = ?, "
        "source = 'local' WHERE id = ?",
        [p.name, p.price, p.categoryId, p.barcode, p.active ? 1 : 0,
         p.soldByWeight ? 1 : 0, p.taxRate, p.odooId, p.color, p.id]);
  }

  /// Take a product off the grid, keeping it restorable. Same reasoning as
  /// [archiveCategory]: a parked order and a printed receipt still name it.
  void archiveProduct(int id) =>
      _db.raw.execute("UPDATE products SET active = 0, source = 'local' WHERE id = ?", [id]);

  void restoreProduct(int id) =>
      _db.raw.execute("UPDATE products SET active = 1, source = 'local' WHERE id = ?", [id]);

  /// Attach a new modifier group to [productId]. Created and linked in one step,
  /// because a group nothing points at is not something a manager can mean.
  ModifierGroup addModifierGroup({
    required int productId,
    required String name,
    int minSelection = 0,
    int maxSelection = 0,
    bool required = false,
  }) {
    final id = _nextLocalId('modifier_groups');
    _db.raw.execute(
        'INSERT INTO modifier_groups (id, name, sequence, min_selection, max_selection, '
        "required, auto_add, source) VALUES (?,?,0,?,?,?,0,'local')",
        [id, name, minSelection, maxSelection, required ? 1 : 0]);
    _db.raw.execute(
        "INSERT OR IGNORE INTO product_modifier_groups (product_id, group_id, source) "
        "VALUES (?,?,'local')",
        [productId, id]);
    return modifierGroupsFor(productId).firstWhere((g) => g.id == id);
  }

  void saveModifierGroup(ModifierGroup g) {
    _db.raw.execute(
        'UPDATE modifier_groups SET name = ?, min_selection = ?, max_selection = ?, '
        "required = ?, source = 'local' WHERE id = ?",
        [g.name, g.minSelection, g.maxSelection, g.required ? 1 : 0, g.id]);
  }

  /// Drop a group and everything under it. Unlike a product, a group is not named by
  /// any past sale: the options a customer actually chose were copied onto the order
  /// line when it was rung, so removing the group cannot change a receipt.
  void removeModifierGroup(int groupId) {
    _db.raw.execute('DELETE FROM product_modifier_groups WHERE group_id = ?', [groupId]);
    _db.raw.execute('DELETE FROM modifiers WHERE group_id = ?', [groupId]);
    _db.raw.execute('DELETE FROM modifier_groups WHERE id = ?', [groupId]);
  }

  /// Add an option to a group. Locally created options are a flat amount on purpose:
  /// a percentage option is a pricing rule a shop maintains upstream, and offering
  /// one here is how "+10%" gets typed in and billed as ten pounds.
  Modifier addModifier({
    required int groupId,
    required String name,
    double price = 0,
    bool isDefault = false,
  }) {
    final id = _nextLocalId('modifiers');
    _db.raw.execute(
        'INSERT INTO modifiers (id, group_id, name, price, price_type, sequence, '
        "product_id, is_default, source) VALUES (?,?,?,?,'fixed',0,NULL,?,'local')",
        [id, groupId, name, price, isDefault ? 1 : 0]);
    return Modifier(
      id: id,
      groupId: groupId,
      name: name,
      price: price,
      isDefault: isDefault,
      source: CatalogueSource.local,
    );
  }

  void saveModifier(Modifier m) {
    _db.raw.execute(
        "UPDATE modifiers SET name = ?, price = ?, is_default = ?, source = 'local' "
        'WHERE id = ?',
        [m.name, m.price, m.isDefault ? 1 : 0, m.id]);
  }

  void removeModifier(int id) =>
      _db.raw.execute('DELETE FROM modifiers WHERE id = ?', [id]);

  /// The next id for a row created here.
  ///
  /// Negative and descending, so it can never collide with an Odoo id however the
  /// server's sequences move. The same trick a till-local customer uses, and for the
  /// same reason: the sign of the id says at a glance whose record it is.
  int _nextLocalId(String table) {
    final low = _db.raw.select('SELECT MIN(id) m FROM $table').first['m'] as int?;
    return (low == null || low >= 0) ? -1 : low - 1;
  }
}

/// What the grid needs to know about a product's modifiers without loading them.
class ModifierMark {
  const ModifierMark({required this.groups, required this.required});

  final int groups;

  /// Whether one of the groups must be answered before the item can be rung, which
  /// is a different thing for a cashier from "there are extras available".
  final bool required;
}
