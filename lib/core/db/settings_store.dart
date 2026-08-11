import 'dart:convert';

import 'database.dart';

/// On-device configuration a manager can change without a rebuild: shop name and
/// tax id on the receipt, receipt toggles, category colours, and the quick-pick
/// lists for notes and discount reasons.
///
/// A single key-value table backs all of it, so adding a setting is a write rather
/// than a migration. Reads are local and synchronous like the rest of the till.
class SettingsStore {
  SettingsStore(this._db);

  final Db _db;

  // ── keys ─────────────────────────────────────────────────────────
  static const _shopName = 'shop_name';
  static const _taxId = 'tax_id';
  static const _receiptFooter = 'receipt_footer';
  static const _quickComments = 'quick_comments';
  static const _discountReasons = 'discount_reasons';
  static const _discountPercents = 'discount_percents';
  static const _maxDiscountPercent = 'max_discount_percent';
  static const _categoryColors = 'category_colors';
  static const _categoryStations = 'category_stations';
  static const _receiptShowTax = 'receipt_show_tax';
  static const _language = 'language';
  static const _unavailableProducts = 'unavailable_products';
  static const _favourites = 'favourite_products';
  static const _gridColumns = 'grid_columns';

  // ── generic accessors ────────────────────────────────────────────
  String? getString(String key) {
    final rows = _db.raw.select('SELECT value FROM app_settings WHERE key = ?', [key]);
    return rows.isEmpty ? null : rows.first['value'] as String;
  }

  void setString(String key, String? value) {
    if (value == null || value.isEmpty) {
      _db.raw.execute('DELETE FROM app_settings WHERE key = ?', [key]);
      return;
    }
    _db.raw.execute(
      'INSERT INTO app_settings (key, value) VALUES (?, ?) '
      'ON CONFLICT(key) DO UPDATE SET value = excluded.value',
      [key, value],
    );
  }

  bool getBool(String key, {bool fallback = false}) {
    final v = getString(key);
    return v == null ? fallback : v == '1';
  }

  void setBool(String key, bool value) => setString(key, value ? '1' : '0');

  List<String> getStringList(String key) {
    final v = getString(key);
    if (v == null) return const [];
    try {
      return (jsonDecode(v) as List).map((e) => e.toString()).toList();
    } catch (_) {
      return const [];
    }
  }

  void setStringList(String key, List<String> values) =>
      setString(key, jsonEncode(values));

  // ── typed convenience ────────────────────────────────────────────
  String? get shopName => getString(_shopName);
  set shopName(String? v) => setString(_shopName, v);

  String? get taxId => getString(_taxId);
  set taxId(String? v) => setString(_taxId, v);

  String? get receiptFooter => getString(_receiptFooter);
  set receiptFooter(String? v) => setString(_receiptFooter, v);

  bool get receiptShowTax => getBool(_receiptShowTax, fallback: true);
  set receiptShowTax(bool v) => setBool(_receiptShowTax, v);

  /// Kitchen-note quick picks shown on the line-note dialog. A default set until a
  /// manager curates their own.
  List<String> get quickComments {
    final v = getStringList(_quickComments);
    return v.isEmpty
        ? const ['No onions', 'Extra spicy', 'Well done', 'Allergy']
        : v;
  }

  set quickComments(List<String> v) => setStringList(_quickComments, v);

  /// Discount reason quick picks shown on the discount dialog.
  List<String> get discountReasons {
    final v = getStringList(_discountReasons);
    return v.isEmpty
        ? const ['Manager comp', 'Loyalty', 'Staff meal', 'Complaint']
        : v;
  }

  set discountReasons(List<String> v) => setStringList(_discountReasons, v);

  /// The preset discount percentages offered as quick-pick chips when applying a
  /// discount. Editable by a manager; a sensible default until then.
  List<double> get discountPercents {
    final v = getStringList(_discountPercents);
    if (v.isEmpty) return const [5, 10, 15, 20];
    return v.map((e) => double.tryParse(e) ?? 0).where((e) => e > 0).toList();
  }

  set discountPercents(List<double> v) => setStringList(
      _discountPercents,
      (v.toList()..sort()).map((e) => e.toStringAsFixed(e == e.roundToDouble() ? 0 : 1)).toList());

  /// The largest discount a cashier may apply (0 = no cap). Guards against a
  /// fat-fingered 100% off.
  double get maxDiscountPercent =>
      double.tryParse(getString(_maxDiscountPercent) ?? '') ?? 0;
  set maxDiscountPercent(double v) =>
      setString(_maxDiscountPercent, v <= 0 ? null : v.toStringAsFixed(0));

  /// Category id to colour (ARGB int), so the product grid can be colour-coded the
  /// way Dishflow does. Empty until a manager sets colours.
  Map<int, int> get categoryColors {
    final v = getString(_categoryColors);
    if (v == null) return const {};
    try {
      return (jsonDecode(v) as Map)
          .map((k, val) => MapEntry(int.parse(k as String), val as int));
    } catch (_) {
      return const {};
    }
  }

  set categoryColors(Map<int, int> v) => setString(
      _categoryColors, jsonEncode(v.map((k, val) => MapEntry('$k', val))));

  void setCategoryColor(int categoryId, int? argb) {
    final map = Map<int, int>.from(categoryColors);
    if (argb == null) {
      map.remove(categoryId);
    } else {
      map[categoryId] = argb;
    }
    categoryColors = map;
  }

  /// Category id to kitchen station (printer name), so a multi-station kitchen
  /// routes each item to the right printer. Empty means everything goes to the
  /// single default kitchen.
  Map<int, String> get categoryStations {
    final v = getString(_categoryStations);
    if (v == null) return const {};
    try {
      return (jsonDecode(v) as Map)
          .map((k, val) => MapEntry(int.parse(k as String), val as String));
    } catch (_) {
      return const {};
    }
  }

  set categoryStations(Map<int, String> v) => setString(
      _categoryStations, jsonEncode(v.map((k, val) => MapEntry('$k', val))));

  void setCategoryStation(int categoryId, String? station) {
    final map = Map<int, String>.from(categoryStations);
    if (station == null || station.isEmpty) {
      map.remove(categoryId);
    } else {
      map[categoryId] = station;
    }
    categoryStations = map;
  }

  /// UI language code: 'en' or 'ar'. Drives translation and text direction.
  String get language => getString(_language) ?? 'en';
  set language(String code) => setString(_language, code);

  /// Products marked sold-out ("86'd") on this till, so a run-out item can be
  /// blocked mid-service without waiting for an Odoo catalogue change.
  Set<int> get unavailableProducts =>
      getStringList(_unavailableProducts).map((e) => int.tryParse(e) ?? -1).where((e) => e >= 0).toSet();

  set unavailableProducts(Set<int> ids) =>
      setStringList(_unavailableProducts, ids.map((e) => '$e').toList());

  void setProductAvailable(int productId, bool available) {
    final set = unavailableProducts;
    if (available) {
      set.remove(productId);
    } else {
      set.add(productId);
    }
    unavailableProducts = set;
  }

  /// Products pinned as favourites for a quick-access grid.
  Set<int> get favourites =>
      getStringList(_favourites).map((e) => int.tryParse(e) ?? -1).where((e) => e >= 0).toSet();

  set favourites(Set<int> ids) => setStringList(_favourites, ids.map((e) => '$e').toList());

  void setFavourite(int productId, bool favourite) {
    final set = favourites;
    if (favourite) {
      set.add(productId);
    } else {
      set.remove(productId);
    }
    favourites = set;
  }

  /// Product-grid density: tiles per row. 0 = auto (fit by width).
  int get gridColumns => int.tryParse(getString(_gridColumns) ?? '') ?? 0;
  set gridColumns(int n) => setString(_gridColumns, n <= 0 ? null : '$n');
}
