import 'dart:convert';
import 'dart:typed_data';

import '../../domain/business_day.dart';
import '../../domain/order.dart' show OrderType;
import '../auth/permissions.dart';
import '../email/smtp_config.dart';
import '../lan/lan_event.dart';
import '../printing/escpos.dart';
import '../printing/printer_logo.dart';
import '../sync/odoo_puller.dart';
import '../theme/table_palette.dart';
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
    publishBusinessDayRule();
    publishCataloguePullOptions();
    publishTablePalette();
  }

  final Db _db;

  /// Announces a shop-wide setting change to the LAN fabric, or null with the
  /// fabric off (and then this class writes exactly what it always wrote).
  ///
  /// Assigned after construction rather than taken in the constructor, because the
  /// switch that decides whether there is a fabric at all is read from this very
  /// store: the node cannot exist before it.
  LanPublish? _publish;
  set publish(LanPublish? v) => _publish = v;

  // ── keys ─────────────────────────────────────────────────────────
  static const _shopName = 'shop_name';
  static const _taxId = 'tax_id';
  static const _receiptFooter = 'receipt_footer';
  static const _quickComments = 'quick_comments';
  static const _discountReasons = 'discount_reasons';
  static const _discountPercents = 'discount_percents';
  static const _maxDiscountPercent = 'max_discount_percent';
  static const _allowAmountDiscount = 'allow_amount_discount';
  static const _orderNoDay = 'order_no_day';
  static const _orderNoSeq = 'order_no_seq';
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
  static const _customRoles = 'custom_roles';
  static const _smtpHost = 'smtp_host';
  static const _smtpPort = 'smtp_port';
  static const _smtpSecurity = 'smtp_security';
  static const _smtpUsername = 'smtp_username';
  static const _smtpPassword = 'smtp_password';
  static const _smtpFrom = 'smtp_from';
  static const _zReportRecipients = 'z_report_recipients';
  static const _emailZReport = 'email_z_report';
  static const _roleOrderTypes = 'role_order_types';
  static const _shopOrderTypes = 'shop_order_types';
  static const _codePage = 'receipt_code_page';
  static const _arabicRaster = 'receipt_arabic_raster';
  static const _businessDayCutoverHour = 'business_day_cutover_hour';

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

  // ── the trading day ──────────────────────────────────────────────

  /// The hour the shop's trading day rolls over, 0-23. A restaurant serving past
  /// midnight books the small hours against the evening that produced them, so the
  /// night is one report and one cash-up instead of two.
  int get businessDayCutoverHour =>
      (int.tryParse(getString(_businessDayCutoverHour) ?? '') ??
              BusinessDay.defaultCutoverHour)
          .clamp(0, 23);

  set businessDayCutoverHour(int v) {
    setString(_businessDayCutoverHour, '${v.clamp(0, 23)}');
    publishBusinessDayRule();
  }

  /// Hands the domain the shop's day rule, so an order created anywhere is stamped
  /// with it. Called on open and on every change, like [publishPrintProfile].
  void publishBusinessDayRule() =>
      BusinessDay.shopCutoverHour = businessDayCutoverHour;

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

  /// Products marked sold-out ("86'd"), so a run-out item can be blocked
  /// mid-service without waiting for an Odoo catalogue change.
  ///
  /// Shop-wide when the LAN fabric is on: running out is a fact about the kitchen,
  /// not about one till, so the change is announced and every device ends up
  /// refusing the same item.
  Set<int> get unavailableProducts =>
      getStringList(_unavailableProducts).map((e) => int.tryParse(e) ?? -1).where((e) => e >= 0).toSet();

  set unavailableProducts(Set<int> ids) =>
      setStringList(_unavailableProducts, ids.map((e) => '$e').toList());

  /// The record key one product's availability is replicated under, so the
  /// last-write-wins clock is kept per product rather than per till.
  static String availabilityRecord(int productId) => 'product-$productId';

  void setProductAvailable(int productId, bool available) {
    final publish = _publish;
    _writeAvailability(
      productId,
      available,
      publish == null
          ? null
          : () => publish(
                LanEventKind.productAvailability,
                availabilityRecord(productId),
                {'product_id': productId, 'available': available},
              ),
    );
  }

  /// Apply an availability change that arrived from another till. Announces
  /// nothing: the origin till already told everybody, and echoing it back would
  /// have two devices claiming the same shout from the kitchen.
  void applyProductAvailable(int productId, bool available) =>
      _writeAvailability(productId, available, null);

  /// The single writer, optionally with its fabric event in the same transaction.
  ///
  /// A failed announce still commits: a till that knows an item is off must act on
  /// it whatever the other devices heard, exactly as a sale outranks replication.
  void _writeAvailability(int productId, bool available, void Function()? announce) {
    void write() {
      final set = unavailableProducts;
      if (available) {
        set.remove(productId);
      } else {
        set.add(productId);
      }
      unavailableProducts = set;
    }

    if (announce == null) {
      write();
      return;
    }
    _db.raw.execute('BEGIN');
    try {
      write();
      announce();
      _db.raw.execute('COMMIT');
    } catch (_) {
      _db.raw.execute('ROLLBACK');
      write();
    }
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

  // ── the number a human calls an order ────────────────────────────

  /// The next order number for this till, as `DDMM-SEQ-TAG`.
  ///
  /// The sequence is per trading day and per device: it restarts at 1 at the
  /// business-day cutover (so a service that runs past midnight keeps counting, and
  /// tomorrow starts at 1 again), and it carries a tag derived from the device id so
  /// two tills serving the same room never hand out the same number. Local, and
  /// deliberately not a server document number: the till has to be able to name an
  /// order with the line down.
  ///
  /// [now] is injectable for the rollover test; production reads the clock.
  String nextOrderNumber(String deviceId, {DateTime? now}) {
    final day = BusinessDay.of(now ?? DateTime.now());
    // A different trading day than the last number handed out means the counter
    // starts again, which is what makes the numbers short enough to say out loud.
    final seq = getString(_orderNoDay) == day.key
        ? (int.tryParse(getString(_orderNoSeq) ?? '') ?? 0) + 1
        : 1;
    setString(_orderNoDay, day.key);
    setString(_orderNoSeq, '$seq');
    String two(int n) => n.toString().padLeft(2, '0');
    final d = day.date;
    return '${two(d.day)}${two(d.month)}-${seq.toString().padLeft(3, '0')}-'
        '${tillTagFor(deviceId)}';
  }

  /// A short, stable tag for a device: the last three alphanumeric characters of its
  /// id, uppercased. The id is a client-generated uuid, so its tail is as good as a
  /// hash, and three characters keep the number sayable while making a clash between
  /// the two or three tills in one shop vanishingly unlikely.
  static String tillTagFor(String deviceId) {
    final letters =
        deviceId.toUpperCase().replaceAll(RegExp('[^A-Z0-9]'), '');
    if (letters.isEmpty) return 'XXX';
    final tail = letters.length <= 3 ? letters : letters.substring(letters.length - 3);
    return tail.padLeft(3, 'X');
  }

  /// Ask how many are sitting down when a table is seated. Off by default: a shop
  /// where one cashier serves the room gains nothing from a dialog between tapping
  /// a table and ringing the first drink, and the covers can still be set from the
  /// Guests chip whenever they matter.
  bool get askGuestCount => getBool('ask_guest_count');
  set askGuestCount(bool v) => setBool('ask_guest_count', v);

  /// Draw the floor's sections down the side of the plan rather than as a strip
  /// above it. On by default: a waiter reads a short vertical list of rooms faster
  /// than a horizontal one that scrolls off the edge, and the width it costs is
  /// width the plan pans through anyway. A narrow till can put them back on top.
  bool get floorSectionsSide => getBool('floor_sections_side', fallback: true);
  set floorSectionsSide(bool v) => setBool('floor_sections_side', v);

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

  /// Whether another till may take over a tab parked on this one.
  ///
  /// Off by default, and that default is the safe answer rather than a timid one: a
  /// bill is settled where it was opened, so nothing can end up booked twice. A shop
  /// running waiter handhelds against a counter cashier needs the other answer, and
  /// switches it on knowing that the handover still asks this device first.
  bool get lanAllowTakeover => getBool('lan_allow_takeover');
  set lanAllowTakeover(bool v) => setBool('lan_allow_takeover', v);

  // ── the floor with more than one person on it ────────────────────

  /// Whether a tab opened by one cashier asks before another one picks it up.
  ///
  /// Off by default, because most shops run one cashier at a time and a prompt
  /// between a waiter and their own table is friction for nothing. A shop where
  /// several people share a till and each answers for their own drawer wants the
  /// other answer: the cashier who opened the tab unlocks it, or a manager does.
  bool get tableSecurity => getBool('table_security');
  set tableSecurity(bool v) => setBool('table_security', v);

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

  // ── what a tender is called on paper ─────────────────────────────

  /// Payment method id to the name the receipt should print for it, so a shop can
  /// say "Visa/Mastercard" or "InstaPay" where Odoo says "Bank". Display only: the
  /// method id and everything that goes to the server are untouched, so a renamed
  /// tender still books and still reports as itself.
  Map<int, String> get paymentMethodLabels {
    final v = getString('payment_method_labels');
    if (v == null) return const {};
    try {
      return (jsonDecode(v) as Map).map(
          (k, val) => MapEntry(int.parse(k as String), val.toString()));
    } catch (_) {
      return const {};
    }
  }

  set paymentMethodLabels(Map<int, String> v) => setString(
      'payment_method_labels', jsonEncode(v.map((k, val) => MapEntry('$k', val))));

  /// Set or clear one override. An empty label clears it, so a manager who empties
  /// the box gets the method's own name back rather than a blank line on the slip.
  void setPaymentMethodLabel(int methodId, String? label) {
    final map = Map<int, String>.from(paymentMethodLabels);
    final trimmed = label?.trim() ?? '';
    if (trimmed.isEmpty) {
      map.remove(methodId);
    } else {
      map[methodId] = trimmed;
    }
    paymentMethodLabels = map;
  }

  // ── letting a customer settle later ──────────────────────────────

  /// The payment method an on-account sale books against, or null when the shop
  /// does not run accounts. Off by default, and deliberately a nomination rather
  /// than an invented tender: the wire contract books real methods, so a shop that
  /// wants "pay later" points it at the method their accounts already use for a
  /// customer balance (never the cash one, or the drawer would be counted short).
  int? get payLaterMethodId {
    final id = int.tryParse(getString('pay_later_method_id') ?? '');
    return (id == null || id <= 0) ? null : id;
  }

  set payLaterMethodId(int? v) =>
      setString('pay_later_method_id', (v == null || v <= 0) ? null : '$v');

  // ── the shop's mark on the paper ─────────────────────────────────

  /// Print the shop logo at the top of the receipt. Off until a shop asks for it,
  /// because a logo the printer does not hold prints as nothing at best.
  bool get receiptPrintLogo => getBool('receipt_print_logo');
  set receiptPrintLogo(bool v) => setBool('receipt_print_logo', v);

  /// Send the picture with every receipt instead of printing the one in the
  /// printer's flash. Deliberately off and deliberately its own switch: it is
  /// kilobytes on the wire per slip, and only a printer with no flash needs it.
  bool get receiptLogoRaster => getBool('receipt_logo_raster');
  set receiptLogoRaster(bool v) => setBool('receipt_logo_raster', v);

  /// The dots of the logo last loaded on this device, so the raster route and the
  /// designer's preview do not need the source file again. Null until one is loaded;
  /// the flash route does not need it at all.
  PrinterLogo? get receiptLogo => PrinterLogo.decode(getString('receipt_logo'));
  set receiptLogo(PrinterLogo? v) => setString('receipt_logo', v?.encode());

  /// The command that puts the mark on a slip, or null when the shop prints none.
  /// One place decides between the two routes, so the sale receipt, the bill and the
  /// sample all carry the same header.
  Uint8List? receiptLogoCommand() {
    if (!receiptPrintLogo) return null;
    if (!receiptLogoRaster) return PrinterLogo.printStored();
    return receiptLogo?.raster();
  }

  // ── the second copy of the slip ──────────────────────────────────

  /// The station a no-price copy of every sale slip is sent to, so the pass gets a
  /// packing list of what the bag holds. Empty (the default) means no copy is
  /// printed at all and the till behaves exactly as it did before this existed.
  ///
  /// A station name, not an address: it is routed through the same registry every
  /// kitchen ticket is, so a copy follows the printer when its lease moves.
  String get subReceiptStation => getString('sub_receipt_station') ?? '';
  set subReceiptStation(String v) => setString('sub_receipt_station', v.trim());

  /// Whether that copy leaves the amount column off. On by default, because the
  /// reason to print it at the pass is that a runner should not be handing a
  /// customer a second priced slip.
  bool get subReceiptHidePrices => getBool('sub_receipt_hide_prices', fallback: true);
  set subReceiptHidePrices(bool v) => setBool('sub_receipt_hide_prices', v);

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
      textScale: EscPosTextScale.byKey[receiptFontProfile],
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

  void _writeRolePermissionMap(Map<String, Set<String>> map) => setString(
      _rolePermissions, jsonEncode(map.map((k, v) => MapEntry(k, v.toList()))));

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
    _writeRolePermissionMap(map);
  }

  /// Whether [role] may do [p] without a manager PIN.
  bool roleCan(String role, Permission p) => permissionsFor(role).contains(p);

  // ── roles the shop invented ──────────────────────────────────────
  // A restaurant is not two job titles. A supervisor who may void and discount but
  // not touch the server, a runner who may do neither: both are ordinary and both
  // used to need a manager standing next to the till. The permission plumbing
  // already takes any role string, so this is only the list of names that exist.

  /// The two names the app itself relies on. Neither can be re-invented as a
  /// custom role: 'manager' is unrestricted by definition and 'cashier' is the
  /// fallback every account lands on.
  static const Set<String> builtInRoles = {'manager', 'cashier'};

  /// Roles added on this till, in the order they were created. A fresh list every
  /// read: the empty case is a const literal, and callers edit what they get.
  List<String> get customRoles => [...getStringList(_customRoles)];

  /// Every role the roster may put someone on, manager aside. Manager is handed
  /// out separately because only a manager may create one.
  List<String> get assignableRoles => ['cashier', ...customRoles];

  /// Trimmed and collapsed, because "Head  waiter" and "Head waiter" being two
  /// roles is a difference nobody can see on screen and nobody meant.
  static String normaliseRole(String name) =>
      name.trim().replaceAll(RegExp(r'\s+'), ' ');

  /// Adds a role. False when the name is empty, is one of [builtInRoles], or
  /// already exists. Names are compared case-insensitively for the same reason
  /// they are collapsed: two roles that read the same are one role.
  bool addCustomRole(String name) {
    final role = normaliseRole(name);
    if (role.isEmpty || !_nameIsFree(role)) return false;
    setStringList(_customRoles, [...customRoles, role]);
    return true;
  }

  /// Renames a role and carries its permissions across, so a rename never
  /// silently strips what the role was allowed to do.
  ///
  /// Staff already on the old name are NOT moved here: this store knows nothing
  /// about the roster, so the caller reassigns them. Doing it in one place would
  /// mean this class reaching into another store's rows.
  bool renameCustomRole(String from, String to) {
    final target = normaliseRole(to);
    final roles = customRoles;
    final at = roles.indexOf(from);
    if (at < 0 || target.isEmpty) return false;
    // Same name in different letters is a rename worth allowing; any other clash
    // is not.
    if (target.toLowerCase() != from.toLowerCase() && !_nameIsFree(target)) {
      return false;
    }
    roles[at] = target;
    setStringList(_customRoles, roles);
    final map = _rolePermissionMap;
    final held = map.remove(from);
    if (held != null) map[target] = held;
    _writeRolePermissionMap(map);
    return true;
  }

  /// Removes a role and the permissions saved against it. Staff left on the name
  /// are the caller's to move, as with a rename.
  void deleteCustomRole(String name) {
    final roles = customRoles..remove(name);
    setStringList(_customRoles, roles);
    final map = _rolePermissionMap;
    if (map.remove(name) != null) _writeRolePermissionMap(map);
  }

  bool _nameIsFree(String role) {
    final lower = role.toLowerCase();
    if (builtInRoles.contains(lower)) return false;
    return !customRoles.any((r) => r.toLowerCase() == lower);
  }

  // ── outgoing mail ────────────────────────────────────────────────
  // The shop's own mailbox, for sending the Z report to an owner who is not in
  // the building. The password lives here like every other setting, in a
  // SQLCipher database encrypted at rest, and is never written to a log or a
  // receipt.

  String? get smtpHost => getString(_smtpHost);
  set smtpHost(String? v) => setString(_smtpHost, v?.trim());

  int get smtpPort =>
      int.tryParse(getString(_smtpPort) ?? '') ??
      SmtpConfig.defaultPortFor(smtpSecurity);
  set smtpPort(int v) => setString(_smtpPort, v <= 0 ? null : '$v');

  SmtpSecurity get smtpSecurity => SmtpSecurity.fromKey(getString(_smtpSecurity));
  set smtpSecurity(SmtpSecurity v) => setString(_smtpSecurity, v.key);

  String? get smtpUsername => getString(_smtpUsername);
  set smtpUsername(String? v) => setString(_smtpUsername, v?.trim());

  String? get smtpPassword => getString(_smtpPassword);
  set smtpPassword(String? v) => setString(_smtpPassword, v);

  String? get smtpFrom => getString(_smtpFrom);
  set smtpFrom(String? v) => setString(_smtpFrom, v?.trim());

  /// Who the Z report goes to. Empty is the default and means nothing is sent.
  List<String> get zReportRecipients => getStringList(_zReportRecipients);
  set zReportRecipients(List<String> v) => setStringList(
      _zReportRecipients,
      [
        for (final r in v)
          if (r.trim().isNotEmpty) r.trim(),
      ]);

  /// The master switch. Off by default: a shop that has not asked for mail at
  /// shift close does not get any.
  bool get emailZReport => getBool(_emailZReport, fallback: false);
  set emailZReport(bool v) => setBool(_emailZReport, v);

  /// The mail settings as one value, or null when the switch is off or there is
  /// not enough here to try. Read fresh on every send, so a corrected password
  /// takes effect on the next attempt rather than the next restart.
  SmtpConfig? get smtp {
    if (!emailZReport) return null;
    final config = SmtpConfig(
      host: smtpHost ?? '',
      port: smtpPort,
      security: smtpSecurity,
      from: smtpFrom ?? '',
      recipients: zReportRecipients,
      username: smtpUsername,
      password: smtpPassword,
    );
    return config.isComplete ? config : null;
  }

  // ── how the till looks and how big the paper prints ──────────────

  /// Light, dark, or whatever the device is set to. Stored as the key rather than
  /// the enum so this file stays free of Flutter's widget layer; [AppTheme] turns it
  /// back into a [ThemeMode].
  String get themeMode => getString('theme_mode') ?? 'system';
  set themeMode(String v) => setString('theme_mode', v);

  /// Show the product picture on its grid tile.
  ///
  /// Off by default and off on a shop that never asks for it: a picture is the only
  /// part of the catalogue measured in megabytes, so this switch decides whether they
  /// are downloaded at all as well as whether they are drawn.
  bool get showProductImages => getBool('show_product_images');
  set showProductImages(bool v) {
    setBool('show_product_images', v);
    publishCataloguePullOptions();
  }

  /// Hands the catalogue puller the one choice it cannot ask a database for. Called
  /// on open and on every change, like [publishPrintProfile].
  void publishCataloguePullOptions() =>
      CataloguePullOptions.shared = CataloguePullOptions(images: showProductImages);

  /// The two floor colours, as ARGB ints, or null while the shop is on the defaults.
  int? get tableColorFree => int.tryParse(getString('table_color_free') ?? '');
  int? get tableColorOccupied =>
      int.tryParse(getString('table_color_occupied') ?? '');

  /// Set one floor colour, or hand it back to the default with null.
  void setTableColorFree(int? argb) => _setTableColor('table_color_free', argb);

  void setTableColorOccupied(int? argb) =>
      _setTableColor('table_color_occupied', argb);

  void _setTableColor(String key, int? argb) {
    setString(key, argb?.toString());
    publishTablePalette();
  }

  /// Hands the floor the colours it draws with. Called on open and on every change.
  void publishTablePalette() => TablePalette.shared = TablePalette.fromArgb(
        free: tableColorFree,
        occupied: tableColorOccupied,
      );

  /// How big the body text prints: 'normal', 'tall' (same characters per line, twice
  /// the height) or 'large' (twice both ways, so half as many characters fit). A
  /// shop with older eyes on the counter reads the slip; the layout follows the
  /// choice rather than running off the edge of the roll.
  String get receiptFontProfile {
    final v = getString('receipt_font_profile') ?? 'normal';
    return EscPosTextScale.byKey.containsKey(v) ? v : 'normal';
  }

  set receiptFontProfile(String v) {
    setString('receipt_font_profile', v);
    publishPrintProfile();
  }

  // ── which sales a role may open ──────────────────────────────────
  // A delivery desk that cannot seat a table, or a counter that does not take
  // delivery orders, is a shop decision rather than a permission: there is no
  // manager PIN that makes sense as an override, so a type a role may not ring
  // simply is not offered.

  /// The order types [role] may start. Everything, until a manager narrows it: a
  /// till that has never seen this screen behaves exactly as it did before.
  /// A manager is never restricted, in line with every other role rule here.
  Set<OrderType> orderTypesFor(String role) {
    if (role == 'manager') return OrderType.values.toSet();
    final raw = getString(_roleOrderTypes);
    if (raw == null) return OrderType.values.toSet();
    try {
      final map = jsonDecode(raw) as Map;
      if (!map.containsKey(role)) return OrderType.values.toSet();
      final names = (map[role] as List).map((e) => e.toString()).toSet();
      final allowed = OrderType.values.where((t) => names.contains(t.name)).toSet();
      // A role that may ring nothing could take no money at all, so an empty set
      // reads as unrestricted rather than as a till nobody can sell on.
      return allowed.isEmpty ? OrderType.values.toSet() : allowed;
    } catch (_) {
      return OrderType.values.toSet();
    }
  }

  bool roleCanRing(String role, OrderType type) =>
      orderTypesFor(role).contains(type);

  /// Allow or refuse one order type for [role]. A no-op for 'manager', and for
  /// taking away the last type a role has left.
  void setRoleOrderType(String role, OrderType type, bool allowed) {
    if (role == 'manager') return;
    final current = orderTypesFor(role).toSet();
    if (allowed) {
      current.add(type);
    } else {
      if (current.length <= 1) return;
      current.remove(type);
    }
    final map = <String, List<String>>{};
    final raw = getString(_roleOrderTypes);
    if (raw != null) {
      try {
        (jsonDecode(raw) as Map).forEach((k, v) =>
            map[k as String] = (v as List).map((e) => e.toString()).toList());
      } catch (_) {
        // Unreadable saved value: replaced by what is being set now.
      }
    }
    map[role] = current.map((t) => t.name).toList();
    setString(_roleOrderTypes, jsonEncode(map));
  }

  // ── which sales the shop takes at all ────────────────────────────
  // Distinct from the role rule above and one level over it: a shop that does not
  // deliver has nobody who may ring a delivery, whatever any role says. Kept as its
  // own key so narrowing a role never quietly reopens a type the shop closed.

  /// The order types this shop offers. Everything until a manager narrows it.
  Set<OrderType> get shopOrderTypes {
    final raw = getString(_shopOrderTypes);
    if (raw == null) return OrderType.values.toSet();
    try {
      final names = (jsonDecode(raw) as List).map((e) => e.toString()).toSet();
      final offered = OrderType.values.where((t) => names.contains(t.name)).toSet();
      // A shop that offers nothing could take no money at all, so an empty saved
      // value reads as "everything" rather than as a till nobody can sell on.
      return offered.isEmpty ? OrderType.values.toSet() : offered;
    } catch (_) {
      return OrderType.values.toSet();
    }
  }

  set shopOrderTypes(Set<OrderType> v) {
    final offered = v.isEmpty ? OrderType.values.toSet() : v;
    setString(_shopOrderTypes, jsonEncode(offered.map((t) => t.name).toList()));
  }

  /// Offer or withdraw one order type shop-wide. Withdrawing the last one is a
  /// no-op, for the same reason the role rule refuses it.
  void setShopOrderType(OrderType type, bool offered) {
    final current = shopOrderTypes.toSet();
    if (offered) {
      current.add(type);
    } else {
      if (current.length <= 1) return;
      current.remove(type);
    }
    shopOrderTypes = current;
  }

  /// What [role] may actually ring on this till: the types the shop offers, narrowed
  /// by the types the role may open. The two compose rather than override, so a
  /// delivery the shop does not do cannot be reopened by a role rule, and a role
  /// kept off deliveries in a shop that does deliver still is.
  ///
  /// If the two have nothing in common (a delivery-only role in a shop that stopped
  /// delivering) the shop's word stands: a cashier standing at a till has to be able
  /// to sell something.
  Set<OrderType> availableOrderTypesFor(String role) {
    final shop = shopOrderTypes;
    final both = orderTypesFor(role).intersection(shop);
    return both.isEmpty ? shop : both;
  }
}
