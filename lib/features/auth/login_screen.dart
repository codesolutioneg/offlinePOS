import 'package:flutter/material.dart';

import '../../core/auth/auth_service.dart';
import '../../core/auth/user_store.dart';
import '../../core/i18n/l10n.dart';
import '../../core/theme/app_colors.dart';

/// PIN sign-in.
///
/// Everything here resolves locally, so the screen behaves identically with or
/// without a line. There is no probe of a remote service that can hang, which is the
/// failure mode that leaves a cashier staring at a spinner with no way in.
///
/// Laid out as a till lock screen: who is signing in as one row of face tiles, the
/// PIN as a row of dots, and a pad big enough to hit at speed. A shift change is a
/// two-tap, one-glance affair, because it happens with a queue watching.
class LoginScreen extends StatefulWidget {
  const LoginScreen({
    super.key,
    required this.auth,
    required this.users,
    required this.onSignedIn,
    this.provisioningPin,
  });

  final AuthService auth;
  final UserStore users;
  final void Function(Cashier) onSignedIn;

  /// The one-time PIN for the setup account, when this till has no real roster
  /// yet. Shown here because there is nowhere else to show it and no shipped
  /// credential to fall back on; see `BootstrapCashier`.
  final String? provisioningPin;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  Cashier? _selected;
  String _pin = '';
  String? _message;
  bool _busy = false;

  Future<void> _submit() async {
    final who = _selected;
    if (who == null || _busy) return;
    setState(() => _busy = true);
    final result = await widget.auth.unlock(who.id, _pin);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _pin = '';
      _message = switch (result) {
        AuthOk() => null,
        AuthRejected() => tr(context, 'Incorrect PIN'),
        AuthMalformed() => tr(context, 'PIN must be 4 to 6 digits'),
        // Say it is a lockout, not a wrong PIN, or the cashier keeps trying. The
        // wait doubles with each further failure, so it is quoted rather than
        // described as "a few minutes".
        AuthLockedOut(:final until) =>
          '${tr(context, 'Too many attempts. Try again in')} ${_wait(until)}.',
      };
    });
    if (result is AuthOk) widget.onSignedIn(result.cashier);
  }

  static String _wait(DateTime until) {
    final left = until.difference(DateTime.now());
    if (left.inMinutes < 1) return '${left.inSeconds.clamp(1, 59)} seconds';
    if (left.inHours < 1) return '${left.inMinutes + 1} minutes';
    return '${left.inHours + 1} hours';
  }

  void _press(String d) {
    if (_pin.length >= 6) return;
    setState(() {
      _pin += d;
      _message = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final staff = widget.users.active();
    return Scaffold(
      // A quiet wash of the brand colour behind the card, so the lock screen is
      // recognisably the till from across the counter without shouting.
      body: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              scheme.primaryContainer.withValues(alpha: 0.35),
              scheme.surface,
              scheme.surface,
            ],
          ),
        ),
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(24, 20, 24, 16),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _brand(context),
                      const SizedBox(height: 16),
                      if (widget.provisioningPin != null) ...[
                        _provisioningCard(context),
                        const SizedBox(height: 8),
                      ],
                      if (staff.isEmpty)
                        Padding(
                          padding: const EdgeInsets.all(16),
                          child: Text(tr(context, 'No cashiers on this device yet'),
                              key: const Key('no-users')),
                        )
                      else ...[
                        _accountSelector(staff),
                        const SizedBox(height: 12),
                        _pinDots(context),
                        if (_message != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: Text(_message!,
                                key: const Key('login-message'),
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                    color: scheme.error,
                                    fontWeight: FontWeight.w600)),
                          ),
                        const SizedBox(height: 10),
                        _keypad(),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// The shop's mark and the build it is running, in one glance.
  Widget _brand(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(children: [
      Container(
        width: 48,
        height: 48,
        decoration: BoxDecoration(
          color: scheme.primary,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Icon(Icons.storefront, size: 26, color: scheme.onPrimary),
      ),
      const SizedBox(height: 8),
      Text(tr(context, 'offlinePOS'),
          style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
      Text(
          '${tr(context, 'Build')} ${const String.fromEnvironment('APP_VERSION', defaultValue: 'dev')}',
          key: const Key('build-version'),
          style: TextStyle(
              fontSize: 11, color: scheme.onSurfaceVariant)),
    ]);
  }

  Widget _provisioningCard(BuildContext context) => Card(
        key: const Key('provisioning'),
        color: AppColors.warning.withValues(alpha: 0.15),
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: AppColors.warning.withValues(alpha: 0.5)),
        ),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Text(
            '${tr(context, 'This till has no staff yet. Sign in as Setup with PIN')} '
            '${widget.provisioningPin}'
            '${tr(context, ', then enrol the real roster. This code is new on every launch and stops appearing once staff are enrolled.')}',
            textAlign: TextAlign.center,
          ),
        ),
      );

  /// The typed PIN as dots the customer side of the counter cannot read. One Text
  /// so its length is checkable, sized to be legible from the cashier's arm's
  /// length; the reserved height stops the pad jumping as digits land.
  Widget _pinDots(BuildContext context) => SizedBox(
        height: 32,
        child: Center(
          child: Text('•' * _pin.length,
              key: const Key('pin-dots'),
              style: TextStyle(
                  fontSize: 26,
                  letterSpacing: 8,
                  color: Theme.of(context).colorScheme.primary)),
        ),
      );

  void _choose(Cashier c) => setState(() {
        _selected = c;
        _pin = '';
        _message = null;
      });

  /// Above this many accounts the tile wall stops being scannable, so switch to a
  /// type-to-search field. A small shop keeps the one-tap tiles.
  static const _chipLimit = 6;

  /// A stable colour per cashier so a face tile is found by colour before it is
  /// read, shift after shift.
  static Color _staffColor(String id) => AppColors.categoryColor(id.hashCode);

  static String _initials(String name) {
    final parts = name.trim().split(RegExp(r'\s+'));
    if (parts.isEmpty || parts.first.isEmpty) return '?';
    final first = parts.first.characters.first.toUpperCase();
    if (parts.length == 1) return first;
    return first + parts.last.characters.first.toUpperCase();
  }

  /// Pick who is signing in. Face tiles for a small roster (fast, no typing); a
  /// searchable field once there are enough accounts that tiles would wrap into an
  /// unscannable wall, so a 15-strong roster is a name away instead of a hunt.
  Widget _accountSelector(List<Cashier> staff) {
    if (staff.length <= _chipLimit) {
      return Wrap(
        spacing: 10,
        runSpacing: 10,
        alignment: WrapAlignment.center,
        children: [for (final c in staff) _staffTile(c)],
      );
    }
    return Column(
      children: [
        Autocomplete<Cashier>(
          displayStringForOption: (c) => c.name,
          optionsBuilder: (value) {
            final q = value.text.trim().toLowerCase();
            // Empty query lists everyone, so the field doubles as a full account
            // list you can scroll, not only a search.
            if (q.isEmpty) return staff;
            return staff.where((c) => c.name.toLowerCase().contains(q));
          },
          onSelected: _choose,
          fieldViewBuilder: (context, controller, focusNode, onSubmit) => TextField(
            key: const Key('account-search'),
            controller: controller,
            focusNode: focusNode,
            textCapitalization: TextCapitalization.words,
            // Editing the name after choosing someone drops the selection, so the
            // keypad can never send a PIN to the previously picked account on a
            // shared till. Re-picking a suggestion sets it again.
            onChanged: (text) {
              if (_selected != null && text != _selected!.name) {
                setState(() {
                  _selected = null;
                  _pin = '';
                  _message = null;
                });
              }
            },
            decoration: InputDecoration(
              labelText: tr(context, 'Search your name'),
              prefixIcon: const Icon(Icons.search),
              border: const OutlineInputBorder(),
            ),
          ),
        ),
        if (_selected != null)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Text('${tr(context, 'Signing in as')}: ${_selected!.name}',
                key: const Key('signing-in-as'),
                style: const TextStyle(fontWeight: FontWeight.bold)),
          ),
      ],
    );
  }

  /// One cashier as a tile: their colour, their initials, their name, and a ring
  /// when they are the one signing in.
  Widget _staffTile(Cashier c) {
    final scheme = Theme.of(context).colorScheme;
    final selected = _selected?.id == c.id;
    final color = _staffColor(c.id);
    return InkWell(
      key: Key('user-${c.id}'),
      borderRadius: BorderRadius.circular(14),
      onTap: () => _choose(c),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        width: 86,
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
        decoration: BoxDecoration(
          color: selected
              ? scheme.primary.withValues(alpha: 0.10)
              : scheme.surfaceContainerHighest.withValues(alpha: 0.4),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: selected ? scheme.primary : Colors.transparent,
            width: 2,
          ),
        ),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          CircleAvatar(
            radius: 18,
            backgroundColor: color.withValues(alpha: 0.2),
            child: Text(_initials(c.name),
                style: TextStyle(
                    color: color, fontWeight: FontWeight.w800, fontSize: 14)),
          ),
          const SizedBox(height: 5),
          Text(c.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500)),
        ]),
      ),
    );
  }

  Widget _keypad() => SizedBox(
        width: 300,
        child: GridView.count(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          crossAxisCount: 3,
          childAspectRatio: 1.7,
          mainAxisSpacing: 8,
          crossAxisSpacing: 8,
          children: [
            for (final d in ['1', '2', '3', '4', '5', '6', '7', '8', '9'])
              _key(d, () => _press(d)),
            _key('⌫', () => setState(() {
                  if (_pin.isNotEmpty) _pin = _pin.substring(0, _pin.length - 1);
                })),
            _key('0', () => _press('0')),
            FilledButton(
              key: const Key('pin-ok'),
              style: FilledButton.styleFrom(
                  textStyle:
                      const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
              onPressed: _selected == null || _busy ? null : _submit,
              child: Text(tr(context, 'OK')),
            ),
          ],
        ),
      );

  /// One pad key. Digits sit on a quiet surface; the delete key reads in the
  /// danger colour so it is found without looking.
  Widget _key(String label, VoidCallback onTap) {
    final scheme = Theme.of(context).colorScheme;
    final enabled = _selected != null;
    final isDelete = label == '⌫';
    return Material(
      color: isDelete
          ? AppColors.error.withValues(alpha: enabled ? 0.10 : 0.05)
          : scheme.surfaceContainerHighest.withValues(alpha: enabled ? 0.6 : 0.3),
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        key: Key('key-$label'),
        borderRadius: BorderRadius.circular(14),
        onTap: enabled ? onTap : null,
        child: Center(
          child: isDelete
              ? Icon(Icons.backspace_outlined,
                  color: AppColors.error.withValues(alpha: enabled ? 1 : 0.4))
              : Text(label,
                  style: TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.w600,
                      color: enabled
                          ? scheme.onSurface
                          : scheme.onSurface.withValues(alpha: 0.35))),
        ),
      ),
    );
  }
}
