import 'package:flutter/material.dart';

import '../../app/pos_session.dart';
import '../../core/i18n/l10n.dart';
import '../../core/theme/app_colors.dart';
import '../../domain/catalogue.dart';
import '../../domain/order.dart';

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
    this.initial = const [],
    this.confirmLabel,
  });

  final Product product;
  final List<ModifierGroup> groups;
  final String Function(double) formatAmount;

  /// What the line already carries, so reopening the sheet on a line in the cart
  /// shows the current choices instead of a blank sheet. Empty while ringing, which
  /// is what a fresh line has.
  final List<OrderModifier> initial;

  /// The confirm button's wording. Null reads "Add to order", which is what ringing
  /// a line does; editing one passes its own.
  final String? confirmLabel;

  @override
  State<ModifierSheet> createState() => _ModifierSheetState();
}

class _ModifierSheetState extends State<ModifierSheet> {
  /// group id -> modifier id -> quantity
  final Map<int, Map<int, int>> _picked = {};

  @override
  void initState() {
    super.initState();
    // Prefill from the line, matched on the option id through the groups on screen.
    // A choice the catalogue has since dropped is therefore simply not carried back
    // in: the sheet can only offer what the menu still has, and pretending otherwise
    // would show the cashier a row they cannot see or clear.
    final have = {for (final m in widget.initial) m.modifierId: m};
    for (final g in widget.groups) {
      for (final m in g.modifiers) {
        final on = have[m.id];
        if (on == null) continue;
        final n = on.quantity.round();
        (_picked[g.id] ??= {})[m.id] = n < 1 ? 1 : n;
      }
    }
  }

  int _countIn(ModifierGroup g) =>
      (_picked[g.id] ?? const {}).values.fold(0, (a, b) => a + b);

  bool get _valid => widget.groups.every((g) => g.isSatisfiedBy(_countIn(g)));

  String? get _problem {
    for (final g in widget.groups) {
      final n = _countIn(g);
      if (g.isSatisfiedBy(n)) continue;
      if (g.maxSelection > 0 && n > g.maxSelection) {
        return '${g.name}: ${tr(context, 'at most')} ${g.maxSelection}';
      }
      final need = (g.minSelection == 0 && g.required) ? 1 : g.minSelection;
      return '${g.name}: ${tr(context, 'choose')} ${need - n} ${tr(context, 'more')}';
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

  void _bump(ModifierGroup g, Modifier m, int delta) {
    setState(() {
      final sel = _picked.putIfAbsent(g.id, () => {});
      final next = (sel[m.id] ?? 0) + delta;
      if (next <= 0) {
        sel.remove(m.id);
      } else {
        sel[m.id] = next;
      }
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
  ///
  /// An option that replaces the dish's price shows that price with no plus in
  /// front of it, because it is not an addition: the menu says a large coffee is
  /// 20, and "+10" on the option a cashier taps to sell one is a different number
  /// from the one the customer was quoted.
  String _label(Modifier m) => switch (m.priceType) {
        ModifierPriceType.free => '',
        ModifierPriceType.percentage => '+${m.price.toStringAsFixed(0)}%',
        ModifierPriceType.replace => widget.formatAmount(m.price),
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
                  style:
                      const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
              subtitle: Text(widget.formatAmount(widget.product.price),
                  style: TextStyle(
                      fontWeight: FontWeight.w600,
                      color: Theme.of(context).colorScheme.primary)),
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
                        Text(g.name,
                            style: const TextStyle(fontWeight: FontWeight.bold)),
                        if (g.required) ...[
                          const SizedBox(width: 6),
                          StatusChip(tr(context, 'Required'), AppColors.warning),
                        ],
                        const Spacer(),
                        Text(
                          g.maxSelection > 0
                              ? '${_countIn(g)}/${g.maxSelection}'
                              : '${_countIn(g)}',
                          style: TextStyle(
                              fontWeight: FontWeight.w600,
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant),
                        ),
                      ]),
                    ),
                    for (final m in g.modifiers)
                      Builder(builder: (context) {
                        final qty = (_picked[g.id] ?? const {})[m.id] ?? 0;
                        final selected = qty > 0;
                        // Multi-select options can be taken more than once ("2x
                        // extra cheese"): show a stepper once selected. Single-choice
                        // groups stay a plain checkbox.
                        final canRepeat = g.maxSelection != 1;
                        return CheckboxListTile(
                          key: Key('mod-${m.id}'),
                          dense: true,
                          value: selected,
                          onChanged: (_) => _toggle(g, m),
                          title: Text(m.name),
                          subtitle: (selected && canRepeat)
                              ? Row(mainAxisSize: MainAxisSize.min, children: [
                                  IconButton(
                                    key: Key('mod-${m.id}-minus'),
                                    icon: const Icon(Icons.remove_circle_outline, size: 26),
                                    onPressed: () => _bump(g, m, -1),
                                  ),
                                  Text('$qty'),
                                  IconButton(
                                    key: Key('mod-${m.id}-plus'),
                                    icon: const Icon(Icons.add_circle_outline, size: 26),
                                    onPressed: () => _bump(g, m, 1),
                                  ),
                                ])
                              : null,
                          secondary: Text(_label(m)),
                        );
                      }),
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
                        style: const TextStyle(
                            color: AppColors.warning,
                            fontWeight: FontWeight.w600)),
                  )
                else
                  const Spacer(),
                const SizedBox(width: 8),
                SizedBox(
                  height: 52,
                  child: FilledButton.icon(
                    key: const Key('confirm-modifiers'),
                    onPressed: _valid ? _confirm : null,
                    icon: const Icon(Icons.check),
                    label:
                        Text(widget.confirmLabel ?? tr(context, 'Add to order')),
                  ),
                ),
              ]),
            ),
          ],
        ),
      ),
    );
  }
}
