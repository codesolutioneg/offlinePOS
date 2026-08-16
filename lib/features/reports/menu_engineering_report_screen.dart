import 'package:flutter/material.dart';

import '../../core/i18n/l10n.dart';
import '../../core/theme/app_colors.dart';
import '../../core/widgets/feedback.dart';
import '../../domain/order.dart';
import 'product_margins.dart';
import 'report_export.dart';

/// Which dishes to push, reprice, or drop.
///
/// The classic menu-engineering read: every costed dish is placed against the
/// average of the window on two axes, how often it sells and how much of its price
/// the shop keeps. The four corners have names a chef already uses, and each one has
/// a different answer, which is the whole value of splitting them out rather than
/// ranking on either axis alone.
class MenuEngineeringReportScreen extends StatelessWidget {
  const MenuEngineeringReportScreen({
    super.key,
    required this.orders,
    required this.costs,
    required this.formatAmount,
  });

  final List<Order> orders;
  final Map<int, double> costs;
  final String Function(double) formatAmount;

  /// The costed dishes that actually moved. A dish with no cost cannot be placed on
  /// the margin axis, and one that sold nothing cannot be placed on the other, so
  /// neither is guessed at.
  List<ProductMargin> get _rows => productMargins(orders, costs)
      .where((r) => r.costed && r.units > 0)
      .toList();

  ReportTable _table(List<_Placed> rows) => ReportTable(
        header: const ['Product', 'Quadrant', 'Units', 'Margin', 'Margin %'],
        rows: [
          for (final p in rows)
            [
              p.row.name,
              p.quadrant.name,
              p.row.units.toStringAsFixed(
                  p.row.units == p.row.units.roundToDouble() ? 0 : 2),
              p.row.margin.toStringAsFixed(2),
              p.row.marginPercent.toStringAsFixed(1),
            ],
        ],
      );

  @override
  Widget build(BuildContext context) {
    final rows = _rows;
    if (rows.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: Text(tr(context, 'Menu engineering'))),
        body: Center(
          child: EmptyState(
            key: const Key('menu-empty-state'),
            icon: Icons.restaurant_menu,
            title: tr(context, 'No costs yet'),
            message: tr(context,
                'Costs come down with the menu. Set a cost on the products in Odoo and sync.'),
          ),
        ),
      );
    }

    // The window's own averages are the axes: a busy Saturday and a quiet Tuesday
    // are judged against themselves rather than against a number somebody typed in.
    final avgUnits = rows.fold(0.0, (s, r) => s + r.units) / rows.length;
    final avgMargin =
        rows.fold(0.0, (s, r) => s + r.marginPercent) / rows.length;
    final placed = [
      for (final r in rows)
        _Placed(r, _quadrantOf(r, avgUnits: avgUnits, avgMargin: avgMargin)),
    ];

    return Scaffold(
      appBar: AppBar(
        title: Text(tr(context, 'Menu engineering')),
        actions: [
          reportExportAction(context,
              name: 'report-menu-engineering', title: tr(context, 'Menu engineering'), table: () => _table(placed)),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          for (final q in _Quadrant.values)
            _quadrantCard(context, q, placed.where((p) => p.quadrant == q).toList()),
        ],
      ),
    );
  }

  static _Quadrant _quadrantOf(ProductMargin r,
      {required double avgUnits, required double avgMargin}) {
    final popular = r.units >= avgUnits;
    final rich = r.marginPercent >= avgMargin;
    if (popular && rich) return _Quadrant.stars;
    if (popular) return _Quadrant.plowhorses;
    return rich ? _Quadrant.puzzles : _Quadrant.dogs;
  }

  Widget _quadrantCard(BuildContext context, _Quadrant q, List<_Placed> rows) => Card(
        key: Key('menu-${q.name}'),
        margin: const EdgeInsets.only(bottom: 12),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: q.color.withValues(alpha: 0.35)),
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(q.icon, color: q.color, size: 20),
              const SizedBox(width: 8),
              Text('${tr(context, q.title)}  (${rows.length})',
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            ]),
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(tr(context, q.advice),
                  style: Theme.of(context).textTheme.bodySmall),
            ),
            const Divider(),
            if (rows.isEmpty)
              Text(tr(context, 'Nothing here'),
                  style: Theme.of(context).textTheme.bodySmall)
            else
              for (final p in rows)
                ListTile(
                  key: Key('menu-item-${p.row.productId}'),
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text(p.row.name),
                  subtitle: Text('${p.row.units.toStringAsFixed(
                      p.row.units == p.row.units.roundToDouble() ? 0 : 2)}'
                      ' ${tr(context, 'Units')}'),
                  trailing: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(formatAmount(p.row.margin),
                          style: const TextStyle(fontWeight: FontWeight.bold)),
                      Text('${p.row.marginPercent.toStringAsFixed(1)}%',
                          style: Theme.of(context).textTheme.bodySmall),
                    ],
                  ),
                ),
          ]),
        ),
      );
}

/// One dish and the corner it landed in.
class _Placed {
  const _Placed(this.row, this.quadrant);
  final ProductMargin row;
  final _Quadrant quadrant;
}

enum _Quadrant {
  stars('Stars', 'Popular and profitable. Keep them where the eye lands first.',
      Icons.star, AppColors.success),
  plowhorses(
      'Plowhorses',
      'Popular but thin. Raise the price a little or cut the cost.',
      Icons.agriculture,
      AppColors.info),
  puzzles(
      'Puzzles',
      'Profitable but nobody orders them. Push them or move them up the menu.',
      Icons.help_outline,
      AppColors.warning),
  dogs('Dogs', 'Neither popular nor profitable. Consider dropping them.',
      Icons.thumb_down_alt_outlined, AppColors.error);

  const _Quadrant(this.title, this.advice, this.icon, this.color);

  final String title;
  final String advice;
  final IconData icon;
  final Color color;
}
