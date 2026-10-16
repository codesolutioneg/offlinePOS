import 'package:flutter/material.dart';

/// One tile on the floor's bottom action bar (Dishflow / Dinerware style).
class FloorAction {
  const FloorAction({
    required this.id,
    required this.label,
    required this.icon,
    required this.color,
    this.onTap,
    this.newWork = false,
  });

  /// Stable id, used for the tile key `floor-action-$id`.
  final String id;
  final String label;
  final IconData icon;
  final Color color;

  /// Null draws the tile greyed out and inert.
  final VoidCallback? onTap;

  /// Starts an order, so the floor refuses it with no shift open or a closed day.
  final bool newWork;
}

/// A dark strip of big coloured tiles along the bottom of the floor. One row when
/// the window is wide enough for every tile to stay readable, two otherwise.
class FloorActionBar extends StatelessWidget {
  const FloorActionBar({
    super.key,
    required this.actions,
    this.guard,
    this.compact = false,
    this.keyPrefix = 'floor-action',
    this.barKey = const Key('floor-action-bar'),
  });

  /// Every button the bar can carry, in bar order: id, English l10n label, icon,
  /// colour. The shell builds its tiles from these and settings lists them to
  /// switch off.
  static const List<({String id, String label, IconData icon, Color color})>
      catalog = [
    (id: 'begin', label: 'Begin', icon: Icons.lock_open, color: Color(0xFFE67E22)),
    (id: 'end', label: 'End', icon: Icons.lock, color: Color(0xFFD35400)),
    (id: 'table', label: 'Table', icon: Icons.table_bar, color: Color(0xFF0EA5E9)),
    (id: 'delivery', label: 'Delivery', icon: Icons.two_wheeler,
        color: Color(0xFFE91E63)),
    (id: 'quick', label: 'Delivery / Quick Srv', icon: Icons.delivery_dining,
        color: Color(0xFF8E44AD)),
    (id: 'info', label: 'Info', icon: Icons.info_outline, color: Color(0xFF2980B9)),
    (id: 'session', label: 'Session Open/Close', icon: Icons.point_of_sale,
        color: Color(0xFF16A085)),
    (id: 'misc', label: 'Misc', icon: Icons.more_horiz, color: Color(0xFF607D8B)),
    (id: 'empl', label: 'Empl', icon: Icons.badge_outlined, color: Color(0xFF27AE60)),
    (id: 'tabs', label: 'Tabs', icon: Icons.table_restaurant, color: Color(0xFFF39C12)),
    (id: 'employee-transfer', label: 'Employee Transfer', icon: Icons.swap_horiz,
        color: Color(0xFF34495E)),
    (id: 'transfer-items', label: 'Transfer Items', icon: Icons.move_down,
        color: Color(0xFF3498DB)),
    (id: 'flash', label: 'Flash Report', icon: Icons.flash_on, color: Color(0xFFC0392B)),
    (id: 'quit', label: 'Quit', icon: Icons.power_settings_new, color: Color(0xFF7B1F1F)),
  ];

  final List<FloorAction> actions;

  /// Returns true when the action may run. Asked only for [FloorAction.newWork].
  final bool Function(FloorAction action)? guard;

  /// Always one short row, for a screen that cannot spare the height (the order
  /// screen, whose bill panel sits right above).
  final bool compact;

  /// Tiles are keyed $keyPrefix-.
  final String keyPrefix;
  final Key barKey;

  static const double _minTileWidth = 88;
  static const double _tileHeight = 68;
  static const double _gap = 4;

  @override
  Widget build(BuildContext context) {
    if (actions.isEmpty) return const SizedBox.shrink();
    return SafeArea(
      top: false,
      child: Container(
        key: barKey,
        color: const Color(0xFF1F1F1F),
        padding: EdgeInsets.all(compact ? 3 : _gap),
        child: LayoutBuilder(builder: (context, box) {
          final oneRow = compact ||
              box.maxWidth / actions.length >= _minTileWidth + _gap;
          final perRow =
              oneRow ? actions.length : (actions.length / 2).ceil();
          final rows = <List<FloorAction>>[
            for (var i = 0; i < actions.length; i += perRow)
              actions.sublist(i, (i + perRow).clamp(0, actions.length)),
          ];
          return Column(mainAxisSize: MainAxisSize.min, children: [
            for (var r = 0; r < rows.length; r++) ...[
              if (r > 0) const SizedBox(height: _gap),
              Row(children: [
                for (var i = 0; i < perRow; i++) ...[
                  if (i > 0) const SizedBox(width: _gap),
                  Expanded(
                    child: i < rows[r].length
                        ? _tile(rows[r][i])
                        : SizedBox(height: compact ? 44 : _tileHeight),
                  ),
                ],
              ]),
            ],
          ]);
        }),
      ),
    );
  }

  Widget _tile(FloorAction a) {
    final enabled = a.onTap != null;
    final bg = enabled ? a.color : const Color(0xFF9E9E9E);
    final fg = enabled ? Colors.white : const Color(0xFF616161);
    return SizedBox(
      height: compact ? 44 : _tileHeight,
      child: Material(
        color: bg,
        borderRadius: BorderRadius.circular(6),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: Key('$keyPrefix-${a.id}'),
          onTap: !enabled
              ? null
              : () {
                  if (a.newWork && guard != null && !guard!(a)) return;
                  a.onTap!();
                },
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 4, vertical: compact ? 3 : 6),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(a.icon, color: fg, size: compact ? 18 : 26),
                SizedBox(height: compact ? 1 : 4),
                Text(
                  a.label,
                  maxLines: compact ? 1 : 2,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: fg,
                    fontSize: compact ? 11 : 12,
                    height: 1.1,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
