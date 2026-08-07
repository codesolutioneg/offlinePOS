import 'package:flutter/material.dart';

import '../../core/auth/auth_service.dart';
import '../../core/auth/user_store.dart';

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
  });

  final AuthService auth;
  final UserStore users;
  final void Function(Cashier) onSignedIn;

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
        AuthRejected() => 'Incorrect PIN',
        AuthMalformed() => 'PIN must be 4 to 6 digits',
        // Say it is a lockout, not a wrong PIN, or the cashier keeps trying.
        AuthLockedOut() => 'Too many attempts. Locked for a few minutes.',
      };
    });
    if (result is AuthOk) widget.onSignedIn(result.cashier);
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
              const Text('offlinePOS',
                  style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold)),
              const SizedBox(height: 24),
              if (staff.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('No cashiers on this device yet',
                      key: Key('no-users')),
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
              child: const Text('OK'),
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
