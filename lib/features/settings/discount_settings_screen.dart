import 'package:flutter/material.dart';

import '../../core/db/settings_store.dart';
import '../../core/i18n/l10n.dart';

/// Configure discounts: the quick-pick percentages a cashier can apply, an optional
/// maximum, and the reasons offered. Previously only the reason text was editable;
/// the percentages were hardcoded, so a shop could not set its own discount tiers.
class DiscountSettingsScreen extends StatefulWidget {
  const DiscountSettingsScreen({super.key, required this.settings, required this.onChanged});

  final SettingsStore settings;
  final VoidCallback onChanged;

  @override
  State<DiscountSettingsScreen> createState() => _DiscountSettingsScreenState();
}

class _DiscountSettingsScreenState extends State<DiscountSettingsScreen> {
  late List<double> _percents = List.of(widget.settings.discountPercents);
  late List<String> _reasons = List.of(widget.settings.discountReasons);
  late final TextEditingController _newPercent = TextEditingController();
  late final TextEditingController _newReason = TextEditingController();
  late final TextEditingController _max =
      TextEditingController(text: widget.settings.maxDiscountPercent > 0
          ? widget.settings.maxDiscountPercent.toStringAsFixed(0)
          : '');

  @override
  void dispose() {
    _newPercent.dispose();
    _newReason.dispose();
    _max.dispose();
    super.dispose();
  }

  void _persistPercents() {
    widget.settings.discountPercents = _percents;
    widget.onChanged();
  }

  void _persistReasons() {
    widget.settings.discountReasons = _reasons;
    widget.onChanged();
  }

  void _addPercent() {
    final v = double.tryParse(_newPercent.text.trim());
    if (v == null || v <= 0 || v > 100 || _percents.contains(v)) return;
    setState(() {
      _percents = [..._percents, v]..sort();
      _newPercent.clear();
    });
    _persistPercents();
  }

  void _addReason() {
    final r = _newReason.text.trim();
    if (r.isEmpty || _reasons.contains(r)) return;
    setState(() {
      _reasons = [..._reasons, r];
      _newReason.clear();
    });
    _persistReasons();
  }

  void _saveMax() {
    widget.settings.maxDiscountPercent = double.tryParse(_max.text.trim()) ?? 0;
    widget.onChanged();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr(context, 'Saved'))));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(tr(context, 'Discounts'))),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Text(tr(context, 'Quick discount percentages'),
              style: const TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final p in _percents)
                InputChip(
                  key: Key('pct-${p.toStringAsFixed(0)}'),
                  label: Text('${p.toStringAsFixed(p == p.roundToDouble() ? 0 : 1)}%'),
                  onDeleted: () {
                    setState(() => _percents = _percents.where((x) => x != p).toList());
                    _persistPercents();
                  },
                ),
            ],
          ),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
              child: TextField(
                key: const Key('new-percent'),
                controller: _newPercent,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(
                    labelText: tr(context, 'Add percentage'),
                    suffixText: '%',
                    border: const OutlineInputBorder(),
                    isDense: true),
                onSubmitted: (_) => _addPercent(),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(
                key: const Key('add-percent'),
                onPressed: _addPercent,
                child: Text(tr(context, 'Add'))),
          ]),
          const Divider(height: 32),
          Text(tr(context, 'Maximum discount'),
              style: const TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
              child: TextField(
                key: const Key('max-discount'),
                controller: _max,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                    labelText: tr(context, 'Cap (blank = none)'),
                    suffixText: '%',
                    border: const OutlineInputBorder(),
                    isDense: true),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(
                key: const Key('save-max'),
                onPressed: _saveMax,
                child: Text(tr(context, 'Save'))),
          ]),
          const Divider(height: 32),
          Text(tr(context, 'Discount reasons'),
              style: const TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          for (var i = 0; i < _reasons.length; i++)
            ListTile(
              key: Key('reason-$i'),
              dense: true,
              title: Text(_reasons[i]),
              trailing: IconButton(
                key: Key('delete-reason-$i'),
                icon: const Icon(Icons.delete_outline),
                onPressed: () {
                  setState(() => _reasons = List.of(_reasons)..removeAt(i));
                  _persistReasons();
                },
              ),
            ),
          Row(children: [
            Expanded(
              child: TextField(
                key: const Key('new-reason'),
                controller: _newReason,
                decoration: InputDecoration(
                    labelText: tr(context, 'Add reason'),
                    border: const OutlineInputBorder(),
                    isDense: true),
                onSubmitted: (_) => _addReason(),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(
                key: const Key('add-reason'),
                onPressed: _addReason,
                child: Text(tr(context, 'Add'))),
          ]),
        ],
      ),
    );
  }
}
