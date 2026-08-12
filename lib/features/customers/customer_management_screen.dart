import 'package:flutter/material.dart';

import '../../core/db/customer_store.dart';
import '../../core/i18n/l10n.dart';
import '../../domain/catalogue.dart';

/// Add, look up, correct and remove customers captured directly on the till:
/// walk-ins, delivery addresses, and regulars who are not in the Odoo partner list.
///
/// These live in [CustomerStore], a purely local table kept separate from the
/// read-only partners synced down from Odoo, so a cashier can register someone
/// on the spot without waiting on a catalogue sync to bring them back down.
///
/// The list is built from [CustomerStore.rows] rather than [CustomerStore.search]
/// because a row needs the local string id an update or delete takes, plus the
/// address, and neither survives the conversion to [Customer].
class CustomerManagementScreen extends StatefulWidget {
  const CustomerManagementScreen({super.key, required this.store, required this.onChanged});

  final CustomerStore store;

  /// Called after a customer is added, changed or removed so the caller can
  /// refresh whatever list or picker it is holding of local customers.
  final VoidCallback onChanged;

  @override
  State<CustomerManagementScreen> createState() => _CustomerManagementScreenState();
}

class _CustomerManagementScreenState extends State<CustomerManagementScreen> {
  late final TextEditingController _search = TextEditingController();

  // Lazy: reads widget.store, so it must not be evaluated before the framework
  // attaches the widget to this State. First access happens in build(), by
  // which point that has already happened.
  late List<Map<String, Object?>> _results = widget.store.rows();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _runSearch(String query) {
    setState(() => _results = widget.store.rows(query: query));
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

  /// Correct an existing customer through the same form the add flow uses, so the
  /// two cannot drift apart in validation or fields.
  Future<void> _openEditDialog(Map<String, Object?> row) async {
    final result = await showDialog<_CustomerFormResult>(
      context: context,
      builder: (_) => _CustomerFormDialog(
        initial: _CustomerFormResult(
          name: row['name'] as String,
          phone: row['phone'] as String?,
          address: row['address'] as String?,
        ),
      ),
    );
    if (result == null) return;
    widget.store.update(row['id'] as String,
        name: result.name, phone: result.phone, address: result.address);
    widget.onChanged();
    if (!mounted) return;
    _runSearch(_search.text);
  }

  Future<void> _confirmDelete(Map<String, Object?> row) async {
    final name = row['name'] as String;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr(ctx, 'Delete customer?')),
        content: Text('$name\n'
            '${tr(ctx, 'Orders already taken keep the name they were booked with.')}'),
        actions: [
          TextButton(
            key: const Key('customer-delete-cancel'),
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(tr(ctx, 'Cancel')),
          ),
          FilledButton(
            key: const Key('customer-delete-confirm'),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr(ctx, 'Delete')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    widget.store.remove(row['id'] as String);
    widget.onChanged();
    if (!mounted) return;
    _runSearch(_search.text);
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(tr(context, 'Customer deleted'))));
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
                      final row = _results[index];
                      final id = row['id'] as String;
                      // Phone and address are both optional, so the subtitle shows
                      // whichever of them the cashier actually captured.
                      final details = [row['phone'] as String?, row['address'] as String?]
                          .whereType<String>()
                          .where((s) => s.isNotEmpty)
                          .join('\n');
                      return ListTile(
                        key: Key('cust-$id'),
                        leading: const Icon(Icons.person_outline),
                        title: Text(row['name'] as String),
                        subtitle: details.isEmpty ? null : Text(details),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              key: Key('cust-edit-$id'),
                              icon: const Icon(Icons.edit_outlined),
                              tooltip: tr(context, 'Edit customer'),
                              onPressed: () => _openEditDialog(row),
                            ),
                            IconButton(
                              key: Key('cust-delete-$id'),
                              icon: const Icon(Icons.delete_outline),
                              tooltip: tr(context, 'Delete customer'),
                              onPressed: () => _confirmDelete(row),
                            ),
                          ],
                        ),
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

/// The add and edit form. Name is the only required field: phone and address
/// matter for a delivery order later, but a walk-in customer's name may be all
/// the cashier has right now, so those two must not block saving.
class _CustomerFormDialog extends StatefulWidget {
  const _CustomerFormDialog({this.initial});

  /// The customer being corrected, prefilled into the fields. Null when adding.
  final _CustomerFormResult? initial;

  @override
  State<_CustomerFormDialog> createState() => _CustomerFormDialogState();
}

class _CustomerFormDialogState extends State<_CustomerFormDialog> {
  late final TextEditingController _name =
      TextEditingController(text: widget.initial?.name ?? '');
  late final TextEditingController _phone =
      TextEditingController(text: widget.initial?.phone ?? '');
  late final TextEditingController _address =
      TextEditingController(text: widget.initial?.address ?? '');
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
      title: Text(tr(context, widget.initial == null ? 'Add customer' : 'Edit customer')),
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
