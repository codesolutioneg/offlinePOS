import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/i18n/l10n.dart';
import 'stress_day_runner.dart';

/// Asks how big a full-day or delivery stress should be before it starts.
/// Returns null when the manager backs out.
Future<StressDayConfig?> showStressDayDialog(
  BuildContext context,
  StressDayMode mode, {
  required bool canPrint,
}) => showDialog<StressDayConfig>(
  context: context,
  builder: (_) => _StressDayDialog(mode: mode, canPrint: canPrint),
);

class _StressDayDialog extends StatefulWidget {
  const _StressDayDialog({required this.mode, required this.canPrint});

  final StressDayMode mode;
  final bool canPrint;

  @override
  State<_StressDayDialog> createState() => _StressDayDialogState();
}

class _StressDayDialogState extends State<_StressDayDialog> {
  late final _orders = TextEditingController(
    text: widget.mode == StressDayMode.fullDay ? '40' : '20',
  );
  final _cashiers = TextEditingController(text: '3');
  late bool _printing = widget.canPrint;

  @override
  void dispose() {
    _orders.dispose();
    _cashiers.dispose();
    super.dispose();
  }

  int _read(TextEditingController c, int fallback, int max) =>
      (int.tryParse(c.text.trim()) ?? fallback).clamp(1, max);

  Widget _number(String label, TextEditingController c, String key) =>
      TextField(
        key: Key(key),
        controller: c,
        keyboardType: TextInputType.number,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        decoration: InputDecoration(labelText: tr(context, label)),
      );

  @override
  Widget build(BuildContext context) {
    final full = widget.mode == StressDayMode.fullDay;
    return AlertDialog(
      title: Text(tr(context, full ? 'Full-day stress' : 'Delivery stress')),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              tr(
                context,
                'Lab orders never leave this till. Press "Clean up" when you are done.',
              ),
            ),
            _number('Orders', _orders, 'stress-day-orders'),
            _number('Cashiers at once', _cashiers, 'stress-day-cashiers'),
            if (widget.canPrint)
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(
                  tr(context, 'Print to the kitchen and receipt printers'),
                ),
                value: _printing,
                onChanged: (v) => setState(() => _printing = v),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(tr(context, 'Cancel')),
        ),
        FilledButton(
          key: const Key('stress-day-start'),
          onPressed: () => Navigator.pop(
            context,
            StressDayConfig(
              mode: widget.mode,
              orders: _read(_orders, 40, 1000),
              cashiers: _read(_cashiers, 3, 8),
              printing: _printing,
            ),
          ),
          child: Text(tr(context, 'Start')),
        ),
      ],
    );
  }
}
