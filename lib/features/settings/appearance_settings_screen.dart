import 'package:flutter/material.dart';

import '../../core/db/settings_store.dart';
import '../../core/i18n/l10n.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/feedback.dart';
import '../../domain/catalogue.dart';

/// How the till looks: light or dark, whether the grid shows product pictures,
/// what colour each category reads as, and the two colours the floor is drawn in.
///
/// Colour-coding the grid is what lets a cashier find a category at a glance the way
/// Dishflow's does: drinks are always one colour, mains another, no hunting through a
/// flat list mid-rush.
class AppearanceSettingsScreen extends StatefulWidget {
  const AppearanceSettingsScreen({
    super.key,
    required this.settings,
    required this.categories,
    required this.onChanged,
  });

  final SettingsStore settings;
  final List<Category> categories;

  /// Fired after every change, so anything caching the look (the sell screen's
  /// grid, the app's own theme) reloads without the manager leaving and re-entering
  /// settings.
  final VoidCallback onChanged;

  @override
  State<AppearanceSettingsScreen> createState() => _AppearanceSettingsScreenState();
}

/// A fixed, high-contrast palette. Fixed rather than a colour wheel: a manager
/// mid-rush needs "pick one of ten", not a picker to fiddle with.
const _palette = <Color>[
  Colors.red,
  Colors.deepOrange,
  Colors.orange,
  Colors.amber,
  Colors.green,
  Colors.teal,
  Colors.blue,
  Colors.indigo,
  Colors.purple,
  Colors.pink,
];

/// Shown for a category with no colour set yet, so unset never reads as "black".
const _unsetColor = Colors.grey;

/// Popped by the palette dialog's "Clear" option, distinct from the null that
/// comes back when the dialog is dismissed without a choice.
class _ClearSwatch {
  const _ClearSwatch();
}

const _clearSwatch = _ClearSwatch();

class _AppearanceSettingsScreenState extends State<AppearanceSettingsScreen> {
  Future<Object?> _pickSwatch(String title, int? current) => showDialog<Object>(
        context: context,
        builder: (ctx) => SimpleDialog(
          title: Text(title),
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final color in _palette)
                    InkWell(
                      key: Key('swatch-${color.toARGB32()}'),
                      onTap: () => Navigator.pop(ctx, color),
                      child: Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          color: color,
                          shape: BoxShape.circle,
                          border: current == color.toARGB32()
                              ? Border.all(color: Colors.black, width: 2)
                              : null,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            SimpleDialogOption(
              key: const Key('swatch-clear'),
              onPressed: () => Navigator.pop(ctx, _clearSwatch),
              child: Text(tr(ctx, 'Clear')),
            ),
          ],
        ),
      );

  Future<void> _pickColor(Category category) async {
    final result = await _pickSwatch('${tr(context, 'Colour for')} ${category.name}',
        widget.settings.categoryColors[category.id]);
    if (result == null) return;
    setState(() {
      if (result is _ClearSwatch) {
        widget.settings.setCategoryColor(category.id, null);
      } else if (result is Color) {
        widget.settings.setCategoryColor(category.id, result.toARGB32());
      }
    });
    widget.onChanged();
  }

  /// One of the two floor colours. Clearing puts that side back on the default
  /// rather than leaving the floor with a colour nobody chose.
  Future<void> _pickTableColor({required bool free}) async {
    final s = widget.settings;
    final current = free ? s.tableColorFree : s.tableColorOccupied;
    final result = await _pickSwatch(
        free ? tr(context, 'Free tables') : tr(context, 'Occupied tables'), current);
    if (result == null) return;
    final argb = result is Color ? result.toARGB32() : null;
    setState(() {
      if (free) {
        s.setTableColorFree(argb);
      } else {
        s.setTableColorOccupied(argb);
      }
    });
    widget.onChanged();
  }

  Widget _sectionHeader(String title) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
        child: Text(title,
            style: Theme.of(context)
                .textTheme
                .titleMedium
                ?.copyWith(fontWeight: FontWeight.bold)),
      );

  Widget _swatchTile({
    required Key key,
    required String title,
    required Color color,
    required bool isDefault,
    required VoidCallback onTap,
  }) =>
      ListTile(
        key: key,
        title: Text(title),
        subtitle: isDefault ? Text(tr(context, 'Default')) : null,
        trailing: Container(
          width: 28,
          height: 28,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        onTap: onTap,
      );

  @override
  Widget build(BuildContext context) {
    final s = widget.settings;
    return Scaffold(
      appBar: AppBar(title: Text(tr(context, 'Appearance'))),
      body: ListView(
        children: [
          _sectionHeader(tr(context, 'Theme')),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: SegmentedButton<String>(
              segments: [
                ButtonSegment(
                    value: 'system',
                    icon: const Icon(Icons.brightness_auto),
                    label: Text(tr(context, 'Automatic'), key: const Key('theme-system'))),
                ButtonSegment(
                    value: 'light',
                    icon: const Icon(Icons.light_mode_outlined),
                    label: Text(tr(context, 'Light'), key: const Key('theme-light'))),
                ButtonSegment(
                    value: 'dark',
                    icon: const Icon(Icons.dark_mode_outlined),
                    label: Text(tr(context, 'Dark'), key: const Key('theme-dark'))),
              ],
              selected: {AppTheme.modeKeys.contains(s.themeMode) ? s.themeMode : 'system'},
              onSelectionChanged: (picked) {
                setState(() => s.themeMode = picked.first);
                widget.onChanged();
              },
            ),
          ),
          _sectionHeader(tr(context, 'Product grid')),
          SwitchListTile(
            key: const Key('t-product-images'),
            title: Text(tr(context, 'Show product pictures')),
            subtitle: Text(tr(context,
                'Pictures come down with the menu on the next sync. A product without one keeps its colour.')),
            value: s.showProductImages,
            onChanged: (v) {
              setState(() => s.showProductImages = v);
              widget.onChanged();
            },
          ),
          _sectionHeader(tr(context, 'Table colours')),
          _swatchTile(
            key: const Key('table-colour-free'),
            title: tr(context, 'Free tables'),
            color: s.tableColorFree == null
                ? AppColors.tableFree
                : Color(s.tableColorFree!),
            isDefault: s.tableColorFree == null,
            onTap: () => _pickTableColor(free: true),
          ),
          _swatchTile(
            key: const Key('table-colour-occupied'),
            title: tr(context, 'Occupied tables'),
            color: s.tableColorOccupied == null
                ? AppColors.tableOccupied
                : Color(s.tableColorOccupied!),
            isDefault: s.tableColorOccupied == null,
            onTap: () => _pickTableColor(free: false),
          ),
          _sectionHeader(tr(context, 'Category colours')),
          if (widget.categories.isEmpty)
            EmptyState(
              icon: Icons.palette_outlined,
              title: tr(context, 'No categories yet'),
              message: tr(context, 'Add categories to the catalogue to colour-code them here'),
            )
          else
            for (final category in widget.categories)
              _swatchTile(
                key: Key('cat-${category.id}'),
                title: category.name,
                color: s.categoryColors[category.id] != null
                    ? Color(s.categoryColors[category.id]!)
                    : _unsetColor,
                isDefault: false,
                onTap: () => _pickColor(category),
              ),
        ],
      ),
    );
  }
}
