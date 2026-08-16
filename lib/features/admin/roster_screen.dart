import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/auth/auth_service.dart';
import '../../core/auth/totp.dart';
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
    this.canAssignManager = true,
    this.roles = const ['cashier'],
  });

  final UserStore users;
  final AuthService auth;

  /// The roles this till offers, manager aside. Defaults to the one built-in role
  /// so a caller with no custom roles configured behaves exactly as before.
  final List<String> roles;

  /// Whether the person on this screen may create or touch manager accounts. A
  /// cashier who reaches the roster through the `manageStaff` permission must not
  /// be able to mint a manager (or reset a manager's PIN) and self-promote, so
  /// the caller passes false unless a real manager is signed in.
  final bool canAssignManager;

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
      builder: (_) => _StaffFormDialog(
          canAssignManager: widget.canAssignManager, roles: widget.roles),
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
      builder: (_) => _StaffFormDialog(
          existing: cashier,
          canAssignManager: widget.canAssignManager,
          roles: widget.roles),
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
        // Carried through every rewrite of the row: fixing a typo in a name must
        // not take a manager's second factor off.
        totpSecret: cashier.totpSecret,
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
      totpSecret: cashier.totpSecret,
    ));
    widget.onChanged();
    setState(() {});
  }

  /// Turn a manager's authenticator on (by taking the secret their app shows) or
  /// off. Kept out of the staff form so a PIN reset and a second factor stay two
  /// separate decisions.
  Future<void> _openTotpDialog(Cashier cashier) async {
    final result = await showDialog<String?>(
      context: context,
      builder: (_) => _TotpDialog(cashier: cashier),
    );
    // Null is a cancelled dialog; an empty string is "turn it off".
    if (result == null) return;
    widget.users.setTotpSecret(cashier.id, result.isEmpty ? null : result);
    widget.onChanged();
    if (!mounted) return;
    setState(() {});
  }

  bool _showInactive = false;

  void _reactivate(Cashier cashier) {
    // Restore access with the PIN intact; deactivation kept the hash for exactly
    // this, so no reset is needed.
    widget.users.upsert(Cashier(
      id: cashier.id,
      name: cashier.name,
      role: cashier.role,
      pinSalt: cashier.pinSalt,
      pinHash: cashier.pinHash,
      active: true,
      totpSecret: cashier.totpSecret,
    ));
    widget.onChanged();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final staff = _showInactive ? widget.users.all() : widget.users.active();
    return Scaffold(
      appBar: AppBar(
        title: Text(tr(context, 'Staff')),
        actions: [
          // A compact toggle rather than a label+switch, which can overflow the app
          // bar once the label is translated.
          IconButton(
            key: const Key('show-inactive'),
            tooltip: tr(context, 'Show inactive'),
            isSelected: _showInactive,
            icon: const Icon(Icons.visibility_off_outlined),
            selectedIcon: const Icon(Icons.visibility),
            onPressed: () => setState(() => _showInactive = !_showInactive),
          ),
        ],
      ),
      body: staff.isEmpty
          ? Center(
              child: Text(tr(context, 'No staff on this device yet'), key: const Key('no-staff')),
            )
          : ListView.builder(
              itemCount: staff.length,
              itemBuilder: (context, index) {
                final c = staff[index];
                // A non-manager may see manager rows but not touch them: editing one
                // resets its PIN, which would be a self-promotion path.
                final locked = c.isManager && !widget.canAssignManager;
                return ListTile(
                  key: Key('staff-${c.id}'),
                  title: Text(c.name, overflow: TextOverflow.ellipsis),
                  subtitle: Text([
                    roleLabel(context, c.role),
                    if (!c.active) tr(context, 'inactive'),
                    if (c.hasSecondFactor) tr(context, 'authenticator on'),
                  ].join(' · ')),
                  // Actions live in an overflow menu so a long name can never push
                  // buttons off the row.
                  trailing: locked
                      ? const Icon(Icons.lock_outline)
                      : PopupMenuButton<String>(
                          key: Key('staff-menu-${c.id}'),
                          onSelected: (v) {
                            if (v == 'edit') _openEditDialog(c);
                            if (v == 'totp') _openTotpDialog(c);
                            if (v == 'deactivate') _deactivate(c);
                            if (v == 'reactivate') _reactivate(c);
                          },
                          itemBuilder: (_) => [
                            PopupMenuItem(
                                key: Key('edit-${c.id}'), value: 'edit', child: Text(tr(context, 'Edit'))),
                            // Only managers approve things, so only a manager's
                            // second factor is ever asked for.
                            if (c.isManager)
                              PopupMenuItem(
                                  key: Key('totp-${c.id}'),
                                  value: 'totp',
                                  child: Text(tr(context, 'Authenticator'))),
                            if (c.active)
                              PopupMenuItem(
                                  key: Key('deactivate-${c.id}'),
                                  value: 'deactivate',
                                  child: Text(tr(context, 'Deactivate')))
                            else
                              PopupMenuItem(
                                  key: Key('reactivate-${c.id}'),
                                  value: 'reactivate',
                                  child: Text(tr(context, 'Reactivate'))),
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

/// What a role is called on screen. The two built-in names are translated; a role
/// the shop invented is shown exactly as it was typed, because nobody has
/// translated "Head waiter" and inventing an Arabic form for it would be a guess.
String roleLabel(BuildContext context, String role) => switch (role) {
      'manager' => tr(context, 'Manager'),
      'cashier' => tr(context, 'Cashier'),
      _ => role,
    };
/// Enrol (or drop) a manager's authenticator.
///
/// The secret is typed in from whatever the app on their phone shows; the current
/// code is echoed back live so the two sides can be proven to agree before the
/// dialog is saved, which is the only way to find a mistyped secret before it locks
/// somebody out of approving a void mid-service. Nothing here goes near a network:
/// the code is the clock and the secret, both on this device.
///
/// Pops null when nothing should change, an empty string to turn the factor off,
/// and the normalised secret to turn it on.
class _TotpDialog extends StatefulWidget {
  const _TotpDialog({required this.cashier});

  final Cashier cashier;

  @override
  State<_TotpDialog> createState() => _TotpDialogState();
}

class _TotpDialogState extends State<_TotpDialog> {
  final TextEditingController _secret = TextEditingController();
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    // Keeps the echoed code honest as the 30-second window rolls over.
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    _secret.dispose();
    super.dispose();
  }

  /// The typed secret in stored form, or null while it is not usable yet.
  String? get _normalised => Totp.normaliseSecret(_secret.text);

  @override
  Widget build(BuildContext context) {
    final ready = _normalised;
    return AlertDialog(
      title: Text(tr(context, 'Authenticator')),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(
            widget.cashier.hasSecondFactor
                ? tr(context, 'This manager is asked for a code when they approve.')
                : tr(context, 'This manager approves with their PIN alone.'),
            key: const Key('totp-state'),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('totp-secret'),
            controller: _secret,
            autofocus: true,
            decoration: InputDecoration(
              labelText: tr(context, 'Secret from the authenticator app'),
              helperText: tr(context, 'Letters A-Z and digits 2-7'),
              border: const OutlineInputBorder(),
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 10),
          if (_secret.text.trim().isNotEmpty)
            Text(
              ready == null
                  ? tr(context, 'That is not a usable secret yet.')
                  : '${tr(context, 'Code right now')}: ${Totp.codeAt(ready, DateTime.now())}',
              key: const Key('totp-preview'),
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
        ]),
      ),
      actions: [
        TextButton(
          key: const Key('totp-cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: Text(tr(context, 'Cancel')),
        ),
        if (widget.cashier.hasSecondFactor)
          TextButton(
            key: const Key('totp-off'),
            onPressed: () => Navigator.of(context).pop(''),
            child: Text(tr(context, 'Turn off')),
          ),
        FilledButton(
          key: const Key('totp-save'),
          onPressed: ready == null ? null : () => Navigator.of(context).pop(ready),
          child: Text(tr(context, 'Save')),
        ),
      ],
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
  const _StaffFormDialog({
    this.existing,
    this.canAssignManager = true,
    this.roles = const ['cashier'],
  });

  final Cashier? existing;
  final bool canAssignManager;
  final List<String> roles;

  @override
  State<_StaffFormDialog> createState() => _StaffFormDialogState();
}

class _StaffFormDialogState extends State<_StaffFormDialog> {
  late final TextEditingController _name;
  late final TextEditingController _pin;
  late String _role;
  String? _error;

  bool get _isEdit => widget.existing != null;

  /// The non-manager roles to offer. Always includes whatever role this person is
  /// already on, even one that has since been deleted: a dropdown whose value is
  /// not among its items asserts, and the edit form would be unopenable.
  List<String> get _offered {
    final offered = widget.roles.isEmpty ? ['cashier'] : [...widget.roles];
    final current = widget.existing?.role;
    if (current != null && current != 'manager' && !offered.contains(current)) {
      offered.add(current);
    }
    return offered;
  }

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
    // Belt-and-braces: even if the manager option were somehow selected, a caller
    // without the right may never save a manager account.
    final role = (!widget.canAssignManager && _role == 'manager') ? 'cashier' : _role;
    Navigator.of(context).pop(_StaffFormResult(name: name, role: role, pin: pin));
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
                for (final r in _offered)
                  DropdownMenuItem(
                      key: Key('role-option-$r'),
                      value: r,
                      child: Text(roleLabel(context, r))),
                // Only an actual manager can hand out the manager role.
                if (widget.canAssignManager)
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
