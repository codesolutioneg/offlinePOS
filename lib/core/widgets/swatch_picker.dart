import 'package:flutter/material.dart';

import '../i18n/l10n.dart';

/// A fixed, high-contrast palette. Fixed rather than a colour wheel: a manager
/// mid-rush needs "pick one of ten", not a picker to fiddle with.
const List<Color> kSwatchPalette = <Color>[
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

/// Shown where nothing has been chosen yet, so unset never reads as "black".
const Color kUnsetSwatch = Colors.grey;

/// Popped by the palette dialog's "Clear" option, distinct from the null that
/// comes back when the dialog is dismissed without a choice.
class ClearSwatch {
  const ClearSwatch();
}

const ClearSwatch kClearSwatch = ClearSwatch();

/// Ask for one of [kSwatchPalette], "no colour", or nothing at all.
///
/// Returns a [Color], [kClearSwatch] when the colour is being taken away, or null
/// when the dialog was dismissed. Shared so the category colours in Appearance and
/// the tile colour in the menu editor offer the same ten swatches under the same
/// keys, rather than drifting into two palettes that look nearly alike.
Future<Object?> pickSwatch(BuildContext context, String title, int? current) =>
    showDialog<Object>(
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
                for (final color in kSwatchPalette)
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
            onPressed: () => Navigator.pop(ctx, kClearSwatch),
            child: Text(tr(ctx, 'Clear')),
          ),
        ],
      ),
    );
