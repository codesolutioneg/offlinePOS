import 'package:flutter/material.dart';

import '../../core/db/settings_store.dart';
import '../../core/i18n/l10n.dart';
import '../../core/widgets/feedback.dart';
import '../../domain/catalogue.dart';

/// Lets a manager tag each category with a colour, so the product grid on the
/// sell screen reads at a glance the way Dishflow's does: drinks are always one
/// colour, mains another, no hunting through a flat list mid-rush.
class AppearanceSettingsScreen extends StatefulWidget {
  const AppearanceSettingsScreen({
    super.key,
    required this.settings,
    required this.categories,
    required this.onChanged,
  });

  final SettingsStore settings;
  final List<Category> categories;

  /// Fired after every colour change, so anything caching the palette (the sell
  /// screen's grid) reloads without the manager leaving and re-entering settings.
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
  Future<void> _pickColor(Category category) async {
    final current = widget.settings.categoryColors[category.id];
    final result = await showDialog<Object>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text('Colour for ${category.name}'),
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(tr(context, 'Category colours'))),
      body: widget.categories.isEmpty
          ? EmptyState(
              icon: Icons.palette_outlined,
              title: tr(context, 'No categories yet'),
              message: tr(context, 'Add categories to the catalogue to colour-code them here'),
            )
          : ListView.builder(
              itemCount: widget.categories.length,
              itemBuilder: (context, index) {
                final category = widget.categories[index];
                final argb = widget.settings.categoryColors[category.id];
                final swatchColor = argb != null ? Color(argb) : _unsetColor;
                return ListTile(
                  key: Key('cat-${category.id}'),
                  title: Text(category.name),
                  trailing: Container(
                    width: 28,
                    height: 28,
                    decoration: BoxDecoration(color: swatchColor, shape: BoxShape.circle),
                  ),
                  onTap: () => _pickColor(category),
                );
              },
            ),
    );
  }
}
