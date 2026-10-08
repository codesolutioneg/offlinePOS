import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/i18n/l10n.dart';
import 'multi_till_runner.dart';

/// Asks how many points of sale and cashiers a multi-till run has, and where its
/// sessions go. Returns null when the manager backs out.
Future<MultiTillConfig?> showMultiTillDialog(
  BuildContext context, {
  required String? odooUrl,
  required String cloudUrl,
}) =>
    showDialog<MultiTillConfig>(
      context: context,
      builder: (_) => _MultiTillDialog(odooUrl: odooUrl, cloudUrl: cloudUrl),
    );

class _MultiTillDialog extends StatefulWidget {
  const _MultiTillDialog({required this.odooUrl, required this.cloudUrl});

  final String? odooUrl;
  final String cloudUrl;

  @override
  State<_MultiTillDialog> createState() => _MultiTillDialogState();
}

class _MultiTillDialogState extends State<_MultiTillDialog> {
  final _tills = TextEditingController(text: '6');
  final _cashiers = TextEditingController(text: '2');
  final _sessions = TextEditingController(text: '3');
  final _orders = TextEditingController(text: '10');
  late final _url = TextEditingController(text: widget.cloudUrl);
  final _code = TextEditingController();
  late bool _odoo = widget.odooUrl != null;

  @override
  void dispose() {
    for (final c in [_tills, _cashiers, _sessions, _orders, _url, _code]) {
      c.dispose();
    }
    super.dispose();
  }

  int _read(TextEditingController c, int fallback, int max) =>
      (int.tryParse(c.text.trim()) ?? fallback).clamp(1, max);

  Widget _number(String label, TextEditingController c, String key) => TextField(
        key: Key(key),
        controller: c,
        keyboardType: TextInputType.number,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        decoration: InputDecoration(labelText: tr(context, label)),
      );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text(tr(context, 'Multi-till stress')),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: theme.colorScheme.errorContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  tr(
                    context,
                    'These are real orders: every closed session is booked in Odoo and '
                    'every sale shows on the reports site. The tills run in memory, so '
                    'this till\'s own data is not touched.',
                  ),
                  style: TextStyle(color: theme.colorScheme.onErrorContainer),
                ),
              ),
              Row(children: [
                Expanded(child: _number('Points of sale', _tills, 'multi-till-tills')),
                const SizedBox(width: 12),
                Expanded(
                    child: _number('Cashiers per point', _cashiers, 'multi-till-cashiers')),
              ]),
              Row(children: [
                Expanded(child: _number('Sessions', _sessions, 'multi-till-sessions')),
                const SizedBox(width: 12),
                Expanded(
                    child: _number('Orders per session', _orders, 'multi-till-orders')),
              ]),
              const SizedBox(height: 8),
              SwitchListTile(
                key: const Key('multi-till-odoo'),
                contentPadding: EdgeInsets.zero,
                title: Text(tr(context, 'Close each session into Odoo')),
                subtitle: Text(widget.odooUrl ?? tr(context, 'No Odoo server on this till')),
                value: _odoo,
                onChanged: widget.odooUrl == null ? null : (v) => setState(() => _odoo = v),
              ),
              TextField(
                key: const Key('multi-till-url'),
                controller: _url,
                decoration: InputDecoration(labelText: tr(context, 'Reports server')),
              ),
              TextField(
                key: const Key('multi-till-code'),
                controller: _code,
                decoration: InputDecoration(
                  labelText: tr(context, 'Branch pairing code'),
                  helperText: tr(context, 'Leave empty to skip the reports site'),
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(tr(context, 'Cancel')),
        ),
        FilledButton(
          key: const Key('multi-till-start'),
          onPressed: () => Navigator.pop(
            context,
            MultiTillConfig(
              tills: _read(_tills, 6, 8),
              cashiers: _read(_cashiers, 2, 8),
              sessions: _read(_sessions, 3, 20),
              ordersPerSession: _read(_orders, 10, 200),
              sendToOdoo: _odoo,
              cloudUrl: _url.text.trim(),
              pairCode: _code.text.trim(),
            ),
          ),
          child: Text(tr(context, 'Start')),
        ),
      ],
    );
  }
}
