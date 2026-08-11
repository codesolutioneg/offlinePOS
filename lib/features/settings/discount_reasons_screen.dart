import 'package:flutter/material.dart';

import '../../core/db/settings_store.dart';
import '../../core/i18n/l10n.dart';

/// Manage the discount-reason quick picks shown on the discount dialog.
///
/// Before this screen existed the list was whatever shipped in code (see
/// [SettingsStore.discountReasons]'s default), with no way for a manager to add a
/// till-specific reason like "Regular customer" without a rebuild. This screen is
/// the only place that list is edited, and it always writes the whole list back in
/// one call so there is never a partial write a concurrent read could see.
class DiscountReasonsScreen extends StatefulWidget {
  const DiscountReasonsScreen({super.key, required this.settings, required this.onChanged});

  final SettingsStore settings;

  /// Called after every change so the caller can refresh the copy of the list it
  /// is holding (this screen owns no state the caller can see).
  final VoidCallback onChanged;

  @override
  State<DiscountReasonsScreen> createState() => _DiscountReasonsScreenState();
}

class _DiscountReasonsScreenState extends State<DiscountReasonsScreen> {
  late final TextEditingController _newReason;

  @override
  void initState() {
    super.initState();
    _newReason = TextEditingController();
  }

  @override
  void dispose() {
    _newReason.dispose();
    super.dispose();
  }

  void _add() {
    final reason = _newReason.text.trim();
    if (reason.isEmpty) return;
    final reasons = List<String>.from(widget.settings.discountReasons)..add(reason);
    widget.settings.discountReasons = reasons;
    widget.onChanged();
    _newReason.clear();
    setState(() {});
  }

  void _remove(int index) {
    final reasons = List<String>.from(widget.settings.discountReasons)..removeAt(index);
    widget.settings.discountReasons = reasons;
    widget.onChanged();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final reasons = widget.settings.discountReasons;
    return Scaffold(
      appBar: AppBar(title: Text(tr(context, 'Discount reasons'))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          for (var i = 0; i < reasons.length; i++)
            ListTile(
              key: Key('reason-$i'),
              title: Text(reasons[i]),
              trailing: IconButton(
                key: Key('delete-reason-$i'),
                icon: const Icon(Icons.delete_outline),
                tooltip: tr(context, 'Remove'),
                onPressed: () => _remove(i),
              ),
            ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: TextField(
                  key: const Key('new-reason'),
                  controller: _newReason,
                  decoration: InputDecoration(
                    labelText: tr(context, 'New reason'),
                    hintText: tr(context, 'e.g. Regular customer'),
                    border: const OutlineInputBorder(),
                  ),
                  onSubmitted: (_) => _add(),
                ),
              ),
              const SizedBox(width: 12),
              FilledButton(
                key: const Key('add-reason'),
                onPressed: _add,
                child: Text(tr(context, 'Add')),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
