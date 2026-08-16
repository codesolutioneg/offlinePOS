import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/db/catalogue_store.dart';
import '../../core/i18n/l10n.dart';
import '../../core/sync/odoo_puller.dart';
import '../../core/theme/app_colors.dart';
import '../../core/widgets/feedback.dart';
import '../../core/widgets/swatch_picker.dart';
import '../../domain/catalogue.dart';

/// The menu, as the shop keeps it.
///
/// The catalogue used to be a copy of Odoo's, so a shop whose items are not in Odoo
/// (or not in Odoo yet) had nothing to sell. This is the other half: a manager types
/// the menu here, on the device, and it works with the line down like everything
/// else on this till. Linking a row to an Odoo record is offered but never required,
/// because a shop that cannot get an id out of its accountant still has to open.
class MenuEditorScreen extends StatefulWidget {
  const MenuEditorScreen({
    super.key,
    required this.catalogue,
    required this.onChanged,
    this.categoryColors = const {},
    this.onSetCategoryColor,
    this.searchOdooProducts,
    this.searchOdooCategories,
    this.localProductBookingId,
  });

  final CatalogueStore catalogue;

  /// Fired after every write, so the grid behind this screen picks the change up
  /// without the manager restarting the till.
  final VoidCallback onChanged;

  /// Category colours live in settings, keyed by category id, and are shared with
  /// the Appearance screen. Passed through rather than re-read so there is one
  /// owner of them.
  final Map<int, int> categoryColors;
  final void Function(int categoryId, int? argb)? onSetCategoryColor;

  /// Ask the server what a row could be linked to. Null when the till has no server
  /// configured; an offline till gets the exception and is told to type the id.
  final Future<List<OdooRef>> Function(String term)? searchOdooProducts;
  final Future<List<OdooRef>> Function(String term)? searchOdooCategories;

  /// The Odoo product an unlinked item books against, if the shop named one. Drives
  /// what the editor warns about, so a manager finds out here rather than from a
  /// parked sale a week later.
  final int? localProductBookingId;

  @override
  State<MenuEditorScreen> createState() => _MenuEditorScreenState();
}

class _MenuEditorScreenState extends State<MenuEditorScreen> {
  String _search = '';
  bool _showArchived = false;

  void _reload() {
    setState(() {});
    widget.onChanged();
  }

  @override
  Widget build(BuildContext context) => DefaultTabController(
        length: 2,
        child: Scaffold(
          appBar: AppBar(
            title: Text(tr(context, 'Menu')),
            bottom: TabBar(tabs: [
              Tab(key: const Key('tab-items'), text: tr(context, 'Items')),
              Tab(key: const Key('tab-categories'), text: tr(context, 'Categories')),
            ]),
          ),
          body: TabBarView(children: [_itemsTab(), _categoriesTab()]),
        ),
      );

  // ── items ────────────────────────────────────────────────────────

  Widget _itemsTab() {
    final products = widget.catalogue
        .products(search: _search, limit: 500, includeArchived: _showArchived);
    final categories = {
      for (final c in widget.catalogue.categories(includeArchived: true)) c.id: c
    };
    // One read for the whole list, not one per row: the same grouped query the sell
    // grid uses to draw its marks.
    final marks = widget.catalogue.modifierMarks();
    return Column(children: [
      Padding(
        padding: const EdgeInsets.all(8),
        child: TextField(
          key: const Key('menu-search'),
          decoration: InputDecoration(
            prefixIcon: const Icon(Icons.search),
            hintText: tr(context, 'Search the menu'),
            border: const OutlineInputBorder(),
            isDense: true,
          ),
          onChanged: (v) => setState(() => _search = v),
        ),
      ),
      SwitchListTile(
        key: const Key('menu-show-archived'),
        dense: true,
        value: _showArchived,
        title: Text(tr(context, 'Show removed items')),
        onChanged: (v) => setState(() => _showArchived = v),
      ),
      Expanded(
        child: products.isEmpty
            ? EmptyState(
                icon: Icons.restaurant_menu,
                title: tr(context, 'No items yet'),
                message: tr(context, 'Add the first one, or refresh the menu from Odoo'),
              )
            : ListView(children: [
                for (final p in products)
                  _itemTile(p, categories[p.categoryId], marks[p.id]),
              ]),
      ),
      Padding(
        padding: const EdgeInsets.all(12),
        child: FilledButton.icon(
          key: const Key('menu-add-item'),
          icon: const Icon(Icons.add),
          label: Text(tr(context, 'Add item')),
          onPressed: () => _editProduct(null),
        ),
      ),
    ]);
  }

  Widget _itemTile(Product p, Category? category, ModifierMark? marks) {
    return ListTile(
      key: Key('menu-item-${p.id}'),
      leading: CircleAvatar(
        backgroundColor: p.color != null
            ? Color(p.color!)
            : (widget.categoryColors[p.categoryId] != null
                ? Color(widget.categoryColors[p.categoryId]!)
                : AppColors.categoryColor(p.categoryId ?? 0)),
        child: Text(p.name.isEmpty ? '?' : p.name.characters.first.toUpperCase(),
            style: const TextStyle(color: Colors.white)),
      ),
      title: Row(children: [
        Flexible(child: Text(p.name)),
        if (marks != null) ...[
          const SizedBox(width: 6),
          Icon(Icons.tune,
              key: Key('menu-item-mods-${p.id}'), size: 16, color: AppColors.warning),
        ],
        if (!p.active) ...[
          const SizedBox(width: 6),
          Text(tr(context, 'Removed'),
              style: const TextStyle(color: Colors.black45, fontSize: 12)),
        ],
      ]),
      subtitle: Text([
        p.price.toStringAsFixed(2),
        if (category != null) category.name,
        p.isLinked
            ? '${tr(context, 'Odoo')} #${p.odooId}'
            : tr(context, 'Not linked to Odoo'),
      ].join('  ·  ')),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        IconButton(
          key: Key('edit-item-${p.id}'),
          icon: const Icon(Icons.edit_outlined),
          tooltip: tr(context, 'Edit'),
          onPressed: () => _editProduct(p),
        ),
        if (p.active)
          IconButton(
            key: Key('archive-item-${p.id}'),
            icon: const Icon(Icons.delete_outline),
            tooltip: tr(context, 'Remove'),
            onPressed: () async {
              if (!await _confirmRemove(p.name)) return;
              widget.catalogue.archiveProduct(p.id);
              _reload();
            },
          )
        else
          IconButton(
            key: Key('restore-item-${p.id}'),
            icon: const Icon(Icons.undo),
            tooltip: tr(context, 'Restore'),
            onPressed: () {
              widget.catalogue.restoreProduct(p.id);
              _reload();
            },
          ),
      ]),
    );
  }

  Future<void> _editProduct(Product? product) async {
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => ProductEditorScreen(
        catalogue: widget.catalogue,
        product: product,
        searchOdooProducts: widget.searchOdooProducts,
        localProductBookingId: widget.localProductBookingId,
      ),
    ));
    _reload();
  }

  /// Removing is reversible, and the wording says so: a manager who expects a hard
  /// delete and gets an archive would otherwise go looking for the row in Odoo.
  Future<bool> _confirmRemove(String name) async =>
      await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(tr(ctx, 'Remove from the menu?')),
          content: Text('$name\n\n'
              '${tr(ctx, 'It leaves the grid and can be brought back from this screen. Past sales keep it.')}'),
          actions: [
            TextButton(
              key: const Key('remove-cancel'),
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(tr(ctx, 'Cancel')),
            ),
            FilledButton(
              key: const Key('remove-ok'),
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(tr(ctx, 'Remove')),
            ),
          ],
        ),
      ) ??
      false;

  // ── categories ───────────────────────────────────────────────────

  Widget _categoriesTab() {
    final categories = widget.catalogue.categories(includeArchived: _showArchived);
    return Column(children: [
      Expanded(
        child: categories.isEmpty
            ? EmptyState(
                icon: Icons.category_outlined,
                title: tr(context, 'No categories yet'),
                message: tr(context, 'A category groups items on the grid'),
              )
            : ListView(children: [
                for (final c in categories)
                  ListTile(
                    key: Key('menu-category-${c.id}'),
                    leading: GestureDetector(
                      key: Key('category-color-${c.id}'),
                      onTap: widget.onSetCategoryColor == null
                          ? null
                          : () => _pickCategoryColor(c),
                      child: CircleAvatar(
                        backgroundColor: widget.categoryColors[c.id] != null
                            ? Color(widget.categoryColors[c.id]!)
                            : kUnsetSwatch,
                        radius: 14,
                      ),
                    ),
                    title: Text(c.name),
                    subtitle: Text(c.odooId != null
                        ? '${tr(context, 'Odoo')} #${c.odooId}'
                        : tr(context, 'Not linked to Odoo')),
                    trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                      IconButton(
                        key: Key('edit-category-${c.id}'),
                        icon: const Icon(Icons.edit_outlined),
                        tooltip: tr(context, 'Edit'),
                        onPressed: () => _categoryDialog(category: c),
                      ),
                      IconButton(
                        key: Key('archive-category-${c.id}'),
                        icon: const Icon(Icons.delete_outline),
                        tooltip: tr(context, 'Remove'),
                        onPressed: () async {
                          if (!await _confirmRemove(c.name)) return;
                          widget.catalogue.archiveCategory(c.id);
                          _reload();
                        },
                      ),
                    ]),
                  ),
              ]),
      ),
      Padding(
        padding: const EdgeInsets.all(12),
        child: FilledButton.icon(
          key: const Key('menu-add-category'),
          icon: const Icon(Icons.add),
          label: Text(tr(context, 'Add category')),
          onPressed: () => _categoryDialog(),
        ),
      ),
    ]);
  }

  Future<void> _pickCategoryColor(Category c) async {
    final result = await pickSwatch(
        context, '${tr(context, 'Colour for')} ${c.name}', widget.categoryColors[c.id]);
    if (result == null) return;
    widget.onSetCategoryColor
        ?.call(c.id, result is Color ? result.toARGB32() : null);
    _reload();
  }

  Future<void> _categoryDialog({Category? category}) async {
    final name = TextEditingController(text: category?.name ?? '');
    final odoo = TextEditingController(text: category?.odooId?.toString() ?? '');
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr(ctx, category == null ? 'Add category' : 'Edit category')),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
            key: const Key('cat-name'),
            controller: name,
            autofocus: true,
            decoration: InputDecoration(labelText: tr(ctx, 'Name')),
          ),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
              child: TextField(
                key: const Key('cat-odoo-id'),
                controller: odoo,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: InputDecoration(
                  labelText: tr(ctx, 'Odoo category id'),
                  helperText: tr(ctx, 'Optional'),
                ),
              ),
            ),
            if (widget.searchOdooCategories != null)
              IconButton(
                key: const Key('cat-find-odoo'),
                icon: const Icon(Icons.travel_explore),
                tooltip: tr(ctx, 'Find in Odoo'),
                onPressed: () async {
                  final picked = await showOdooPicker(
                      ctx, widget.searchOdooCategories!, name.text);
                  if (picked != null) odoo.text = '${picked.id}';
                },
              ),
          ]),
        ]),
        actions: [
          TextButton(
            key: const Key('cat-cancel'),
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(tr(ctx, 'Cancel')),
          ),
          FilledButton(
            key: const Key('cat-save'),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr(ctx, 'Save')),
          ),
        ],
      ),
    );
    if (saved != true || name.text.trim().isEmpty) return;
    final odooId = int.tryParse(odoo.text.trim());
    if (category == null) {
      widget.catalogue.addCategory(name: name.text.trim(), odooId: odooId);
    } else {
      widget.catalogue
          .saveCategory(category.copyWith(name: name.text.trim(), odooId: odooId));
    }
    _reload();
  }

}

/// One item, everything about it, and its modifiers.
///
/// A full page rather than a dialog: there is a form and a nested list on it, and a
/// dialog holding a list that can grow is how a manager ends up unable to reach the
/// Save button.
class ProductEditorScreen extends StatefulWidget {
  const ProductEditorScreen({
    super.key,
    required this.catalogue,
    this.product,
    this.searchOdooProducts,
    this.localProductBookingId,
  });

  final CatalogueStore catalogue;

  /// The item being edited, or null to create one.
  final Product? product;
  final Future<List<OdooRef>> Function(String term)? searchOdooProducts;
  final int? localProductBookingId;

  @override
  State<ProductEditorScreen> createState() => _ProductEditorScreenState();
}

class _ProductEditorScreenState extends State<ProductEditorScreen> {
  late final TextEditingController _name =
      TextEditingController(text: widget.product?.name ?? '');
  late final TextEditingController _price = TextEditingController(
      text: widget.product == null ? '' : widget.product!.price.toStringAsFixed(2));
  late final TextEditingController _odoo =
      TextEditingController(text: widget.product?.odooId?.toString() ?? '');
  late int? _categoryId = widget.product?.categoryId;
  late int? _color = widget.product?.color;
  late bool _available = widget.product?.active ?? true;

  /// The saved row, once there is one. An item has to exist before a modifier group
  /// can hang off it, so the first save on a new item creates it and the editor
  /// carries on against the created row.
  late Product? _saved = widget.product;

  bool _nameMissing = false;

  @override
  void dispose() {
    _name.dispose();
    _price.dispose();
    _odoo.dispose();
    super.dispose();
  }

  int? get _odooId => int.tryParse(_odoo.text.trim());

  Product? _persist() {
    if (_name.text.trim().isEmpty) {
      setState(() => _nameMissing = true);
      return null;
    }
    final price = double.tryParse(_price.text.trim()) ?? 0;
    final existing = _saved;
    final row = existing == null
        ? widget.catalogue.addProduct(
            name: _name.text.trim(),
            price: price,
            categoryId: _categoryId,
            odooId: _odooId,
            color: _color,
            active: _available,
          )
        : (() {
            widget.catalogue.saveProduct(existing.copyWith(
              name: _name.text.trim(),
              price: price,
              categoryId: _categoryId,
              odooId: _odooId,
              color: _color,
              active: _available,
            ));
            return widget.catalogue.byId(existing.id)!;
          })();
    setState(() {
      _saved = row;
      _nameMissing = false;
    });
    return row;
  }

  @override
  Widget build(BuildContext context) {
    final categories = widget.catalogue.categories(includeArchived: true);
    return Scaffold(
      appBar: AppBar(
        title: Text(tr(context,
            widget.product == null ? 'New item' : 'Edit item')),
        actions: [
          TextButton(
            key: const Key('item-save'),
            onPressed: () {
              if (_persist() == null) return;
              Navigator.of(context).pop();
            },
            child: Text(tr(context, 'Save')),
          ),
        ],
      ),
      body: ListView(padding: const EdgeInsets.all(12), children: [
        TextField(
          key: const Key('item-name'),
          controller: _name,
          decoration: InputDecoration(
            labelText: tr(context, 'Name'),
            border: const OutlineInputBorder(),
            errorText: _nameMissing ? tr(context, 'A name is needed') : null,
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          key: const Key('item-price'),
          controller: _price,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          inputFormatters: [
            FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d{0,2}')),
          ],
          decoration: InputDecoration(
            labelText: tr(context, 'Price'),
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<int?>(
          key: const Key('item-category'),
          initialValue: _categoryId,
          decoration: InputDecoration(
            labelText: tr(context, 'Category'),
            border: const OutlineInputBorder(),
          ),
          items: [
            DropdownMenuItem<int?>(
                value: null, child: Text(tr(context, 'No category'))),
            for (final c in categories)
              DropdownMenuItem<int?>(value: c.id, child: Text(c.name)),
          ],
          onChanged: (v) => setState(() => _categoryId = v),
        ),
        const SizedBox(height: 12),
        ListTile(
          key: const Key('item-color'),
          leading: CircleAvatar(
            backgroundColor: _color != null ? Color(_color!) : kUnsetSwatch,
            radius: 14,
          ),
          title: Text(tr(context, 'Tile colour')),
          subtitle: Text(tr(context, 'Overrides the category colour on the grid')),
          onTap: () async {
            final picked =
                await pickSwatch(context, tr(context, 'Tile colour'), _color);
            if (picked == null) return;
            setState(() => _color = picked is Color ? picked.toARGB32() : null);
          },
        ),
        SwitchListTile(
          key: const Key('item-available'),
          value: _available,
          title: Text(tr(context, 'On the menu')),
          onChanged: (v) => setState(() => _available = v),
        ),
        const Divider(height: 24),
        _odooSection(),
        const Divider(height: 24),
        _modifierSection(),
      ]),
    );
  }

  Widget _odooSection() => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(tr(context, 'Books in Odoo as'),
              style: const TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
              child: TextField(
                key: const Key('item-odoo-id'),
                controller: _odoo,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: InputDecoration(
                  labelText: tr(context, 'Odoo product id'),
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
                onChanged: (_) => setState(() {}),
              ),
            ),
            if (widget.searchOdooProducts != null)
              IconButton(
                key: const Key('item-find-odoo'),
                icon: const Icon(Icons.travel_explore),
                tooltip: tr(context, 'Find in Odoo'),
                onPressed: () async {
                  final picked = await showOdooPicker(
                      context, widget.searchOdooProducts!, _name.text);
                  if (picked == null) return;
                  setState(() => _odoo.text = '${picked.id}');
                },
              ),
          ]),
          if (_odooId == null) ...[
            const SizedBox(height: 8),
            Container(
              key: const Key('item-unlinked-warning'),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppColors.warning.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                widget.localProductBookingId != null
                    ? tr(context,
                        'It sells and prints normally. Until it is linked, Odoo books it against the stand-in product set on the server screen.')
                    : tr(context,
                        'It sells and prints normally, but Odoo has nothing to book it against, so the sale will be held back for someone to fix. Link it, or name a stand-in product on the server screen.'),
                style: const TextStyle(fontSize: 13),
              ),
            ),
          ],
        ],
      );

  // ── modifiers ────────────────────────────────────────────────────

  Widget _modifierSection() {
    final row = _saved;
    if (row == null) {
      // A group has to hang off a row that exists. Saving in place rather than
      // telling the manager to save, come back and open the item again: the shop
      // typed the dish and its sizes in one thought, and the editor should not make
      // that two trips.
      return OutlinedButton.icon(
        key: const Key('mods-need-save'),
        icon: const Icon(Icons.add),
        label: Text(tr(context, 'Save the item, then add its choices')),
        onPressed: _persist,
      );
    }
    final groups = widget.catalogue.modifierGroupsFor(row.id);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(tr(context, 'Choices the cashier is asked'),
          style: const TextStyle(fontWeight: FontWeight.bold)),
      const SizedBox(height: 4),
      Text(
          tr(context,
              'A group with choices in it marks the item on the grid, so nobody has to guess.'),
          style: const TextStyle(color: Colors.black54, fontSize: 13)),
      const SizedBox(height: 8),
      for (final g in groups) _groupCard(row, g),
      const SizedBox(height: 8),
      OutlinedButton.icon(
        key: const Key('add-mod-group'),
        icon: const Icon(Icons.add),
        label: Text(tr(context, 'Add a choice group')),
        onPressed: () => _groupDialog(row),
      ),
    ]);
  }

  Widget _groupCard(Product row, ModifierGroup g) => Card(
        key: Key('mod-group-${g.id}'),
        child: Column(children: [
          ListTile(
            title: Text(g.name),
            subtitle: Text([
              if (g.required) tr(context, 'Required') else tr(context, 'Optional'),
              '${tr(context, 'Min')} ${g.minSelection}',
              '${tr(context, 'Max')} ${g.maxSelection == 0 ? tr(context, 'any') : g.maxSelection}',
            ].join('  ·  ')),
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              IconButton(
                key: Key('edit-mod-group-${g.id}'),
                icon: const Icon(Icons.edit_outlined),
                tooltip: tr(context, 'Edit'),
                onPressed: () => _groupDialog(row, group: g),
              ),
              // Only a group this till owns can be removed for good. Deleting one
              // the server sends would put it back on the next refresh, and a
              // button that undoes itself is worse than no button; editing it
              // claims it here first, after which this appears.
              if (g.source == CatalogueSource.local)
                IconButton(
                  key: Key('remove-mod-group-${g.id}'),
                  icon: const Icon(Icons.delete_outline),
                  tooltip: tr(context, 'Remove'),
                  onPressed: () {
                    widget.catalogue.removeModifierGroup(g.id);
                    setState(() {});
                  },
                )
              else
                Padding(
                  key: Key('mod-group-from-odoo-${g.id}'),
                  padding: const EdgeInsetsDirectional.only(end: 12),
                  child: Text(tr(context, 'From Odoo'),
                      style: const TextStyle(color: Colors.black45, fontSize: 12)),
                ),
            ]),
          ),
          for (final m in g.modifiers)
            ListTile(
              key: Key('mod-option-${m.id}'),
              dense: true,
              leading: const Icon(Icons.subdirectory_arrow_right, size: 18),
              title: Text(m.name),
              subtitle: m.price == 0 ? null : Text('+${m.price.toStringAsFixed(2)}'),
              trailing: IconButton(
                key: Key('remove-mod-option-${m.id}'),
                icon: const Icon(Icons.close),
                tooltip: tr(context, 'Remove'),
                onPressed: () {
                  widget.catalogue.removeModifier(m.id);
                  setState(() {});
                },
              ),
            ),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: TextButton.icon(
                key: Key('add-mod-option-${g.id}'),
                icon: const Icon(Icons.add, size: 18),
                label: Text(tr(context, 'Add a choice')),
                onPressed: () => _optionDialog(g),
              ),
            ),
          ),
        ]),
      );

  Future<void> _groupDialog(Product row, {ModifierGroup? group}) async {
    final name = TextEditingController(text: group?.name ?? '');
    final min = TextEditingController(text: '${group?.minSelection ?? 0}');
    final max = TextEditingController(text: '${group?.maxSelection ?? 1}');
    var required = group?.required ?? false;
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSt) => AlertDialog(
          title: Text(tr(ctx, group == null ? 'Add a choice group' : 'Edit group')),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(
              key: const Key('mod-group-name'),
              controller: name,
              autofocus: true,
              decoration: InputDecoration(labelText: tr(ctx, 'Name')),
            ),
            Row(children: [
              Expanded(
                child: TextField(
                  key: const Key('mod-group-min'),
                  controller: min,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: InputDecoration(labelText: tr(ctx, 'Min')),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  key: const Key('mod-group-max'),
                  controller: max,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: InputDecoration(
                    labelText: tr(ctx, 'Max'),
                    helperText: tr(ctx, '0 for any'),
                  ),
                ),
              ),
            ]),
            SwitchListTile(
              key: const Key('mod-group-required'),
              value: required,
              title: Text(tr(ctx, 'Must be answered')),
              onChanged: (v) => setSt(() => required = v),
            ),
          ]),
          actions: [
            TextButton(
              key: const Key('mod-group-cancel'),
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(tr(ctx, 'Cancel')),
            ),
            FilledButton(
              key: const Key('mod-group-save'),
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(tr(ctx, 'Save')),
            ),
          ],
        ),
      ),
    );
    if (saved != true || name.text.trim().isEmpty) return;
    final minValue = int.tryParse(min.text.trim()) ?? 0;
    final maxValue = int.tryParse(max.text.trim()) ?? 0;
    if (group == null) {
      widget.catalogue.addModifierGroup(
        productId: row.id,
        name: name.text.trim(),
        minSelection: minValue,
        maxSelection: maxValue,
        required: required,
      );
    } else {
      widget.catalogue.saveModifierGroup(ModifierGroup(
        id: group.id,
        name: name.text.trim(),
        sequence: group.sequence,
        minSelection: minValue,
        maxSelection: maxValue,
        required: required,
        source: CatalogueSource.local,
      ));
    }
    setState(() {});
  }

  Future<void> _optionDialog(ModifierGroup group) async {
    final name = TextEditingController();
    final price = TextEditingController();
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr(ctx, 'Add a choice')),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
            key: const Key('mod-option-name'),
            controller: name,
            autofocus: true,
            decoration: InputDecoration(labelText: tr(ctx, 'Name')),
          ),
          TextField(
            key: const Key('mod-option-price'),
            controller: price,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d{0,2}')),
            ],
            decoration: InputDecoration(
              labelText: tr(ctx, 'Extra charge'),
              helperText: tr(ctx, 'Leave empty for no charge'),
            ),
          ),
        ]),
        actions: [
          TextButton(
            key: const Key('mod-option-cancel'),
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(tr(ctx, 'Cancel')),
          ),
          FilledButton(
            key: const Key('mod-option-save'),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr(ctx, 'Save')),
          ),
        ],
      ),
    );
    if (saved != true || name.text.trim().isEmpty) return;
    widget.catalogue.addModifier(
      groupId: group.id,
      name: name.text.trim(),
      price: double.tryParse(price.text.trim()) ?? 0,
    );
    setState(() {});
  }
}

/// Pick an Odoo record to link to.
///
/// The list is whatever the server answers, already narrowed to this till's point of
/// sale where that is possible. A server that will not answer leaves the manager the
/// id box, which is the path that always works and the only one an offline till has.
Future<OdooRef?> showOdooPicker(BuildContext context,
    Future<List<OdooRef>> Function(String term) search, String term) {
  return showDialog<OdooRef>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(tr(ctx, 'Find in Odoo')),
      content: SizedBox(
        width: 420,
        child: FutureBuilder<List<OdooRef>>(
          future: search(term),
          builder: (ctx, snap) {
            if (snap.connectionState != ConnectionState.done) {
              return const SizedBox(
                  height: 80, child: Center(child: CircularProgressIndicator()));
            }
            if (snap.hasError) {
              return Text(
                key: const Key('odoo-picker-offline'),
                tr(ctx, 'The server did not answer. Type the id instead.'),
              );
            }
            final refs = snap.data ?? const <OdooRef>[];
            if (refs.isEmpty) {
              return Text(
                key: const Key('odoo-picker-empty'),
                tr(ctx, 'Nothing matched on this point of sale.'),
              );
            }
            return ListView(shrinkWrap: true, children: [
              for (final r in refs)
                ListTile(
                  key: Key('odoo-ref-${r.id}'),
                  dense: true,
                  title: Text(r.name),
                  subtitle: Text([
                    '#${r.id}',
                    if (r.reference != null) r.reference!,
                  ].join('  ·  ')),
                  onTap: () => Navigator.pop(ctx, r),
                ),
            ]);
          },
        ),
      ),
      actions: [
        TextButton(
          key: const Key('odoo-picker-close'),
          onPressed: () => Navigator.pop(ctx),
          child: Text(tr(ctx, 'Cancel')),
        ),
      ],
    ),
  );
}
