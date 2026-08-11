import 'package:flutter/material.dart';

import '../../core/auth/auth_service.dart';
import '../../core/auth/user_store.dart';
import '../../core/i18n/l10n.dart';

/// Staff management: add a cashier, change their role, reset a PIN, or deactivate.
///
/// Before this screen existed there was no way to add staff on the till itself,
/// so every roster started (and stayed) empty until someone hand-wrote rows into
/// the database. This is the gap it fills, entirely on-device: [AuthService.enrol]
/// hashes the PIN locally and no PIN is ever shown back or logged.
class RosterScreen extends StatefulWidget {
  const RosterScreen({
    super.key,
    required this.users,
    required this.auth,
    required this.onChanged,
  });

  final UserStore users;
  final AuthService auth;

  /// Called after any change so the caller can refresh whatever list it is
  /// holding of the roster (this screen owns no state the caller can see).
  final VoidCallback onChanged;

  @override
  State<RosterScreen> createState() => _RosterScreenState();
}

class _RosterScreenState extends State<RosterScreen> {
  Future<void> _openAddDialog() async {
    final result = await showDialog<_StaffFormResult>(
      context: context,
      builder: (_) => const _StaffFormDialog(),
    );
    if (result == null) return;
    // The id is derived from the name rather than typed, so a cashier's login
    // key can never collide with a display-name change; the suffix keeps two
    // "Sara"s on the same till from colliding with each other.
    final slug = result.name
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    final id = '${slug.isEmpty ? 'staff' : slug}-'
        '${DateTime.now().microsecondsSinceEpoch}';
    await widget.auth.enrol(
      id: id,
      name: result.name.trim(),
      pin: result.pin,
      role: result.role,
    );
    widget.onChanged();
    if (!mounted) return;
    setState(() {});
  }

  Future<void> _openEditDialog(Cashier cashier) async {
    final result = await showDialog<_StaffFormResult>(
      context: context,
      builder: (_) => _StaffFormDialog(existing: cashier),
    );
    if (result == null) return;
    if (result.pin.isEmpty) {
      // No new PIN entered: keep the existing hash, just update name/role.
      widget.users.upsert(Cashier(
        id: cashier.id,
        name: result.name.trim(),
        role: result.role,
        pinSalt: cashier.pinSalt,
        pinHash: cashier.pinHash,
        active: cashier.active,
      ));
    } else {
      // A new PIN was entered: re-enrol under the same id so it re-hashes.
      await widget.auth.enrol(
        id: cashier.id,
        name: result.name.trim(),
        pin: result.pin,
        role: result.role,
      );
    }
    widget.onChanged();
    if (!mounted) return;
    setState(() {});
  }

  void _deactivate(Cashier cashier) {
    // A copy with active=false, keeping the existing salt/hash: deactivating
    // is not the same as forgetting the PIN, so re-activating later needs no
    // PIN reset.
    widget.users.upsert(Cashier(
      id: cashier.id,
      name: cashier.name,
      role: cashier.role,
      pinSalt: cashier.pinSalt,
      pinHash: cashier.pinHash,
      active: false,
    ));
    widget.onChanged();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final staff = widget.users.active();
    return Scaffold(
      appBar: AppBar(title: Text(tr(context, 'Staff'))),
      body: staff.isEmpty
          ? Center(
              child: Text(tr(context, 'No staff on this device yet'), key: const Key('no-staff')),
            )
          : ListView.builder(
              itemCount: staff.length,
              itemBuilder: (context, index) {
                final c = staff[index];
                return ListTile(
                  key: Key('staff-${c.id}'),
                  title: Text(c.name),
                  subtitle: Text(c.id),
                  trailing: Wrap(
                    spacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Chip(label: Text(c.isManager ? tr(context, 'Manager') : tr(context, 'Cashier'))),
                      IconButton(
                        key: Key('edit-${c.id}'),
                        icon: const Icon(Icons.edit),
                        tooltip: tr(context, 'Edit'),
                        onPressed: () => _openEditDialog(c),
                      ),
                      IconButton(
                        key: Key('deactivate-${c.id}'),
                        icon: const Icon(Icons.person_off),
                        tooltip: tr(context, 'Deactivate'),
                        onPressed: () => _deactivate(c),
                      ),
                    ],
                  ),
                );
              },
            ),
      floatingActionButton: FloatingActionButton(
        key: const Key('add-staff'),
        onPressed: _openAddDialog,
        tooltip: tr(context, 'Add staff'),
        child: const Icon(Icons.person_add),
      ),
    );
  }
}

class _StaffFormResult {
  const _StaffFormResult({required this.name, required this.role, required this.pin});
  final String name;
  final String role;
  final String pin;
}

/// Add or edit form. On edit, the PIN field is optional: leaving it blank keeps
/// the current PIN, so a manager is not forced to invent a new one just to fix
/// a typo in a name.
class _StaffFormDialog extends StatefulWidget {
  const _StaffFormDialog({this.existing});

  final Cashier? existing;

  @override
  State<_StaffFormDialog> createState() => _StaffFormDialogState();
}

class _StaffFormDialogState extends State<_StaffFormDialog> {
  late final TextEditingController _name;
  late final TextEditingController _pin;
  late String _role;
  String? _error;

  bool get _isEdit => widget.existing != null;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.existing?.name ?? '');
    _pin = TextEditingController();
    _role = widget.existing?.role ?? 'cashier';
  }

  @override
  void dispose() {
    _name.dispose();
    _pin.dispose();
    super.dispose();
  }

  void _save() {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = tr(context, 'Name is required'));
      return;
    }
    final pin = _pin.text;
    // On add a PIN is mandatory; on edit an empty PIN means "leave it as is".
    if (pin.isNotEmpty || !_isEdit) {
      final wellFormed = pin.length >= 4 && pin.length <= 6 && RegExp(r'^\d+$').hasMatch(pin);
      if (!wellFormed) {
        setState(() => _error = tr(context, 'PIN must be 4 to 6 digits'));
        return;
      }
    }
    Navigator.of(context).pop(_StaffFormResult(name: name, role: _role, pin: pin));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(_isEdit ? tr(context, 'Edit staff') : tr(context, 'Add staff')),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              key: const Key('staff-name'),
              controller: _name,
              decoration: InputDecoration(labelText: tr(context, 'Name')),
              textCapitalization: TextCapitalization.words,
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              key: const Key('staff-role'),
              initialValue: _role,
              decoration: InputDecoration(labelText: tr(context, 'Role')),
              items: [
                DropdownMenuItem(value: 'cashier', child: Text(tr(context, 'Cashier'))),
                DropdownMenuItem(value: 'manager', child: Text(tr(context, 'Manager'))),
              ],
              onChanged: (v) => setState(() => _role = v ?? _role),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('staff-pin'),
              controller: _pin,
              obscureText: true,
              keyboardType: TextInputType.number,
              maxLength: 6,
              decoration: InputDecoration(
                labelText: _isEdit ? tr(context, 'New PIN (leave blank to keep current)') : tr(context, 'PIN'),
                hintText: tr(context, '4 to 6 digits'),
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  _error!,
                  key: const Key('staff-form-error'),
                  style: const TextStyle(color: Colors.red),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const Key('staff-form-cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: Text(tr(context, 'Cancel')),
        ),
        FilledButton(
          key: const Key('staff-form-save'),
          onPressed: _save,
          child: Text(tr(context, 'Save')),
        ),
      ],
    );
  }
}
