/// Where in Odoo this till's sales belong: the branch, the point of sale and the
/// warehouse the stock leaves from.
///
/// Published by [SettingsStore] the way the print profile and the catalogue pull
/// options are: the sender is built once at startup and a manager can set these at
/// any point after that. Read when a sale is pushed rather than when it is rung, so
/// a week of takings taken before the ids were typed still books in the right place.
///
/// Ids only. A name would have to be resolved against a server the till cannot
/// assume is there, and the shop is identified on the wire by what Odoo keys on.
class OdooSite {
  const OdooSite({this.branchId, this.restaurantId, this.warehouseId});

  static OdooSite shared = const OdooSite();

  /// The branch, which in jouma is a company: its branch reports filter
  /// `account.move` on `company_id`, so a branch id is a `res.company` id.
  final int? branchId;

  /// The point of sale (`pos.config`) this till sells through. The one id the
  /// booking method already acts on: without it the server has to match the till by
  /// its device id, and a till whose device id was never set on any point of sale is
  /// refused outright.
  final int? restaurantId;

  /// The warehouse (`stock.warehouse`) the sold stock comes out of.
  final int? warehouseId;

  bool get isEmpty =>
      branchId == null && restaurantId == null && warehouseId == null;

  /// What rides on a pushed sale.
  ///
  /// Only ids the shop actually set travel. An unset id must never arrive as a zero:
  /// Odoo would read that as a real record and either book the sale somewhere
  /// nobody asked for or refuse it.
  Map<String, dynamic> get payloadFields => {
        if (branchId != null) 'company_id': branchId,
        if (restaurantId != null) 'config_id': restaurantId,
        if (warehouseId != null) 'warehouse_id': warehouseId,
      };
}

/// The branch Odoo itself says this till belongs to, resolved from the login
/// rather than picked by hand: the shop lists its people on the branch record,
/// and the till adopts whichever branch names its user.
class OdooBoundSite {
  const OdooBoundSite({
    required this.name,
    required this.companyId,
    this.warehouseId,
  });

  /// The branch's display name, for the audit trail and the settings screen.
  final String name;

  /// The branch's company, which is what the till stores as its branch id.
  final int companyId;

  /// The branch's warehouse, when the shop set one on the branch record.
  final int? warehouseId;
}

/// One record a manager can point this till at: a branch, a point of sale or a
/// warehouse, with the name Odoo calls it by.
///
/// Names are a convenience for the person choosing and never authority. Nobody
/// knows their warehouse's database id, so a picker has to show something else;
/// what travels on a sale is still [OdooSite], which is ids alone.
class OdooSiteOption {
  const OdooSiteOption({required this.id, required this.name, this.companyId});

  final int id;
  final String name;

  /// The company this record belongs to, where Odoo holds one. Null means the
  /// record does not say, and a record that does not say is never hidden from a
  /// shop that has chosen a branch.
  final int? companyId;

  Map<String, dynamic> toMap() =>
      {'id': id, 'name': name, 'company_id': companyId};

  factory OdooSiteOption.fromMap(Map<String, dynamic> m) => OdooSiteOption(
        id: m['id'] as int,
        name: (m['name'] ?? '') as String,
        companyId: m['company_id'] is int ? m['company_id'] as int : null,
      );
}

/// What Odoo has to offer behind the three pickers on the server screen.
///
/// Cached on the till after one successful read, so a manager on a till with no
/// line still sees names instead of bare numbers. A list that came back empty
/// means the question was not answered, never that the shop has none: the caller
/// keeps what it had rather than emptying a picker.
class OdooSiteChoices {
  const OdooSiteChoices({
    this.branches = const [],
    this.pointsOfSale = const [],
    this.warehouses = const [],
  });

  final List<OdooSiteOption> branches;
  final List<OdooSiteOption> pointsOfSale;
  final List<OdooSiteOption> warehouses;

  bool get isEmpty =>
      branches.isEmpty && pointsOfSale.isEmpty && warehouses.isEmpty;

  Map<String, dynamic> toMap() => {
        'branches': [for (final o in branches) o.toMap()],
        'points_of_sale': [for (final o in pointsOfSale) o.toMap()],
        'warehouses': [for (final o in warehouses) o.toMap()],
      };

  factory OdooSiteChoices.fromMap(Map<String, dynamic> m) => OdooSiteChoices(
        branches: _list(m['branches']),
        pointsOfSale: _list(m['points_of_sale']),
        warehouses: _list(m['warehouses']),
      );

  static List<OdooSiteOption> _list(Object? raw) => raw is! List
      ? const []
      : [
          for (final e in raw)
            if (e is Map && e['id'] is int)
              OdooSiteOption.fromMap(e.cast<String, dynamic>()),
        ];
}
