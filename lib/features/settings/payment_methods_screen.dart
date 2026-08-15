import 'package:flutter/material.dart';

import '../../core/db/settings_store.dart';
import '../../core/i18n/l10n.dart';
import '../../domain/catalogue.dart';

/// What each tender is called on the printed receipt.
///
/// The methods themselves come down from the server and are not editable here: a
/// method's id is what a sale books against and what every report counts, so this
/// screen changes one thing only, the words on the paper. A shop whose accounts call
/// it "Bank" can print "Visa / Mastercard" without anything downstream noticing.
///
/// Empty the box and the method's own name comes back, so an override is never a
/// one-way door.
class PaymentMethodsScreen extends StatefulWidget {
  const PaymentMethodsScreen({
    super.key,
    required this.settings,
    required this.methods,
    required this.onChanged,
  });

  final SettingsStore settings;

  /// The methods as synced from the server, in the order they are offered.
  final List<PaymentMethod> methods;

  /// Called after every change, so anything holding the receipt layout reloads.
  final VoidCallback onChanged;

  @override
  State<PaymentMethodsScreen> createState() => _PaymentMethodsScreenState();
}

class _PaymentMethodsScreenState extends State<PaymentMethodsScreen> {
  final Map<int, TextEditingController> _labels = {};

  @override
  void initState() {
    super.initState();
    final saved = widget.settings.paymentMethodLabels;
    for (final m in widget.methods) {
      _labels[m.id] = TextEditingController(text: saved[m.id] ?? '');
    }
  }

  @override
  void dispose() {
    for (final c in _labels.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _save() {
    for (final m in widget.methods) {
      widget.settings.setPaymentMethodLabel(m.id, _labels[m.id]?.text);
    }
    widget.onChanged();
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(tr(context, 'Saved'))));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(tr(context, 'Payment methods'))),
      body: widget.methods.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  tr(context,
                      'No payment methods yet. They arrive with the menu on the next sync.'),
                  key: const Key('no-payment-methods'),
                  textAlign: TextAlign.center,
                ),
              ),
            )
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text(
                  tr(context,
                      'Only the wording on the receipt changes. Sales and reports keep the method as it is.'),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
                for (final m in widget.methods)
                  Card(
                    key: Key('payment-method-${m.id}'),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(children: [
                            Icon(m.isCash ? Icons.payments : Icons.credit_card,
                                size: 18),
                            const SizedBox(width: 8),
                            Text(m.name,
                                style: const TextStyle(fontWeight: FontWeight.w600)),
                          ]),
                          const SizedBox(height: 8),
                          TextField(
                            key: Key('payment-label-${m.id}'),
                            controller: _labels[m.id],
                            decoration: InputDecoration(
                              labelText: tr(context, 'Printed name'),
                              hintText: m.name,
                              border: const OutlineInputBorder(),
                              isDense: true,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
      bottomNavigationBar: widget.methods.isEmpty
          ? null
          : Padding(
              padding: const EdgeInsets.all(16),
              child: FilledButton(
                key: const Key('save-payment-labels'),
                onPressed: _save,
                child: Text(tr(context, 'Save')),
              ),
            ),
    );
  }
}
