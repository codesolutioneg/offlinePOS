import 'package:flutter/material.dart';

import '../../core/db/settings_store.dart';
import '../../core/i18n/l10n.dart';
import '../../domain/catalogue.dart';

/// What each tender is called on the printed receipt.
///
/// The tenders themselves come down from the server and are not editable here: they
/// are the shop's own bank and cash journals, which is where the money lands and
/// what every report counts, so this screen changes one thing only, the words on the
/// paper. A shop whose accounts call a journal "Bank" can print "Visa / Mastercard"
/// without anything downstream noticing.
///
/// Empty the box and the journal's own name comes back, so an override is never a
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

  /// Whether each method is offered on the till's payment sheet.
  final Map<int, bool> _offered = {};

  /// The method an on-account sale books against, or null for off.
  int? _payLater;

  @override
  void initState() {
    super.initState();
    final saved = widget.settings.paymentMethodLabels;
    _payLater = widget.settings.payLaterMethodId;
    for (final m in widget.methods) {
      _labels[m.id] = TextEditingController(text: saved[m.id] ?? '');
      _offered[m.id] = widget.settings.isPaymentMethodOffered(m.id);
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
      widget.settings.setPaymentMethodOffered(m.id, _offered[m.id] ?? true);
    }
    widget.settings.payLaterMethodId = _payLater;
    widget.onChanged();
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(tr(context, 'Saved'))));
  }

  /// Where a tender's money ends up, in one line under its name.
  ///
  /// A tender left on this till from before it offered journals can be a method Odoo
  /// holds no journal against, which is its pay-later tender. It is named as that
  /// rather than as a gap: the shop settles it on account, so it was offered on
  /// purpose and not by oversight.
  String _booksTo(PaymentMethod m) {
    if (m.isPayLater) return tr(context, 'No journal, so this is pay later');
    final name = m.journalName;
    // The journal id with no name is a server that gave up the method but not the
    // journal behind it. Saying which one it is still beats saying nothing.
    if (name == null) return '${tr(context, 'Journal')} ${m.journalId}';
    final kind = switch (m.journalType) {
      'bank' => tr(context, 'Bank'),
      'cash' => tr(context, 'Cash'),
      _ => m.journalType ?? '',
    };
    return '${tr(context, 'Books to')} $name ($kind)';
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
                      'No payment methods yet. The shop\'s bank and cash journals arrive with the menu on the next sync.'),
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
                      'Only the wording on the receipt changes. Sales and reports keep the journal as it is.'),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
                // Which tender carries a sale a customer settles later. Only
                // non-cash methods are offered: booking a tab as cash would count
                // the drawer short by the amount nobody handed over.
                DropdownButtonFormField<int?>(
                  key: const Key('pay-later-method'),
                  initialValue: _payLater,
                  decoration: InputDecoration(
                    labelText: tr(context, 'Pay later books against'),
                    helperText: tr(context,
                        'An on-account sale needs a customer, and shows in the receivables report'),
                    helperMaxLines: 3,
                    border: const OutlineInputBorder(),
                    isDense: true,
                  ),
                  items: [
                    DropdownMenuItem<int?>(
                      value: null,
                      child: Text(tr(context, 'Off')),
                    ),
                    for (final m in widget.methods.where((m) => !m.isCash))
                      DropdownMenuItem<int?>(value: m.id, child: Text(m.name)),
                  ],
                  onChanged: (v) => setState(() => _payLater = v),
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
                            Expanded(
                              child: Text(m.name,
                                  style: const TextStyle(fontWeight: FontWeight.w600)),
                            ),
                            // Offered at the till or not. A method turned off is
                            // hidden from the payment sheet but untouched in reports.
                            Switch(
                              key: Key('payment-offered-${m.id}'),
                              value: _offered[m.id] ?? true,
                              onChanged: (v) => setState(() => _offered[m.id] = v),
                            ),
                          ]),
                          // What this tender books to, so a manager can see that
                          // the card method lands in the bank and not the drawer.
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(
                              _booksTo(m),
                              key: Key('payment-journal-${m.id}'),
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ),
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
