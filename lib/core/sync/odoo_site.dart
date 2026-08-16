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
