import '../../domain/catalogue.dart';
import '../../domain/delivery.dart';

/// The lookups a report reads besides the sales: the menu's categories, unit
/// costs, who the staff ids are, which tenders are cash, the drivers and the
/// shop's name.
///
/// A till sends one record of each per branch (see [toRecords]); the reports
/// site reads them back, from one branch or several, with [fromRecords].
class ReportLookups {
  const ReportLookups({
    this.categories = const [],
    this.costs = const {},
    this.staffNames = const {},
    this.cashTenderIds = const {},
    this.drivers = const [],
    this.shopName = '',
  });

  final List<Category> categories;
  final Map<int, double> costs;
  final Map<String, String> staffNames;
  final Set<int> cashTenderIds;
  final List<Driver> drivers;
  final String shopName;

  /// The record kinds this travels as, which are the server's snapshot kinds.
  static const kinds = ['categories', 'costs', 'staff', 'tenders', 'drivers', 'shop'];

  /// Payload per kind, as the till uploads them.
  Map<String, Object> toRecords() => {
        'categories': {
          'items': [
            for (final c in categories)
              {
                'id': c.id,
                'name': c.name,
                'sequence': c.sequence,
                'parent_id': c.parentId,
                'active': c.active,
              }
          ],
        },
        'costs': {
          'items': {for (final e in costs.entries) '${e.key}': e.value},
        },
        'staff': {'items': staffNames},
        'tenders': {'cash_ids': cashTenderIds.toList()..sort()},
        'drivers': {
          'items': [
            for (final d in drivers)
              {'id': d.id, 'name': d.name, 'phone': d.phone, 'active': d.active}
          ],
        },
        'shop': {'name': shopName},
      };

  /// The lookups from the records of one or more branches. Branches of one
  /// shop share a catalogue, so where two disagree the later one simply wins.
  factory ReportLookups.fromRecords(
      Iterable<({String kind, Map<String, Object?> payload})> records) {
    final categories = <int, Category>{};
    final costs = <int, double>{};
    final staff = <String, String>{};
    final cash = <int>{};
    final drivers = <String, Driver>{};
    var shop = '';
    List<Object?> list(Object? v) => v is List ? v : const [];
    Map<String, Object?> map(Object? v) =>
        v is Map ? v.cast<String, Object?>() : const {};
    for (final r in records) {
      final p = r.payload;
      switch (r.kind) {
        case 'categories':
          for (final raw in list(p['items'])) {
            final c = map(raw);
            final id = (c['id'] as num).toInt();
            categories[id] = Category(
              id: id,
              name: '${c['name'] ?? ''}',
              sequence: (c['sequence'] as num?)?.toInt() ?? 0,
              parentId: (c['parent_id'] as num?)?.toInt(),
              active: c['active'] != false,
            );
          }
        case 'costs':
          for (final e in map(p['items']).entries) {
            final id = int.tryParse(e.key);
            final cost = e.value;
            if (id != null && cost is num) costs[id] = cost.toDouble();
          }
        case 'staff':
          for (final e in map(p['items']).entries) {
            staff[e.key] = '${e.value}';
          }
        case 'tenders':
          for (final id in list(p['cash_ids'])) {
            if (id is num) cash.add(id.toInt());
          }
        case 'drivers':
          for (final raw in list(p['items'])) {
            final d = map(raw);
            final id = '${d['id']}';
            drivers[id] = Driver(
              id: id,
              name: '${d['name'] ?? ''}',
              phone: d['phone'] as String?,
              active: d['active'] != false,
            );
          }
        case 'shop':
          final name = '${p['name'] ?? ''}';
          if (name.isNotEmpty) shop = name;
      }
    }
    return ReportLookups(
      categories: categories.values.toList()
        ..sort((a, b) => a.sequence.compareTo(b.sequence)),
      costs: costs,
      staffNames: staff,
      cashTenderIds: cash,
      drivers: drivers.values.toList(),
      shopName: shop,
    );
  }
}
