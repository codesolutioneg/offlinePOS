import 'package:flutter/material.dart';

import '../../app/pos_session.dart';
import '../../domain/catalogue.dart';

/// Modifier picker.
///
/// Opens instantly: the groups are handed in already resolved from local storage,
/// so there is no loading state and nothing to fail when the line is down.
class ModifierSheet extends StatefulWidget {
  const ModifierSheet({
    super.key,
    required this.product,
    required this.groups,
    required this.formatAmount,
  });

  final Product product;
  final List<ModifierGroup> groups;
  final String Function(double) formatAmount;

  @override
  State<ModifierSheet> createState() => _ModifierSheetState();
}

class _ModifierSheetState extends State<ModifierSheet> {
  /// group id -> modifier id -> quantity
  final Map<int, Map<int, int>> _picked = {};

  int _countIn(ModifierGroup g) =>
      (_picked[g.id] ?? const {}).values.fold(0, (a, b) => a + b);

  bool get _valid => widget.groups.every((g) => g.isSatisfiedBy(_countIn(g)));

  String? get _problem {
    for (final g in widget.groups) {
      final n = _countIn(g);
      if (g.isSatisfiedBy(n)) continue;
      if (g.maxSelection > 0 && n > g.maxSelection) {
        return '${g.name}: at most ${g.maxSelection}';
      }
      final need = (g.minSelection == 0 && g.required) ? 1 : g.minSelection;
      return '${g.name}: choose ${need - n} more';
    }
    return null;
  }

  void _toggle(ModifierGroup g, Modifier m) {
    setState(() {
      final sel = _picked.putIfAbsent(g.id, () => {});
      if (sel.containsKey(m.id)) {
        sel.remove(m.id);
        return;
      }
      // A single-choice group swaps rather than stacking, which is what a cashier
      // means when they tap a second size.
      if (g.maxSelection == 1) sel.clear();
      sel[m.id] = 1;
    });
  }

  void _confirm() {
    final chosen = <ChosenModifier>[];
    for (final g in widget.groups) {
      for (final entry in (_picked[g.id] ?? const {}).entries) {
        final m = g.modifiers.firstWhere((x) => x.id == entry.key);
        chosen.add(ChosenModifier(m, entry.value));
      }
    }
    Navigator.of(context).pop(chosen);
  }

  /// A percentage option shows a percentage. Showing it as money is how a 10%
  /// modifier gets mistaken for a flat 10.
  String _label(Modifier m) => switch (m.priceType) {
        ModifierPriceType.free => '',
        ModifierPriceType.percentage => '+${m.price.toStringAsFixed(0)}%',
        ModifierPriceType.fixed =>
          m.price == 0 ? '' : '+${widget.formatAmount(m.price)}',
      };

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        builder: (_, controller) => Column(
          children: [
            ListTile(
              title: Text(widget.product.name,
                  style: const TextStyle(fontWeight: FontWeight.bold)),
              trailing: IconButton(
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView(
                controller: controller,
                children: [
                  for (final g in widget.groups) ...[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                      child: Row(children: [
                        Text(g.name, style: const TextStyle(fontWeight: FontWeight.bold)),
                        if (g.required)
                          const Text(' *', style: TextStyle(color: Colors.red)),
                        const Spacer(),
                        Text(
                          g.maxSelection > 0
                              ? '${_countIn(g)}/${g.maxSelection}'
                              : '${_countIn(g)}',
                          style: const TextStyle(color: Colors.black54),
                        ),
                      ]),
                    ),
                    for (final m in g.modifiers)
                      CheckboxListTile(
                        key: Key('mod-${m.id}'),
                        dense: true,
                        value: (_picked[g.id] ?? const {}).containsKey(m.id),
                        onChanged: (_) => _toggle(g, m),
                        title: Text(m.name),
                        secondary: Text(_label(m)),
                      ),
                  ],
                ],
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Row(children: [
                if (_problem != null)
                  Expanded(
                    child: Text(_problem!,
                        key: const Key('validation'),
                        style: const TextStyle(color: Colors.orange)),
                  )
                else
                  const Spacer(),
                const SizedBox(width: 8),
                FilledButton(
                  key: const Key('confirm-modifiers'),
                  onPressed: _valid ? _confirm : null,
                  child: const Text('Add to order'),
                ),
              ]),
            ),
          ],
        ),
      ),
    );
  }
}
