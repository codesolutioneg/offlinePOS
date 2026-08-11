import 'package:flutter/material.dart';

import '../../core/db/customer_store.dart';
import '../../core/i18n/l10n.dart';
import '../../domain/catalogue.dart';

/// Add and look up customers captured directly on the till: walk-ins, delivery
/// addresses, and regulars who are not in the Odoo partner list.
///
/// These live in [CustomerStore], a purely local table kept separate from the
/// read-only partners synced down from Odoo, so a cashier can register someone
/// on the spot without waiting on a catalogue sync to bring them back down.
///
/// Editing and removing an existing local customer are deliberately left out of
/// this first pass: [CustomerStore.search] only returns a synthetic negative int
/// id, never the local string id an update or delete call needs, and there is
/// no listing API to recover it from the visible row either. Capturing a new
/// customer and finding them again by name or phone is the need this screen
/// fills today; edit/delete need a store change to expose the string id first.
class CustomerManagementScreen extends StatefulWidget {
  const CustomerManagementScreen({super.key, required this.store, required this.onChanged});

  final CustomerStore store;

  /// Called after a customer is added so the caller can refresh whatever list
  /// or picker it is holding of local customers.
  final VoidCallback onChanged;

  @override
  State<CustomerManagementScreen> createState() => _CustomerManagementScreenState();
}

class _CustomerManagementScreenState extends State<CustomerManagementScreen> {
  late final TextEditingController _search = TextEditingController();

  // Lazy: reads widget.store, so it must not be evaluated before the framework
  // attaches the widget to this State. First access happens in build(), by
  // which point that has already happened.
  late List<Customer> _results = widget.store.search();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _runSearch(String query) {
    setState(() => _results = widget.store.search(query: query));
  }

  Future<void> _openAddDialog() async {
    final result = await showDialog<_CustomerFormResult>(
      context: context,
      builder: (_) => const _CustomerFormDialog(),
    );
    if (result == null) return;
    widget.store.add(name: result.name, phone: result.phone, address: result.address);
    widget.onChanged();
    if (!mounted) return;
    _runSearch(_search.text);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(tr(context, 'Customers'))),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              key: const Key('customer-search'),
              controller: _search,
              decoration: InputDecoration(
                labelText: tr(context, 'Search'),
                prefixIcon: const Icon(Icons.search),
                border: const OutlineInputBorder(),
                isDense: true,
              ),
              onChanged: _runSearch,
            ),
          ),
          Expanded(
            child: _results.isEmpty
                ? Center(
                    child: Text(tr(context, 'No customers'), key: const Key('no-customers')),
                  )
                : ListView.builder(
                    itemCount: _results.length,
                    itemBuilder: (context, index) {
                      final c = _results[index];
                      final phone = c.phone;
                      return ListTile(
                        key: Key('cust-${c.id}'),
                        leading: const Icon(Icons.person_outline),
                        title: Text(c.name),
                        subtitle: phone == null || phone.isEmpty ? null : Text(phone),
                      );
                    },
                  ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        key: const Key('add-customer'),
        onPressed: _openAddDialog,
        tooltip: tr(context, 'Add customer'),
        child: const Icon(Icons.person_add),
      ),
    );
  }
}

class _CustomerFormResult {
  const _CustomerFormResult({required this.name, this.phone, this.address});
  final String name;
  final String? phone;
  final String? address;
}

/// The add form. Name is the only required field: phone and address matter for
/// a delivery order later, but a walk-in customer's name may be all the cashier
/// has right now, so those two must not block saving.
class _CustomerFormDialog extends StatefulWidget {
  const _CustomerFormDialog();

  @override
  State<_CustomerFormDialog> createState() => _CustomerFormDialogState();
}

class _CustomerFormDialogState extends State<_CustomerFormDialog> {
  late final TextEditingController _name = TextEditingController();
  late final TextEditingController _phone = TextEditingController();
  late final TextEditingController _address = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    _address.dispose();
    super.dispose();
  }

  void _save() {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = tr(context, 'Name is required'));
      return;
    }
    final phone = _phone.text.trim();
    final address = _address.text.trim();
    Navigator.of(context).pop(_CustomerFormResult(
      name: name,
      phone: phone.isEmpty ? null : phone,
      address: address.isEmpty ? null : address,
    ));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(tr(context, 'Add customer')),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              key: const Key('cust-name'),
              controller: _name,
              decoration: InputDecoration(labelText: tr(context, 'Name')),
              textCapitalization: TextCapitalization.words,
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('cust-phone'),
              controller: _phone,
              keyboardType: TextInputType.phone,
              decoration: InputDecoration(labelText: tr(context, 'Phone')),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('cust-address'),
              controller: _address,
              minLines: 1,
              maxLines: 3,
              decoration: InputDecoration(labelText: tr(context, 'Address')),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  _error!,
                  key: const Key('customer-form-error'),
                  style: const TextStyle(color: Colors.red),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const Key('customer-form-cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: Text(tr(context, 'Cancel')),
        ),
        FilledButton(
          key: const Key('customer-form-save'),
          onPressed: _save,
          child: Text(tr(context, 'Save')),
        ),
      ],
    );
  }
}
