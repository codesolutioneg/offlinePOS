import 'package:flutter/material.dart';

import '../../core/auth/auth_service.dart';
import '../../core/auth/user_store.dart';
import '../../core/i18n/l10n.dart';

/// PIN sign-in.
///
/// Everything here resolves locally, so the screen behaves identically with or
/// without a line. There is no probe of a remote service that can hang, which is the
/// failure mode that leaves a cashier staring at a spinner with no way in.
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
    final staff = widget.users.active();
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(tr(context, 'offlinePOS'),
                  style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold)),
              Text('${tr(context, 'Build')} ${const String.fromEnvironment('APP_VERSION', defaultValue: 'dev')}',
                  key: const Key('build-version'),
                  style: const TextStyle(fontSize: 11, color: Colors.black45)),
              const SizedBox(height: 24),
              if (widget.provisioningPin != null)
                Card(
                  key: const Key('provisioning'),
                  color: Colors.amber.shade100,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(
                      '${tr(context, 'This till has no staff yet. Sign in as Setup with PIN')} '
                      '${widget.provisioningPin}'
                      '${tr(context, ', then enrol the real roster. This code is new on every launch and stops appearing once staff are enrolled.')}',
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
              if (staff.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(tr(context, 'No cashiers on this device yet'),
                      key: const Key('no-users')),
                )
              else ...[
                Wrap(
                  spacing: 8,
                  alignment: WrapAlignment.center,
                  children: [
                    for (final c in staff)
                      ChoiceChip(
                        key: Key('user-${c.id}'),
                        label: Text(c.name),
                        selected: _selected?.id == c.id,
                        onSelected: (_) => setState(() {
                          _selected = c;
                          _pin = '';
                          _message = null;
                        }),
                      ),
                  ],
                ),
                const SizedBox(height: 20),
                Text('•' * _pin.length,
                    key: const Key('pin-dots'),
                    style: const TextStyle(fontSize: 30, letterSpacing: 6)),
                if (_message != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(_message!,
                        key: const Key('login-message'),
                        style: const TextStyle(color: Colors.red)),
                  ),
                const SizedBox(height: 12),
                _keypad(),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _keypad() => SizedBox(
        width: 300,
        child: GridView.count(
          shrinkWrap: true,
          crossAxisCount: 3,
          childAspectRatio: 1.6,
          mainAxisSpacing: 6,
          crossAxisSpacing: 6,
          children: [
            for (final d in ['1', '2', '3', '4', '5', '6', '7', '8', '9'])
              _key(d, () => _press(d)),
            _key('⌫', () => setState(() {
                  if (_pin.isNotEmpty) _pin = _pin.substring(0, _pin.length - 1);
                })),
            _key('0', () => _press('0')),
            FilledButton(
              key: const Key('pin-ok'),
              onPressed: _selected == null || _busy ? null : _submit,
              child: Text(tr(context, 'OK')),
            ),
          ],
        ),
      );

  Widget _key(String label, VoidCallback onTap) => OutlinedButton(
        key: Key('key-$label'),
        onPressed: _selected == null ? null : onTap,
        child: Text(label, style: const TextStyle(fontSize: 20)),
      );
}
