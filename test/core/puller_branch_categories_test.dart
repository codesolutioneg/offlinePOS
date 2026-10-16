import 'package:flutter_test/flutter_test.dart';
import 'package:offline_pos/core/sync/odoo_puller.dart';

/// Branch "Categories" tab: order and hide on the till rail.
void main() {
  OdooPuller puller({
    int? branch,
    required List<Map<String, dynamic>> globalCats,
    List<Map<String, dynamic>> lines = const [],
  }) {
    return OdooPuller(
      branchId: branch == null ? null : () => branch,
      call: (model, method, args, kwargs) async {
        if (model == 'pos.category') return globalCats;
        if (model == 'branch.pos.category.line') {
          final domain = (args.first as List).cast<dynamic>();
          final wantsBranch = domain.any((c) =>
              c is List && c.first == 'branch_id' && c.last == branch);
          return wantsBranch ? lines : const [];
        }
        return const [];
      },
    );
  }

  test('empty branch lines keep the global category sequence', () async {
    final pull = await puller(
      branch: 3,
      globalCats: [
        {'id': 1, 'name': 'Burgers', 'sequence': 20, 'parent_id': false},
        {'id': 2, 'name': 'Drinks', 'sequence': 10, 'parent_id': false},
      ],
    ).pull();
    expect(pull.categories.map((c) => c.id).toList(), [1, 2]);
    expect(pull.categories.every((c) => c.active), isTrue);
  });

  test('branch lines reorder and hide categories on the rail', () async {
    final pull = await puller(
      branch: 3,
      globalCats: [
        {'id': 1, 'name': 'Burgers', 'sequence': 10, 'parent_id': false},
        {'id': 2, 'name': 'Drinks', 'sequence': 20, 'parent_id': false},
        {'id': 3, 'name': 'Hidden', 'sequence': 30, 'parent_id': false},
      ],
      lines: [
        {'pos_categ_id': [2, 'Drinks'], 'sequence': 1, 'visible': true},
        {'pos_categ_id': [1, 'Burgers'], 'sequence': 2, 'visible': true},
        {'pos_categ_id': [3, 'Hidden'], 'sequence': 3, 'visible': false},
      ],
    ).pull();
    final active = pull.categories.where((c) => c.active).toList()
      ..sort((a, b) => a.sequence.compareTo(b.sequence));
    expect(active.map((c) => c.id).toList(), [2, 1]);
    expect(pull.categories.singleWhere((c) => c.id == 3).active, isFalse);
  });

  test('no branch leaves categories untouched', () async {
    final pull = await puller(
      globalCats: [
        {'id': 1, 'name': 'Burgers', 'sequence': 5, 'parent_id': false},
      ],
      lines: [
        {'pos_categ_id': [1, 'Burgers'], 'sequence': 99, 'visible': false},
      ],
    ).pull();
    expect(pull.categories.single.active, isTrue);
    expect(pull.categories.single.sequence, 5);
  });
}
