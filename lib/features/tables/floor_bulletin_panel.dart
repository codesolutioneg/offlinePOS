import 'package:flutter/material.dart';

import '../../core/i18n/l10n.dart';
import '../../core/theme/dishflow_brand.dart';
import '../../domain/floor_bulletin.dart';

/// One line the Bulletin board can carry. The label is the English l10n key.
typedef BulletinRow = ({String id, String label, IconData icon, Color color});

/// The Bulletin board down the right of the floor: how many tables are open,
/// free, fired, billed, and what is waiting outside the room.
class FloorBulletinPanel extends StatelessWidget {
  const FloorBulletinPanel({
    super.key,
    required this.bulletin,
    required this.formatAmount,
    this.hidden = const {},
  });

  final FloorBulletin bulletin;
  final String Function(double) formatAmount;

  /// Row ids the shop switched off in settings.
  final Set<String> hidden;

  static const double width = 260;

  /// Every row, in board order. Settings lists the same ones to switch off.
  static const List<BulletinRow> rows = [
    (
      id: 'open',
      label: 'Open tables',
      icon: Icons.table_restaurant,
      color: Color(0xFFE67E22),
    ),
    (
      id: 'free',
      label: 'Free tables',
      icon: Icons.event_seat,
      color: Color(0xFF27AE60),
    ),
    (
      id: 'sent',
      label: 'Sent to kitchen',
      icon: Icons.soup_kitchen,
      color: Color(0xFF2980B9),
    ),
    (
      id: 'not-sent',
      label: 'Not sent yet',
      icon: Icons.hourglass_empty,
      color: Color(0xFF7F8C8D),
    ),
    (
      id: 'billed',
      label: 'Bill printed, not paid',
      icon: Icons.receipt_long,
      color: Color(0xFF8E44AD),
    ),
    (
      id: 'delivery',
      label: 'Delivery orders',
      icon: Icons.delivery_dining,
      color: Color(0xFF16A085),
    ),
    (
      id: 'takeaway',
      label: 'Takeaway / to go',
      icon: Icons.takeout_dining,
      color: Color(0xFFF39C12),
    ),
    (
      id: 'open-amount',
      label: 'Open tables total',
      icon: Icons.account_balance_wallet_outlined,
      color: Color(0xFFD35400),
    ),
    (
      id: 'paid',
      label: 'Closed checks today',
      icon: Icons.check_circle_outline,
      color: Color(0xFF2ECC71),
    ),
    (
      id: 'sales',
      label: 'Sales today',
      icon: Icons.payments_outlined,
      color: Color(0xFFC0392B),
    ),
  ];

  String _value(String id) {
    final b = bulletin;
    return switch (id) {
      'open' => '${b.openTables}',
      'free' => '${b.freeTables} / ${b.tables}',
      'sent' => '${b.sentToKitchen}',
      'not-sent' => '${b.notSent}',
      'billed' => '${b.billPrinted}',
      'delivery' => '${b.delivery}',
      'takeaway' => '${b.takeaway}',
      'open-amount' => formatAmount(b.openAmount),
      'paid' => '${b.paidToday}',
      'sales' => formatAmount(b.salesToday),
      _ => '',
    };
  }

  @override
  Widget build(BuildContext context) {
    final shown = rows.where((r) => !hidden.contains(r.id)).toList();

    // The board takes only the height its rows need, with the Dishflow mark right
    // under it; a long board stops short of the mark and scrolls instead.
    return SizedBox(
      width: width + 16,
      child: LayoutBuilder(
        builder: (context, box) {
          const logoArea = 96.0;
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: (box.maxHeight - logoArea).clamp(
                    120,
                    double.infinity,
                  ),
                ),
                child: _board(context, shown),
              ),
              const SizedBox(
                key: Key('floor-bulletin-logo'),
                height: logoArea,
                child: Center(
                  child: DishflowBrandMark(height: 44, showSubtitle: true),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _board(BuildContext context, List<BulletinRow> shown) {
    return Container(
      key: const Key('floor-bulletin'),
      width: width,
      margin: const EdgeInsets.fromLTRB(8, 8, 8, 0),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF1565C0), Color(0xFF0D47A1)],
        ),
        borderRadius: BorderRadius.circular(16),
        boxShadow: const [
          BoxShadow(color: Colors.black26, blurRadius: 6, offset: Offset(0, 2)),
        ],
      ),
      padding: const EdgeInsets.fromLTRB(10, 10, 10, 10),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(vertical: 6),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              tr(context, 'Bulletin'),
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Color(0xFF1565C0),
                fontSize: 20,
                fontWeight: FontWeight.w900,
                letterSpacing: 4,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Flexible(
            child: Container(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(10),
              ),
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Column(
                  children: [
                    for (final (i, r) in shown.indexed) ...[
                      if (i > 0)
                        const Divider(height: 1, indent: 10, endIndent: 10),
                      Padding(
                        key: Key('bulletin-${r.id}'),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 7,
                        ),
                        child: Row(
                          children: [
                            Container(
                              width: 30,
                              height: 30,
                              decoration: BoxDecoration(
                                color: r.color,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Icon(
                                r.icon,
                                color: Colors.white,
                                size: 18,
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                tr(context, r.label),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            const SizedBox(width: 6),
                            Text(
                              _value(r.id),
                              key: Key('bulletin-${r.id}-value'),
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w800,
                                color: r.color,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
