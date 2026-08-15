import 'dart:convert';

import '../../domain/order.dart' show OrderType;
import '../auth/permissions.dart';
import '../printing/escpos.dart';
import 'database.dart';

/// On-device configuration a manager can change without a rebuild: shop name and
/// tax id on the receipt, receipt toggles, category colours, and the quick-pick
/// lists for notes and discount reasons.
///
/// A single key-value table backs all of it, so adding a setting is a write rather
/// than a migration. Reads are local and synchronous like the rest of the till.
class SettingsStore {
  SettingsStore(this._db) {
    publishPrintProfile();
  }

  final Db _db;

  // ── keys ─────────────────────────────────────────────────────────
  static const _shopName = 'shop_name';
  static const _taxId = 'tax_id';
  static const _receiptFooter = 'receipt_footer';
  static const _quickComments = 'quick_comments';
  static const _discountReasons = 'discount_reasons';
  static const _discountPercents = 'discount_percents';
  static const _maxDiscountPercent = 'max_discount_percent';
  static const _allowAmountDiscount = 'allow_amount_discount';
  static const _categoryColors = 'category_colors';
  static const _categoryStations = 'category_stations';
  static const _productStations = 'product_stations';
  static const _categoryTax = 'category_tax';
  static const _serviceChargePercent = 'service_charge_percent';
  static const _serviceChargeOrderTypes = 'service_charge_order_types';
  static const _receiptShowTax = 'receipt_show_tax';
  static const _language = 'language';
  static const _unavailableProducts = 'unavailable_products';
  static const _favourites = 'favourite_products';
  static const _gridColumns = 'grid_columns';
  static const _rolePermissions = 'role_permissions';
  static const _codePage = 'receipt_code_page';
  static const _arabicRaster = 'receipt_arabic_raster';

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

  /// Whether the discount dialogs also take a money amount ("50 off"). Off by
  /// default, because a shop that discounts in percent only should not be shown a
  /// second field to mis-tap. The amount is converted to the equivalent percentage
  /// when it is applied, so orders, receipts and reports stay percent-based and the
  /// configured cap still bites.
  bool get allowAmountDiscount => getBool(_allowAmountDiscount);
  set allowAmountDiscount(bool v) => setBool(_allowAmountDiscount, v);

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

  /// Category id to kitchen station(s) (printer names), so a multi-station kitchen
  /// can route one category to several printers at once (e.g. a shared side that
  /// prints at both the grill and the expo pass). Empty means everything goes to
  /// the single default kitchen.
  ///
  /// A value saved before a category could have more than one station is a bare
  /// string rather than a list; that is read as a one-item list so old data keeps
  /// working without a migration.
  Map<int, List<String>> get categoryStations {
    final v = getString(_categoryStations);
    if (v == null) return const {};
    try {
      return (jsonDecode(v) as Map).map((k, val) => MapEntry(
          int.parse(k as String), _asStationList(val)));
    } catch (_) {
      return const {};
    }
  }

  set categoryStations(Map<int, List<String>> v) => setString(
      _categoryStations, jsonEncode(v.map((k, val) => MapEntry('$k', val))));

  /// Tax rate (percent) per category, overridable per order type, so a shop can set
  /// (say) 14% dine-in and 0% takeaway on food. A category absent from the matrix,
  /// or an order type absent for a category, falls back to the product's own rate
  /// (so nothing changes until a manager configures it). Prices stay tax-inclusive:
  /// the rate drives how much tax is shown/reported, not what the customer pays.
  Map<int, Map<OrderType, double>> get categoryTaxRates {
    final v = getString(_categoryTax);
    if (v == null) return const {};
    try {
      return (jsonDecode(v) as Map).map((k, val) => MapEntry(
            int.parse(k as String),
            (val as Map).map((t, r) =>
                MapEntry(OrderType.values.byName(t as String), (r as num).toDouble())),
          ));
    } catch (_) {
      return const {};
    }
  }

  /// The configured rate for a category in a given order type, or null if none is
  /// set (caller then keeps the product's own rate).
  double? categoryTaxRate(int categoryId, OrderType type) =>
      categoryTaxRates[categoryId]?[type];

  /// Set (or clear, with null) the rate for one category + order type.
  void setCategoryTaxRate(int categoryId, OrderType type, double? rate) {
    final map = {
      for (final e in categoryTaxRates.entries) e.key: {...e.value},
    };
    final row = map.putIfAbsent(categoryId, () => {});
    if (rate == null) {
      row.remove(type);
      if (row.isEmpty) map.remove(categoryId);
    } else {
      row[type] = rate;
    }
    setString(
        _categoryTax,
        jsonEncode(map.map((k, val) =>
            MapEntry('$k', val.map((t, r) => MapEntry(t.name, r))))));
  }

  // ── service charge ───────────────────────────────────────────────

  /// The service percentage a table-service shop bills on top of the food. Zero (the
  /// default) means the shop does not charge service at all.
  ///
  /// This is the shop's current rule, not what a given bill carries: the percentage is
  /// stamped onto an order when it is opened, so editing this never re-prices a bill
  /// that is already running.
  double get serviceChargePercent =>
      double.tryParse(getString(_serviceChargePercent) ?? '') ?? 0;

  set serviceChargePercent(double v) => setString(_serviceChargePercent,
      v <= 0 ? null : v.clamp(0, 100).toStringAsFixed(v == v.roundToDouble() ? 0 : 1));

  /// Which order types the charge applies to. Never configured means dine-in only: a
  /// takeaway bag is not table service. An explicitly empty selection is kept as such
  /// (it reads as "charge nothing"), rather than silently reverting to the default.
  Set<OrderType> get serviceChargeOrderTypes {
    final raw = getString(_serviceChargeOrderTypes);
    if (raw == null) return const {OrderType.dineIn};
    try {
      final names = (jsonDecode(raw) as List).map((e) => e.toString()).toSet();
      return OrderType.values.where((t) => names.contains(t.name)).toSet();
    } catch (_) {
      return const {OrderType.dineIn};
    }
  }

  set serviceChargeOrderTypes(Set<OrderType> v) => setString(
      _serviceChargeOrderTypes, jsonEncode(v.map((t) => t.name).toList()));

  void setServiceChargeOrderType(OrderType type, bool enabled) {
    final set = serviceChargeOrderTypes.toSet();
    if (enabled) {
      set.add(type);
    } else {
      set.remove(type);
    }
    serviceChargeOrderTypes = set;
  }

  /// The percentage to stamp on a new order of [type]: the configured rate for the
  /// types that carry service, and zero for the rest.
  double serviceChargePercentFor(OrderType type) =>
      serviceChargeOrderTypes.contains(type) ? serviceChargePercent : 0;

  /// Repoint every category and product route from [oldStation] to [newStation]
  /// when a printer is renamed, so its tickets keep reaching it rather than
  /// falling back to the default kitchen.
  void renameStation(String oldStation, String newStation) {
    if (oldStation == newStation) return;
    Map<int, List<String>> remap(Map<int, List<String>> m) => {
          for (final e in m.entries)
            e.key: <String>{
              for (final s in e.value) s == oldStation ? newStation : s,
            }.toList(),
        };
    categoryStations = remap(categoryStations);
    productStations = remap(productStations);
  }

  /// Adds or removes one station from a category's routing without disturbing any
  /// other station already set on it, so a category can be pointed at several
  /// printers one toggle at a time.
  void setCategoryStation(int categoryId, String station, bool enabled) {
    final map = <int, List<String>>{
      for (final entry in categoryStations.entries) entry.key: List.of(entry.value),
    };
    final stations = List<String>.from(map[categoryId] ?? const []);
    if (enabled) {
      if (!stations.contains(station)) stations.add(station);
    } else {
      stations.remove(station);
    }
    if (stations.isEmpty) {
      map.remove(categoryId);
    } else {
      map[categoryId] = stations;
    }
    categoryStations = map;
  }

  /// Product id to kitchen station(s), overriding its category's routing for just
  /// that product. Empty means every product routes by whatever its category is
  /// set to (or the default kitchen if neither is set).
  Map<int, List<String>> get productStations {
    final v = getString(_productStations);
    if (v == null) return const {};
    try {
      return (jsonDecode(v) as Map).map((k, val) => MapEntry(
          int.parse(k as String), _asStationList(val)));
    } catch (_) {
      return const {};
    }
  }

  set productStations(Map<int, List<String>> v) => setString(
      _productStations, jsonEncode(v.map((k, val) => MapEntry('$k', val))));

  /// Adds or removes one station from a product's override routing, mirroring
  /// [setCategoryStation] but per-product.
  void setProductStation(int productId, String station, bool enabled) {
    final map = <int, List<String>>{
      for (final entry in productStations.entries) entry.key: List.of(entry.value),
    };
    final stations = List<String>.from(map[productId] ?? const []);
    if (enabled) {
      if (!stations.contains(station)) stations.add(station);
    } else {
      stations.remove(station);
    }
    if (stations.isEmpty) {
      map.remove(productId);
    } else {
      map[productId] = stations;
    }
    productStations = map;
  }

  /// A decoded routing value as a list of station names, whether it was saved as
  /// the old single string or the current list.
  List<String> _asStationList(Object? val) =>
      val is List ? val.map((e) => e.toString()).toList() : [val.toString()];

  /// UI language code: 'en' or 'ar'. Drives translation and text direction.
  String get language => getString(_language) ?? 'en';
  set language(String code) {
    setString(_language, code);
    // Whether Arabic is rendered on paper follows the language until a manager says
    // otherwise, so switching the till to Arabic fixes the receipts too.
    publishPrintProfile();
  }

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

  // ── the LAN state fabric ─────────────────────────────────────────

  /// Whether this device shares its parked orders, kitchen tickets and floor plan
  /// with the other devices in the shop.
  ///
  /// [fallback] is what the build was compiled with, so an installer can ship a
  /// two-till shop with the fabric on and a one-till shop with it off, and either
  /// can still be changed on the device. Off means no socket is opened at all.
  bool lanEnabled({bool fallback = false}) => getBool('lan_enabled', fallback: fallback);
  void setLanEnabled(bool v) => setBool('lan_enabled', v);

  /// What this device calls itself to the others ("Front till", "Kitchen"). Null
  /// until someone names it, and then it is the name that shows on their screens
  /// instead of a device id nobody can act on.
  String? get lanDeviceName => getString('lan_device_name');
  set lanDeviceName(String? v) => setString('lan_device_name', v?.trim());

  /// The key the devices in one shop share, which is what makes them a shop rather
  /// than whatever else is plugged into the switch. Held here because this database
  /// is encrypted at rest; it is a pairing secret between tills, never a server
  /// credential.
  String? get lanShopKey => getString('lan_shop_key');
  set lanShopKey(String? v) => setString('lan_shop_key', v?.trim());

  /// Receipt paper width in characters: 42 for 80mm (default), 32 for 58mm.
  int get receiptColumns => int.tryParse(getString('receipt_columns') ?? '') ?? 42;
  set receiptColumns(int n) => setString('receipt_columns', '$n');

  /// How many copies of each receipt to print (1-3).
  int get receiptCopies => int.tryParse(getString('receipt_copies') ?? '') ?? 1;
  set receiptCopies(int n) => setString('receipt_copies', '${n.clamp(1, 3)}');

  /// Kick the cash drawer open on a cash sale. On by default.
  bool get openDrawerOnSale => getBool('open_drawer_on_sale', fallback: true);
  set openDrawerOnSale(bool v) => setBool('open_drawer_on_sale', v);

  // ── receipt designer: what prints ────────────────────────────────
  // All on by default, so a till that never visits the designer prints the full
  // slip it printed before these existed.

  /// Print the time of sale near the top of the receipt.
  bool get receiptShowDateTime => getBool('receipt_show_datetime', fallback: true);
  set receiptShowDateTime(bool v) => setBool('receipt_show_datetime', v);

  /// Print the order's own reference (#ABC123).
  bool get receiptShowNumber => getBool('receipt_show_number', fallback: true);
  set receiptShowNumber(bool v) => setBool('receipt_show_number', v);

  /// Print the table and cover count on a dine-in slip.
  bool get receiptShowTable => getBool('receipt_show_table', fallback: true);
  set receiptShowTable(bool v) => setBool('receipt_show_table', v);

  /// Print how the sale was tendered (one line per payment).
  bool get receiptShowPayment => getBool('receipt_show_payment', fallback: true);
  set receiptShowPayment(bool v) => setBool('receipt_show_payment', v);

  /// Print the amount column next to each item. Off leaves names and quantities,
  /// which is what a packing slip wants.
  bool get receiptShowItemPrice => getBool('receipt_show_itemprice', fallback: true);
  set receiptShowItemPrice(bool v) => setBool('receipt_show_itemprice', v);

  /// Which character the receipt's separator lines are drawn with: 'line',
  /// 'equals', 'dots' or 'stars'.
  String get receiptDividerStyle => getString('receipt_divider_style') ?? 'line';
  set receiptDividerStyle(String v) => setString('receipt_divider_style', v);

  // ── what the printer can spell ───────────────────────────────────

  /// Which single-byte table the receipt printer is told to render bytes with:
  /// 'wpc1252' (Latin, the default) or 'wpc1256' (Arabic). Arabic is the fast path
  /// on a printer that has the table, because the firmware joins the letters and a
  /// line stays bytes; a printer without it prints those bytes as nonsense, so the
  /// choice belongs to the shop that owns the hardware.
  String get receiptCodePage => getString(_codePage) ?? 'wpc1252';
  set receiptCodePage(String v) {
    setString(_codePage, v);
    publishPrintProfile();
  }

  /// Render a line the table cannot carry as an image instead of printing question
  /// marks. Defaults to on for an Arabic till, which is the shop that needs it.
  bool get receiptArabicRaster =>
      getBool(_arabicRaster, fallback: language == 'ar');
  set receiptArabicRaster(bool v) {
    setBool(_arabicRaster, v);
    publishPrintProfile();
  }

  /// Hands the printing layer the two choices it cannot ask for: a receipt layout
  /// builds an [EscPos] with nothing but a column count, and that layer stays free
  /// of this database on purpose. Called on open and on every change to either.
  void publishPrintProfile() {
    EscPosPrintProfile.shared = EscPosPrintProfile(
      codePage: EscPosCodePage.byKey[receiptCodePage],
      rasterUnmappable: receiptArabicRaster,
    );
  }

  // ── role permissions ─────────────────────────────────────────────
  // Per role name, the set of permission keys that role may exercise WITHOUT
  // stopping for a manager PIN. Managers are never stored here: they are
  // unrestricted by definition, so reducing them is not allowed.

  /// The base a plain cashier starts with before a manager configures anything:
  /// harmless day-to-day actions that should never need approval.
  static const _cashierDefaults = {Permission.reprint, Permission.viewReports};

  /// The raw stored map, role -> set of permission keys. Unparsable or missing data
  /// reads as empty so a corrupt value falls back to defaults rather than throwing.
  Map<String, Set<String>> get _rolePermissionMap {
    final v = getString(_rolePermissions);
    if (v == null) return {};
    try {
      return (jsonDecode(v) as Map).map((k, val) => MapEntry(
          k as String, (val as List).map((e) => e.toString()).toSet()));
    } catch (_) {
      return {};
    }
  }

  /// The permissions [role] may perform without manager approval.
  ///
  /// A manager always gets every permission and cannot be reduced. Any other role
  /// returns its configured set; a 'cashier' with nothing saved falls back to a
  /// sensible base ([reprint], [viewReports]), and an unknown custom role starts
  /// with none.
  Set<Permission> permissionsFor(String role) {
    if (role == 'manager') return Permission.values.toSet();
    final map = _rolePermissionMap;
    if (!map.containsKey(role)) {
      return role == 'cashier' ? {..._cashierDefaults} : <Permission>{};
    }
    return map[role]!.map(Permission.fromKey).whereType<Permission>().toSet();
  }

  /// Grant or revoke one permission for [role]. A no-op for 'manager', who stays
  /// unrestricted. Seeds from the role's current effective set so toggling one
  /// permission never wipes the defaults a role started with.
  void setRolePermission(String role, Permission p, bool enabled) {
    if (role == 'manager') return;
    final map = _rolePermissionMap;
    final current =
        map[role] ?? permissionsFor(role).map((e) => e.key).toSet();
    if (enabled) {
      current.add(p.key);
    } else {
      current.remove(p.key);
    }
    map[role] = current;
    setString(_rolePermissions,
        jsonEncode(map.map((k, val) => MapEntry(k, val.toList()))));
  }

  /// Whether [role] may do [p] without a manager PIN.
  bool roleCan(String role, Permission p) => permissionsFor(role).contains(p);
}
