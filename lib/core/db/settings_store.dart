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
  static const _categoryColors = 'category_colors';
  static const _categoryStations = 'category_stations';
  static const _receiptShowTax = 'receipt_show_tax';
  static const _language = 'language';

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
}
