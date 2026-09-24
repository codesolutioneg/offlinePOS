/// Where in Odoo this till's sales belong: the company, the point of sale and the
/// warehouse the stock leaves from.
///
/// Published by [SettingsStore] the way the print profile and the catalogue pull
/// options are: the sender is built once at startup and a manager can set these at
/// any point after that. Read when a sale is pushed rather than when it is rung, so
/// a week of takings taken before the ids were typed still books in the right place.
///
/// Ids only. A name would have to be resolved against a server the till cannot
/// assume is there, and the shop is identified on the wire by what Odoo keys on.
///
/// The *menu* branch (`branch.simple`) is stored separately on the till: one
/// company can hold many outlets, and products / tenders are filtered by that
/// outlet id, while booking still needs the company.
class OdooSite {
  const OdooSite({
    this.branchId,
    this.restaurantId,
    this.warehouseId,
    this.outletId,
  });

  static OdooSite shared = const OdooSite();

  /// The company sales book into (`res.company`). Kept as [branchId] on the wire
  /// name for the payload field history; it is not the `branch.simple` id.
  final int? branchId;

  /// The point of sale (`pos.config`) this till sells through. The one id the
  /// booking method already acts on: without it the server has to match the till by
  /// its device id, and a till whose device id was never set on any point of sale is
  /// refused outright.
  final int? restaurantId;

  /// The warehouse (`stock.warehouse`) the sold stock comes out of.
  final int? warehouseId;

  /// The outlet (`branch.simple`) for menu filters and End-of-Day session close.
  final int? outletId;

  bool get isEmpty =>
      branchId == null &&
      restaurantId == null &&
      warehouseId == null &&
      outletId == null;

  /// What rides on a pushed sale.
  ///
  /// Only ids the shop actually set travel. An unset id must never arrive as a zero:
  /// Odoo would read that as a real record and either book the sale somewhere
  /// nobody asked for or refuse it.
  Map<String, dynamic> get payloadFields => {
        if (branchId != null) 'company_id': branchId,
        if (restaurantId != null) 'config_id': restaurantId,
        if (warehouseId != null) 'warehouse_id': warehouseId,
        if (outletId != null) 'branch_id': outletId,
      };
}

/// The branch Odoo itself says this till belongs to, resolved from the login
/// rather than picked by hand: the shop lists its people on the branch record,
/// and the till adopts whichever branch names its user.
class OdooBoundSite {
  const OdooBoundSite({
    required this.name,
    required this.branchId,
    required this.companyId,
    this.warehouseId,
  });

  /// The branch's display name, for the audit trail and the settings screen.
  final String name;

  /// The `branch.simple` id: what filters the menu and the tenders.
  final int branchId;

  /// The branch's company: what sales book into.
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
  const OdooSiteOption({
    required this.id,
    required this.name,
    this.companyId,
    this.warehouseId,
    this.consolidateSessionInvoice = false,
    this.sessionPartnerId,
    this.sessionPartnerName,
  });

  final int id;
  final String name;

  /// The company this record belongs to, where Odoo holds one. Null means the
  /// record does not say, and a record that does not say is never hidden from a
  /// shop that has chosen a branch.
  final int? companyId;

  /// For a `branch.simple` row: the warehouse that branch sells from.
  final int? warehouseId;

  /// Branch End-of-Day setting: push the shift as one invoice (Dishflow).
  final bool consolidateSessionInvoice;

  /// Branch session invoice customer (`res.partner` id).
  final int? sessionPartnerId;

  /// Display name for [sessionPartnerId].
  final String? sessionPartnerName;

  Map<String, dynamic> toMap() => {
        'id': id,
        'name': name,
        'company_id': companyId,
        'warehouse_id': warehouseId,
        'consolidate_session_invoice': consolidateSessionInvoice,
        'session_partner_id': sessionPartnerId,
        'session_partner_name': sessionPartnerName,
      };

  factory OdooSiteOption.fromMap(Map<String, dynamic> m) => OdooSiteOption(
        id: m['id'] as int,
        name: (m['name'] ?? '') as String,
        companyId: m['company_id'] is int ? m['company_id'] as int : null,
        warehouseId:
            m['warehouse_id'] is int ? m['warehouse_id'] as int : null,
        consolidateSessionInvoice: m['consolidate_session_invoice'] == true,
        sessionPartnerId: m['session_partner_id'] is int
            ? m['session_partner_id'] as int
            : null,
        sessionPartnerName: m['session_partner_name'] as String?,
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
