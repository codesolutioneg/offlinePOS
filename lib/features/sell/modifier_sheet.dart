import 'package:flutter/material.dart';

import '../../app/pos_session.dart';
import '../../core/i18n/l10n.dart';
import '../../core/theme/app_colors.dart';
import '../../domain/catalogue.dart';
import '../../domain/order.dart';

/// Modifier picker — Dishflow-style option tiles in a dialog-friendly sheet.
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

  /// Which group step is expanded (Dishflow stepped flow).
  int _step = 0;

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
      if (g.maxSelection == 1) {
        sel.clear();
      } else if (g.maxSelection > 0 && _countIn(g) >= g.maxSelection) {
        // A capped group ("choose two") refuses the one that would overrun it,
        // rather than letting the cashier tick a third and only then find the
        // order will not confirm.
        return;
      }
      sel[m.id] = 1;
      _advanceIfReady(g);
    });
  }

  void _bump(ModifierGroup g, Modifier m, int delta) {
    setState(() {
      final sel = _picked.putIfAbsent(g.id, () => {});
      final cur = sel[m.id] ?? 0;
      if (delta > 0) {
        // A group with a cap does not take more than it allows, whichever item the
        // extra one is put on; and an option with its own cap does not go past it.
        if (g.maxSelection > 0 && _countIn(g) >= g.maxSelection) return;
        if (m.maxQuantity > 0 && cur >= m.maxQuantity) return;
      }
      final next = cur + delta;
      if (next <= 0) {
        sel.remove(m.id);
      } else {
        sel[m.id] = next;
      }
      if (delta > 0) _advanceIfReady(g);
    });
  }

  /// Whether this group's choice is "done" enough to advance / auto-add (Dishflow).
  bool _shouldAutoProgress(ModifierGroup g) {
    final n = _countIn(g);
    if (!g.isSatisfiedBy(n)) return false;
    // Single-choice (radio): one tap always commits the step — even when Odoo did
    // not mark the group required, which is common and blocked advance before.
    if (g.maxSelection == 1) return n == 1;
    // Multi with a hard cap: commit when the cap is full.
    if (g.maxSelection > 1) return n >= g.maxSelection;
    // Unlimited: cashier uses Add to order.
    return false;
  }

  void _advanceIfReady(ModifierGroup g) {
    if (!_shouldAutoProgress(g)) return;
    final i = widget.groups.indexOf(g);
    if (i < 0 || _step != i) return;
    // Dishflow: satisfying this step moves to the next; the last step adds the
    // line to the cart by itself when every group is valid.
    // Editing an existing line keeps the confirm button — auto-add is for ringing.
    final ringing = widget.initial.isEmpty && widget.confirmLabel == null;
    if (i < widget.groups.length - 1) {
      _step = i + 1;
      return;
    }
    if (ringing && _valid) {
      // Defer pop until after setState finishes so the sheet does not dispose mid-frame.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _confirm();
      });
    }
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

  double get _previewTotal {
    var t = widget.product.price;
    for (final g in widget.groups) {
      final sel = _picked[g.id] ?? const {};
      for (final m in g.modifiers) {
        final q = sel[m.id] ?? 0;
        if (q <= 0) continue;
        switch (m.priceType) {
          case ModifierPriceType.fixed:
            t += m.price * q;
          case ModifierPriceType.percentage:
            t += widget.product.price * m.price / 100 * q;
          case ModifierPriceType.replace:
            t = m.price;
          case ModifierPriceType.free:
            break;
        }
      }
    }
    return t;
  }

  @override
  Widget build(BuildContext context) {
    final groups = widget.groups;
    return Material(
      color: AppColors.background,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      clipBehavior: Clip.antiAlias,
      child: SafeArea(
        child: Padding(
          padding:
              EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
          child: SizedBox(
            height: MediaQuery.of(context).size.height * 0.78,
            child: Column(
              children: [
                _header(context),
                if (groups.length > 1) _stepChips(groups),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          groups[_step.clamp(0, groups.length - 1)].name,
                          style: const TextStyle(
                              fontWeight: FontWeight.w800, fontSize: 15),
                        ),
                      ),
                      Text(
                        '${_step + 1}/${groups.length}',
                        style: const TextStyle(
                            fontWeight: FontWeight.w700,
                            color: AppColors.brandNavyLight),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                    children: [
                      // Dishflow: one step at a time — only the current group.
                      _groupCard(groups[_step.clamp(0, groups.length - 1)],
                          _step.clamp(0, groups.length - 1),
                          showTitle: false),
                    ],
                  ),
                ),
                _footer(context),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _header(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 14, 8, 12),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [AppColors.brandNavy, AppColors.brandNavyLight],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(widget.product.name,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.w800)),
                const SizedBox(height: 4),
                Text(widget.formatAmount(_previewTotal),
                    style: const TextStyle(
                        color: AppColors.primaryLight,
                        fontWeight: FontWeight.w700,
                        fontSize: 15)),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, color: Colors.white70),
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
    );
  }

  Widget _stepChips(List<ModifierGroup> groups) {
    return SizedBox(
      height: 48,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        itemCount: groups.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (_, i) {
          final g = groups[i];
          final selected = _step == i;
          final done = g.isSatisfiedBy(_countIn(g));
          return InkWell(
            onTap: () => setState(() => _step = i),
            borderRadius: BorderRadius.circular(20),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: selected
                    ? AppColors.primary
                    : done
                        ? AppColors.primary.withValues(alpha: 0.15)
                        : AppColors.surface.withValues(alpha: 0.6),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: selected || done
                      ? AppColors.primary
                      : AppColors.surface,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (done && !selected)
                    const Padding(
                      padding: EdgeInsets.only(right: 4),
                      child: Icon(Icons.check, size: 14, color: AppColors.primary),
                    ),
                  Text(
                    g.name,
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: selected ? Colors.white : AppColors.brandNavy,
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _groupCard(ModifierGroup g, int index, {bool showTitle = true}) {
    final focused = widget.groups.length == 1 || _step == index;
    final count = _countIn(g);
    return AnimatedOpacity(
      duration: const Duration(milliseconds: 180),
      opacity: focused ? 1 : 0.45,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (showTitle)
              Row(
                children: [
                  Expanded(
                    child: Text(g.name,
                        style: const TextStyle(
                            fontWeight: FontWeight.w800, fontSize: 15)),
                  ),
                  if (g.required)
                    StatusChip(tr(context, 'Required'), AppColors.warning),
                  const SizedBox(width: 8),
                  Text(
                    g.maxSelection > 0 ? '$count/${g.maxSelection}' : '$count',
                    style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        color: AppColors.brandNavyLight),
                  ),
                ],
              ),
            if (showTitle) const SizedBox(height: 10),
            if (!showTitle && g.required)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Row(
                  children: [
                    StatusChip(tr(context, 'Required'), AppColors.warning),
                    const Spacer(),
                    Text(
                      g.maxSelection > 0 ? '$count/${g.maxSelection}' : '$count',
                      style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          color: AppColors.brandNavyLight),
                    ),
                  ],
                ),
              ),
            LayoutBuilder(builder: (context, c) {
              final cols = c.maxWidth >= 520 ? 3 : 2;
              return GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: g.modifiers.length,
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: cols,
                  mainAxisSpacing: 8,
                  crossAxisSpacing: 8,
                  childAspectRatio: g.maxSelection == 1 ? 1.35 : 1.15,
                ),
                itemBuilder: (_, i) {
                  final m = g.modifiers[i];
                  final qty = (_picked[g.id] ?? const {})[m.id] ?? 0;
                  final selected = qty > 0;
                  final single = g.maxSelection == 1;
                  final atMax = (g.maxSelection > 0 && count >= g.maxSelection) ||
                      (m.maxQuantity > 0 && qty >= m.maxQuantity);
                  return _OptionTile(
                    key: Key('mod-${m.id}'),
                    modifierId: m.id,
                    name: m.name,
                    priceLabel: _label(m),
                    selected: selected,
                    singleChoice: single,
                    quantity: qty,
                    onTap: single
                        ? () => _toggle(g, m)
                        : (atMax && !selected)
                            ? null
                            : () => _bump(g, m, 1),
                    onMinus: selected ? () => _bump(g, m, -1) : null,
                    onPlus: atMax ? null : () => _bump(g, m, 1),
                  );
                },
              );
            }),
          ],
        ),
      ),
    );
  }

  Widget _footer(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.06),
            blurRadius: 8,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: Row(
        children: [
          if (_problem != null)
            Expanded(
              child: Text(_problem!,
                  key: const Key('validation'),
                  style: const TextStyle(
                      color: AppColors.warning, fontWeight: FontWeight.w600)),
            )
          else
            Expanded(
              child: Text(widget.formatAmount(_previewTotal),
                  style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                      color: AppColors.brandNavy)),
            ),
          const SizedBox(width: 8),
          SizedBox(
            height: 52,
            child: FilledButton.icon(
              key: const Key('confirm-modifiers'),
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.primary,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14)),
              ),
              onPressed: _valid ? _confirm : null,
              icon: const Icon(Icons.check),
              label: Text(widget.confirmLabel ?? tr(context, 'Add to order')),
            ),
          ),
        ],
      ),
    );
  }
}

class _OptionTile extends StatelessWidget {
  const _OptionTile({
    super.key,
    required this.modifierId,
    required this.name,
    required this.priceLabel,
    required this.selected,
    required this.singleChoice,
    required this.quantity,
    required this.onTap,
    this.onMinus,
    this.onPlus,
  });

  final int modifierId;
  final String name;
  final String priceLabel;
  final bool selected;
  final bool singleChoice;
  final int quantity;
  final VoidCallback? onTap;
  final VoidCallback? onMinus;
  final VoidCallback? onPlus;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          decoration: BoxDecoration(
            color: selected
                ? AppColors.primary.withValues(alpha: 0.12)
                : Colors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: selected ? AppColors.primary : AppColors.surface,
              width: selected ? 2 : 1,
            ),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (singleChoice)
                AnimatedContainer(
                  duration: const Duration(milliseconds: 160),
                  width: 18,
                  height: 18,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: selected
                          ? AppColors.primary
                          : AppColors.brandNavyLight.withValues(alpha: 0.4),
                      width: selected ? 5 : 2,
                    ),
                  ),
                )
              else
                Icon(
                  selected ? Icons.check_box : Icons.check_box_outline_blank,
                  color: selected ? AppColors.primary : AppColors.brandNavyLight,
                  size: 20,
                ),
              const SizedBox(height: 4),
              Text(
                name,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  color: AppColors.brandNavy,
                ),
              ),
              if (priceLabel.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(priceLabel,
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: selected
                            ? AppColors.primaryDark
                            : AppColors.brandNavyLight)),
              ],
              if (!singleChoice) ...[
                const SizedBox(height: 4),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    IconButton(
                      key: Key('mod-$modifierId-minus'),
                      visualDensity: VisualDensity.compact,
                      iconSize: 20,
                      onPressed: onMinus,
                      icon: const Icon(Icons.remove_circle_outline),
                    ),
                    SizedBox(
                      width: 28,
                      child: Text('$quantity',
                          key: Key('mod-$modifierId-qty'),
                          textAlign: TextAlign.center,
                          style: TextStyle(
                              fontWeight: FontWeight.w800,
                              fontSize: 14,
                              color: selected
                                  ? null
                                  : Theme.of(context).disabledColor)),
                    ),
                    IconButton(
                      key: Key('mod-$modifierId-plus'),
                      visualDensity: VisualDensity.compact,
                      iconSize: 20,
                      onPressed: onPlus,
                      icon: const Icon(Icons.add_circle_outline),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
