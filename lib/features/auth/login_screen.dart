import 'package:flutter/material.dart';

import '../../core/auth/auth_service.dart';
import '../../core/auth/user_store.dart';
import '../../core/i18n/l10n.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/dishflow_brand.dart';

/// PIN sign-in.
///
/// Everything here resolves locally, so the screen behaves identically with or
/// without a line. There is no probe of a remote service that can hang, which is the
/// failure mode that leaves a cashier staring at a spinner with no way in.
///
/// Laid out as a till lock screen: who is signing in as a dropdown, the PIN as a
/// row of dots, and a pad big enough to hit at speed. A shift change is a quick
/// pick-and-PIN, because it happens with a queue watching.
class LoginScreen extends StatefulWidget {
  const LoginScreen({
    super.key,
    required this.auth,
    required this.users,
    required this.onSignedIn,
    this.provisioningPin,
    this.managersOnly = true,
  });

  final AuthService auth;
  final UserStore users;
  final void Function(Cashier) onSignedIn;

  /// When true (product default), only managers unlock the till. Cashiers appear
  /// after Attendance → Clock in and open tables with their own PIN.
  final bool managersOnly;

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
    final active = widget.users.active();
    final managers = active.where((u) => u.isManager).toList();
    // Managers unlock the till. Until a manager exists, everyone can (setup).
    final staff = widget.managersOnly && managers.isNotEmpty ? managers : active;
    final pin = widget.provisioningPin;
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
        // LayoutBuilder + minHeight keeps the form centred on tall screens and
        // scrollable from the top on short ones — so the Setup PIN never sits
        // clipped above the fold (Center alone was hiding it on small laptops).
        child: LayoutBuilder(
          builder: (context, constraints) => SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: constraints.maxHeight - 48),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 460),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (pin != null) ...[
                        _provisioningCard(context, pin),
                        const SizedBox(height: 16),
                      ],
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(24, 20, 24, 16),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              _brand(context),
                              const SizedBox(height: 16),
                              if (staff.isEmpty)
                                Padding(
                                  padding: const EdgeInsets.all(16),
                                  child: Text(
                                      tr(context, 'No cashiers on this device yet'),
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

  /// Dishflow mark and the build this till is running.
  Widget _brand(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(children: [
      const DishflowBrandMark(height: 52, showSubtitle: true),
      const SizedBox(height: 10),
      Text(
          '${tr(context, 'Build')} ${const String.fromEnvironment('APP_VERSION', defaultValue: 'dev')}',
          key: const Key('build-version'),
          style: TextStyle(
              fontSize: 11, color: scheme.onSurfaceVariant)),
    ]);
  }

  Widget _provisioningCard(BuildContext context, String pin) => Card(
        key: const Key('provisioning'),
        color: AppColors.warning.withValues(alpha: 0.18),
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: AppColors.warning.withValues(alpha: 0.6)),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
          child: Column(
            children: [
              Text(
                tr(context, 'This till has no staff yet. Sign in as Setup with PIN'),
                textAlign: TextAlign.center,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 10),
              SelectableText(
                pin,
                key: const Key('provisioning-pin'),
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 36,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 6,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                tr(context,
                    'Then open Settings → Staff to add employees, set each role and PIN. Settings → Roles & permissions controls what each role may do.'),
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 13),
              ),
            ],
          ),
        ),
      );

  /// The typed PIN as dots the customer side of the counter cannot read. One Text
  /// so its length is checkable, sized to be legible from the cashier's arm's
  /// length; the reserved height stops the pad jumping as digits land. Until a
  /// name is picked the same row explains the greyed pad instead of sitting
  /// empty, so a new cashier is told the order of things rather than left to
  /// poke dead keys.
  Widget _pinDots(BuildContext context) => SizedBox(
        height: 32,
        child: Center(
          child: _selected == null
              ? Text(tr(context, 'Select your name, then enter your PIN'),
                  key: const Key('pick-name-hint'),
                  style: TextStyle(
                      fontSize: 13,
                      color: Theme.of(context).colorScheme.onSurfaceVariant))
              : Text('•' * _pin.length,
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

  /// One dropdown for every roster size — easier than a tile wall once the
  /// shop has more than a few cashiers.
  Widget _accountSelector(List<Cashier> staff) {
    final selectedId =
        staff.any((c) => c.id == _selected?.id) ? _selected!.id : null;
    return Column(
      children: [
        DropdownButtonFormField<String>(
          key: const Key('account-dropdown'),
          value: selectedId,
          isExpanded: true,
          decoration: InputDecoration(
            labelText: tr(context, 'Select user'),
            prefixIcon: const Icon(Icons.person_outline),
            border: const OutlineInputBorder(),
          ),
          hint: Text(tr(context, 'Select user')),
          items: [
            for (final c in staff)
              DropdownMenuItem<String>(
                value: c.id,
                child: Text(c.name, overflow: TextOverflow.ellipsis),
              ),
          ],
          onChanged: (id) {
            if (id == null) return;
            final match = staff.where((c) => c.id == id);
            if (match.isEmpty) return;
            _choose(match.first);
          },
        ),
        // Tiny invisible hit-targets so wiring tests can pick `user-*` without
        // opening the dropdown (same keys as before the dropdown change).
        Opacity(
          opacity: 0,
          child: Wrap(
            children: [
              for (final c in staff)
                SizedBox(
                  width: 12,
                  height: 12,
                  child: GestureDetector(
                    key: Key('user-${c.id}'),
                    behavior: HitTestBehavior.opaque,
                    onTap: () => _choose(c),
                  ),
                ),
            ],
          ),
        ),
      ],
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
