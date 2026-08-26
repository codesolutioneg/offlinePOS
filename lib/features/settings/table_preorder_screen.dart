import 'package:flutter/material.dart';

import '../../core/db/catalogue_store.dart';
import '../../core/db/settings_store.dart';
import '../../core/db/table_store.dart';
import '../../core/i18n/l10n.dart';
import '../../core/theme/app_colors.dart';
import '../../domain/catalogue.dart';
import '../../domain/table_preorder.dart';

/// What a table opens with: the cover charge, the bottle of water, the bread.
///
/// Set for a whole room, because that is how a restaurant thinks about it, and
/// overridden on the odd table that is not like the rest. The list is read once, when
/// guests are seated, and what it produces is ordinary order lines: a waiter takes one
/// off with the void they already have, which is why nothing here is on a selling path.
class TablePreorderScreen extends StatefulWidget {
  const TablePreorderScreen({
    super.key,
    required this.settings,
    required this.tables,
    required this.catalogue,
    this.onChanged,
  });

  final SettingsStore settings;
  final TableStore tables;
  final CatalogueStore catalogue;

  /// Called after every change, so a caller holding a floor can redraw it.
  final VoidCallback? onChanged;

  @override
  State<TablePreorderScreen> createState() => _TablePreorderScreenState();
}

class _TablePreorderScreenState extends State<TablePreorderScreen> {
  String? _section;

  List<String> get _sections {
    final s = widget.tables.sections();
    return s.isEmpty ? const ['Main'] : s;
  }

  String get _active => _section ?? _sections.first;

  void _changed() {
    setState(() {});
    widget.onChanged?.call();
  }

  /// The product name for a line, or a plain marker when the catalogue no longer has
  /// it. Never a bare id: a manager reading "12" has no way to know what it was, and
  /// a line the till will skip has to say so here rather than on a bill.
  String _nameOf(int productId) =>
      widget.catalogue.byId(productId)?.name ??
      tr(context, 'Product no longer in the menu');

  @override
  Widget build(BuildContext context) {
    final tables =
        widget.tables.inSection(_active).where((t) => !t.isDivider).toList();
    return Scaffold(
      appBar: AppBar(title: Text(tr(context, 'What a table opens with'))),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Text(
              tr(context,
                  'These lines are added to the bill when guests are seated. A waiter can still take them off.'),
              style: const TextStyle(color: Colors.black54),
            ),
          ),
          if (_sections.length > 1) _sectionStrip(),
          const Divider(),
          _sectionCard(),
          const Divider(),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Text(tr(context, 'Tables in this section'),
                style: Theme.of(context).textTheme.titleSmall),
          ),
          if (tables.isEmpty)
            ListTile(
              subtitle: Text(tr(context, 'No tables in this section yet.')),
            )
          else
            for (final t in tables) _tableTile(t),
        ],
      ),
    );
  }

  Widget _sectionStrip() => SizedBox(
        height: 56,
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          children: [
            for (final s in _sections) ...[
              ChoiceChip(
                key: Key('preorder-section-${s.toLowerCase()}'),
                label: Text(s),
                selected: _active == s,
                onSelected: (_) => setState(() => _section = s),
              ),
              const SizedBox(width: 6),
            ],
          ],
        ),
      );

  /// The room's own list, which every table in it follows unless it says otherwise.
  Widget _sectionCard() {
    final lines = widget.settings.sectionPreorders(_active);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(
          leading: const Icon(Icons.meeting_room_outlined),
          title: Text('${tr(context, 'Whole section')}: $_active',
              style: const TextStyle(fontWeight: FontWeight.bold)),
          subtitle: Text(lines.isEmpty
              ? tr(context, 'Opens with nothing')
              : '${lines.length} ${tr(context, 'line(s)')}'),
          trailing: IconButton(
            key: const Key('preorder-section-add'),
            icon: const Icon(Icons.add_circle_outline),
            tooltip: tr(context, 'Add item'),
            onPressed: () => _addLine(
              current: lines,
              save: (next) => widget.settings.setSectionPreorders(_active, next),
            ),
          ),
        ),
        for (var i = 0; i < lines.length; i++)
          _lineTile(
            key: Key('preorder-section-line-$i'),
            line: lines[i],
            onRemove: () {
              final next = [...lines]..removeAt(i);
              widget.settings.setSectionPreorders(_active, next);
              _changed();
            },
          ),
      ],
    );
  }

  Widget _tableTile(PosTable t) {
    final own = widget.settings.tablePreorders(t.id);
    final follows = own == null;
    final lines = own ?? const <TablePreorder>[];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(
          key: Key('preorder-table-${t.id}'),
          leading: const Icon(Icons.table_restaurant_outlined),
          title: Text(t.name),
          subtitle: Text(follows
              ? tr(context, 'Same as the section')
              : lines.isEmpty
                  ? tr(context, 'Opens with nothing')
                  : '${lines.length} ${tr(context, 'line(s)')}'),
          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
            if (!follows)
              IconButton(
                key: Key('preorder-follow-${t.id}'),
                icon: const Icon(Icons.settings_backup_restore),
                tooltip: tr(context, 'Follow the section'),
                onPressed: () {
                  widget.settings.setTablePreorders(t.id, null);
                  _changed();
                },
              ),
            IconButton(
              key: Key('preorder-add-${t.id}'),
              icon: const Icon(Icons.add_circle_outline),
              tooltip: tr(context, 'Add item'),
              // Adding to a table that was following its room takes it off the room's
              // list rather than adding to it: the override is the whole list, or a
              // shop could never keep the cover charge off one table.
              onPressed: () => _addLine(
                current: lines,
                save: (next) => widget.settings.setTablePreorders(t.id, next),
              ),
            ),
          ]),
        ),
        if (!follows && lines.isEmpty)
          Padding(
            padding: const EdgeInsets.only(left: 72, bottom: 8),
            child: Text(
              tr(context, 'Nothing, on purpose. Use the arrow to follow the section again.'),
              style: const TextStyle(fontSize: 12, color: Colors.black54),
            ),
          ),
        for (var i = 0; i < lines.length; i++)
          _lineTile(
            key: Key('preorder-table-${t.id}-line-$i'),
            line: lines[i],
            onRemove: () {
              final next = [...lines]..removeAt(i);
              widget.settings.setTablePreorders(t.id, next);
              _changed();
            },
          ),
      ],
    );
  }

  Widget _lineTile({
    required Key key,
    required TablePreorder line,
    required VoidCallback onRemove,
  }) =>
      Padding(
        padding: const EdgeInsets.only(left: 56),
        child: ListTile(
          key: key,
          dense: true,
          title: Text(_nameOf(line.productId)),
          subtitle: Text(line.perGuest
              ? '${_qtyLabel(line.quantity)} × ${tr(context, 'per guest')}'
              : _qtyLabel(line.quantity)),
          trailing: IconButton(
            icon: const Icon(Icons.remove_circle_outline, color: AppColors.error),
            tooltip: tr(context, 'Remove'),
            onPressed: onRemove,
          ),
        ),
      );

  String _qtyLabel(double qty) =>
      qty == qty.roundToDouble() ? '${qty.toInt()}' : qty.toStringAsFixed(2);

  /// Pick a product, a quantity and whether it is per guest, and append it.
  Future<void> _addLine({
    required List<TablePreorder> current,
    required void Function(List<TablePreorder>) save,
  }) async {
    final product = await _pickProduct();
    if (product == null || !mounted) return;
    final line = await _lineDialog(product);
    if (line == null || !mounted) return;
    save([...current, line]);
    _changed();
  }

  Future<Product?> _pickProduct() {
    final search = TextEditingController();
    return showModalBottomSheet<Product>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) {
          final found = widget.catalogue
              .products(search: search.text.trim(), limit: 60);
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                TextField(
                  key: const Key('preorder-product-search'),
                  controller: search,
                  autofocus: true,
                  onChanged: (_) => setSheetState(() {}),
                  decoration: InputDecoration(
                    labelText: tr(ctx, 'Search the menu'),
                    prefixIcon: const Icon(Icons.search),
                    border: const OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 8),
                if (found.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(tr(ctx, 'No products')),
                  )
                else
                  Flexible(
                    child: ListView(
                      shrinkWrap: true,
                      children: [
                        for (final p in found)
                          ListTile(
                            key: Key('preorder-product-${p.id}'),
                            title: Text(p.name),
                            onTap: () => Navigator.pop(ctx, p),
                          ),
                      ],
                    ),
                  ),
              ]),
            ),
          );
        },
      ),
    );
  }

  Future<TablePreorder?> _lineDialog(Product product) {
    var qty = 1.0;
    var perGuest = false;
    return showDialog<TablePreorder>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          key: const Key('preorder-line-dialog'),
          title: Text(product.name),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            Row(children: [
              Text(tr(ctx, 'Quantity')),
              const Spacer(),
              IconButton(
                key: const Key('preorder-qty-down'),
                icon: const Icon(Icons.remove_circle_outline),
                onPressed: () =>
                    setDialogState(() => qty = qty <= 1 ? 1 : qty - 1),
              ),
              Text(_qtyLabel(qty)),
              IconButton(
                key: const Key('preorder-qty-up'),
                icon: const Icon(Icons.add_circle_outline),
                onPressed: () => setDialogState(() => qty = qty + 1),
              ),
            ]),
            SwitchListTile(
              key: const Key('preorder-per-guest'),
              contentPadding: EdgeInsets.zero,
              title: Text(tr(ctx, 'Per guest')),
              subtitle: Text(tr(ctx, 'Multiply by the number of covers seated')),
              value: perGuest,
              onChanged: (v) => setDialogState(() => perGuest = v),
            ),
          ]),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text(tr(ctx, 'Cancel'))),
            FilledButton(
              key: const Key('preorder-line-save'),
              onPressed: () => Navigator.pop(
                ctx,
                TablePreorder(
                    productId: product.id, quantity: qty, perGuest: perGuest),
              ),
              child: Text(tr(ctx, 'Add')),
            ),
          ],
        ),
      ),
    );
  }
}
