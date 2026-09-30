import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/i18n/l10n.dart';

/// A kitchen cancel slip that reached no printer and no spool: the item is off
/// the bill, but the kitchen was never told and may still be cooking it.
class LostKitchenVoid {
  const LostKitchenVoid({
    required this.id,
    required this.item,
    required this.where,
    required this.retry,
  });

  final int id;

  /// What was voided, as the kitchen would read it (`2× Burger`).
  final String item;

  /// The table or order it was on, so the cashier knows which ticket to chase.
  final String where;

  /// Send the slip again. True when a printer or the spool took it.
  final Future<bool> Function() retry;
}

/// The warning that stays on the sell screen until every lost cancel slip has
/// been reprinted or the cashier says the kitchen was told by hand. A toast would
/// be gone before anybody walked to the pass.
class LostVoidBanner extends StatelessWidget {
  const LostVoidBanner({super.key, required this.lost, required this.onResolved});

  final ValueListenable<List<LostKitchenVoid>> lost;

  /// Take [LostKitchenVoid.id] off the list: reprinted, or the kitchen was told.
  final void Function(int id) onResolved;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<List<LostKitchenVoid>>(
        valueListenable: lost,
        builder: (context, items, _) => Column(
          mainAxisSize: MainAxisSize.min,
          children: [for (final v in items) _row(context, v)],
        ),
      );

  Widget _row(BuildContext context, LostKitchenVoid v) {
    final scheme = Theme.of(context).colorScheme;
    final text = tr(context, 'Void for {item} ({where}) did not reach the kitchen. Tell the kitchen.')
        .replaceAll('{item}', v.item)
        .replaceAll('{where}', v.where);
    return Container(
      key: Key('lost-void-${v.id}'),
      width: double.infinity,
      color: scheme.errorContainer,
      padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 12),
      child: Row(children: [
        Icon(Icons.warning_amber_rounded, color: scheme.onErrorContainer),
        const SizedBox(width: 8),
        Expanded(
          child: Text(text,
              style: TextStyle(color: scheme.onErrorContainer, fontWeight: FontWeight.w600)),
        ),
        TextButton(
          key: Key('lost-void-retry-${v.id}'),
          onPressed: () async {
            if (await v.retry()) onResolved(v.id);
          },
          child: Text(tr(context, 'Retry')),
        ),
        TextButton(
          key: Key('lost-void-told-${v.id}'),
          onPressed: () => onResolved(v.id),
          child: Text(tr(context, 'Kitchen told')),
        ),
      ]),
    );
  }
}
