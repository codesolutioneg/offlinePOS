import 'package:flutter/material.dart';

import '../i18n/l10n.dart';

/// One button on an [IconPad]: what it answers, its key, look, and whether it
/// applies right now. The label is the English l10n key.
class IconPadItem {
  const IconPadItem(this.id, this.key, this.icon, this.label, this.color,
      [this.enabled = true]);
  final String id;
  final String key;
  final IconData icon;
  final String label;
  final Color color;
  final bool enabled;
}

/// Dinerware's Misc screen: pages of big icon buttons with Prev page / Next page
/// / Cancel along the bottom. A button that does not apply is greyed rather than
/// hidden, so the pad keeps its shape. Pops the id of the button tapped.
class IconPad extends StatefulWidget {
  const IconPad({
    super.key = const Key('misc-pad'),
    required this.items,
    this.title = 'Misc',
  });
  final List<IconPadItem> items;
  final String title;

  @override
  State<IconPad> createState() => _IconPadState();
}

class _IconPadState extends State<IconPad> {
  static const double _tileW = 128;
  static const double _tileH = 100;
  static const double _gap = 10;
  static const int _rows = 3;
  int _page = 0;

  Widget _tile(IconPadItem item) {
    final bg = item.enabled ? item.color : const Color(0xFFBDBDBD);
    final fg = item.enabled ? Colors.white : const Color(0xFF757575);
    return SizedBox(
      width: _tileW,
      height: _tileH,
      child: Material(
        color: bg,
        borderRadius: BorderRadius.circular(10),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: Key(item.key),
          onTap: item.enabled ? () => Navigator.pop(context, item.id) : null,
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(item.icon, color: fg, size: 32),
                const SizedBox(height: 6),
                Text(
                  tr(context, item.label),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: fg,
                    fontSize: 12.5,
                    height: 1.15,
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

  Widget _footerButton(
          Key key, IconData icon, String label, VoidCallback? onTap) =>
      SizedBox(
        width: _tileW,
        height: 52,
        child: OutlinedButton.icon(
          key: key,
          onPressed: onTap,
          icon: Icon(icon),
          label: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
      );

  @override
  Widget build(BuildContext context) {
    return Dialog(
      insetPadding: const EdgeInsets.all(24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ConstrainedBox(
        constraints:
            const BoxConstraints(maxWidth: 5 * _tileW + 4 * _gap + 40),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: LayoutBuilder(builder: (context, box) {
            final fit =
                ((box.maxWidth + _gap) / (_tileW + _gap)).floor().clamp(2, 5);
            final cols = fit.clamp(2, widget.items.length.clamp(2, 5));
            final perPage = cols * _rows;
            final pages = (widget.items.length / perPage).ceil().clamp(1, 99);
            final page = _page.clamp(0, pages - 1);
            final shown = widget.items.skip(page * perPage).take(perPage);
            final width = cols * _tileW + (cols - 1) * _gap;
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: width,
                  child: Row(children: [
                    Expanded(
                      child: Text(tr(context, widget.title),
                          style: Theme.of(context).textTheme.headlineSmall),
                    ),
                    if (pages > 1) Text('${page + 1} / $pages'),
                  ]),
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: width,
                  child: Wrap(
                    spacing: _gap,
                    runSpacing: _gap,
                    children: [for (final i in shown) _tile(i)],
                  ),
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: width,
                  child: Wrap(
                    alignment: WrapAlignment.end,
                    spacing: _gap,
                    runSpacing: _gap,
                    children: [
                      if (pages > 1) ...[
                        _footerButton(
                            const Key('misc-prev'),
                            Icons.keyboard_double_arrow_left,
                            tr(context, 'Prev page'),
                            page > 0
                                ? () => setState(() => _page = page - 1)
                                : null),
                        _footerButton(
                            const Key('misc-next'),
                            Icons.keyboard_double_arrow_right,
                            tr(context, 'Next page'),
                            page < pages - 1
                                ? () => setState(() => _page = page + 1)
                                : null),
                      ],
                      _footerButton(const Key('misc-cancel'), Icons.close,
                          tr(context, 'Cancel'), () => Navigator.pop(context)),
                    ],
                  ),
                ),
              ],
            );
          }),
        ),
      ),
    );
  }
}
