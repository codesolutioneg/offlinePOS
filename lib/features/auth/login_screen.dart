import 'package:flutter/material.dart';

import '../../core/auth/auth_service.dart';
import '../../core/auth/fingerprint_service.dart';
import '../../core/auth/fingerprint_store.dart';
import '../../core/auth/user_store.dart';
import '../../core/db/attendance_store.dart';
import '../../core/i18n/l10n.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/dishflow_brand.dart';
import 'fingerprint_or_pin_dialog.dart';
import 'login_staff_grid.dart';

/// PIN sign-in.
///
/// Everything here resolves locally, so the screen behaves identically with or
/// without a line. There is no probe of a remote service that can hang, which is the
/// failure mode that leaves a cashier staring at a spinner with no way in.
///
/// Laid out as a till lock screen in two steps: everyone on the roster as tiles,
/// then the picked person's PIN as a row of dots over a pad big enough to hit at
/// speed. A shift change is a quick pick-and-PIN, because it happens with a queue
/// watching.
class LoginScreen extends StatefulWidget {
  const LoginScreen({
    super.key,
    required this.auth,
    required this.users,
    required this.onSignedIn,
    this.provisioningPin,
    this.attendance,
    this.refusal,
    this.fingerprints,
    this.fingerprintStore,
    this.asPopup = false,
    this.onClose,
  });

  /// Just the card, for a dialog over the locked floor, with no page behind it.
  final bool asPopup;

  /// Draws a close button on the card. Null draws none.
  final VoidCallback? onClose;

  final AuthService auth;
  final UserStore users;
  final void Function(Cashier) onSignedIn;

  /// Colours each tile by whether that person is on the clock.
  final AttendanceStore? attendance;

  /// Why this person may not unlock the till right now (an untranslated
  /// message), or null when they may. Asked before the PIN and again before it
  /// is checked, since a shift can open on another till in between.
  final String? Function(Cashier)? refusal;

  /// ZK reader when present: unlock by finger, else PIN.
  final FingerprintService? fingerprints;

  /// Local template bank — pushed into the agent before identify.
  final FingerprintStore? fingerprintStore;

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

  /// Sends [who] back to the roster with the reason when the gate refuses them.
  bool _refused(Cashier who) {
    final why = widget.refusal?.call(who);
    if (why == null) return false;
    setState(() {
      _selected = null;
      _pin = '';
      _message = tr(context, why);
    });
    return true;
  }

  Future<void> _submit() async {
    final who = _selected;
    if (who == null || _busy || _refused(who)) return;
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

  Future<void> _submitFingerprint() async {
    final fp = widget.fingerprints;
    if (fp == null || _busy) return;
    setState(() => _busy = true);
    final result = await showFingerprintOrPin(
      context,
      fingerprints: fp,
      title: tr(context, 'Sign in'),
      message: tr(context, 'Fingerprint or manager PIN'),
      prepareTemplates: widget.fingerprintStore?.pushToAgent,
    );
    if (!mounted) return;
    if (result == null) {
      setState(() => _busy = false);
      return;
    }
    if (result.isFingerprint) {
      final matched = result.matchedUserId;
      final owner = matched == null ? null : widget.users.byId(matched);
      if (owner != null && _refused(owner)) {
        setState(() => _busy = false);
        return;
      }
      final authResult = await widget.auth.unlockByFingerprint(matched ?? '');
      if (!mounted) return;
      setState(() => _busy = false);
      _applyUnlock(authResult);
      return;
    }
    final who = _selected;
    if (who == null) {
      setState(() {
        _busy = false;
        _message = tr(context, 'Pick who is signing in');
      });
      return;
    }
    if (_refused(who)) {
      setState(() => _busy = false);
      return;
    }
    final authResult = await widget.auth.unlock(who.id, result.pin!);
    if (!mounted) return;
    setState(() => _busy = false);
    _applyUnlock(authResult);
  }

  void _applyUnlock(AuthResult result) {
    setState(() {
      _pin = '';
      _message = switch (result) {
        AuthOk() => null,
        AuthRejected() => tr(context, 'Incorrect PIN'),
        AuthMalformed() => tr(context, 'PIN must be 4 to 6 digits'),
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
    final pin = widget.provisioningPin;
    final form = Column(
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
                if (widget.onClose != null)
                  Align(
                    alignment: AlignmentDirectional.centerEnd,
                    child: IconButton(
                      key: const Key('login-close'),
                      icon: const Icon(Icons.close),
                      tooltip: tr(context, 'Close'),
                      onPressed: widget.onClose,
                    ),
                  ),
                _brand(context),
                const SizedBox(height: 16),
                if (staff.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(tr(context, 'No cashiers on this device yet'),
                        key: const Key('no-users')),
                  )
                else if (_selected == null)
                  ..._rosterStep(staff)
                else
                  ..._pinStep(),
              ],
            ),
          ),
        ),
      ],
    );
    if (widget.asPopup) {
      return SingleChildScrollView(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: form,
        ),
      );
    }
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
                  child: form,
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

  /// Step one: who is signing in. The hint says the order of things, and a
  /// refusal from the gate lands on the same row.
  List<Widget> _rosterStep(List<Cashier> staff) => [
        Text(tr(context, 'Select your name, then enter your PIN'),
            key: const Key('pick-name-hint'),
            textAlign: TextAlign.center,
            style: TextStyle(
                fontSize: 13,
                color: Theme.of(context).colorScheme.onSurfaceVariant)),
        _messageLine(),
        const SizedBox(height: 10),
        LoginStaffGrid(
            staff: staff, attendance: widget.attendance, onPick: _choose),
        if (widget.fingerprints != null) ...[
          const SizedBox(height: 10),
          SizedBox(width: 300, child: _fingerprintButton()),
        ],
      ];

  /// Step two: the picked person's PIN, with a way back to the roster.
  List<Widget> _pinStep() => [
        _pickedHeader(),
        const SizedBox(height: 8),
        _pinDots(context),
        _messageLine(),
        const SizedBox(height: 10),
        _keypad(),
      ];

  Widget _pickedHeader() {
    final who = _selected;
    return Row(children: [
      IconButton(
        key: const Key('login-back'),
        icon: const Icon(Icons.arrow_back),
        tooltip: tr(context, 'Back'),
        onPressed: _busy ? null : _backToRoster,
      ),
      Expanded(
        child: Text(who?.name ?? '',
            key: const Key('login-picked-name'),
            textAlign: TextAlign.center,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
      ),
      const SizedBox(width: 48),
    ]);
  }

  Widget _messageLine() {
    final message = _message;
    if (message == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Text(message,
          key: const Key('login-message'),
          textAlign: TextAlign.center,
          style: TextStyle(
              color: Theme.of(context).colorScheme.error,
              fontWeight: FontWeight.w600)),
    );
  }

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

  void _choose(Cashier c) {
    if (_busy || _refused(c)) return;
    setState(() {
      _selected = c;
      _pin = '';
      _message = null;
    });
  }

  void _backToRoster() => setState(() {
        _selected = null;
        _pin = '';
        _message = null;
      });

  Widget _fingerprintButton() => SizedBox(
        width: double.infinity,
        child: OutlinedButton.icon(
          key: const Key('login-fingerprint'),
          onPressed: _busy ? null : _submitFingerprint,
          icon: const Icon(Icons.fingerprint),
          label: Text(tr(context, 'Use fingerprint')),
        ),
      );

  Widget _keypad() => SizedBox(
        width: 300,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.fingerprints != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: _fingerprintButton(),
              ),
            GridView.count(
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
                      if (_pin.isNotEmpty) {
                        _pin = _pin.substring(0, _pin.length - 1);
                      }
                    })),
                _key('0', () => _press('0')),
                FilledButton(
                  key: const Key('pin-ok'),
                  style: FilledButton.styleFrom(
                      textStyle: const TextStyle(
                          fontSize: 17, fontWeight: FontWeight.w700)),
                  onPressed: _selected == null || _busy ? null : _submit,
                  child: Text(tr(context, 'OK')),
                ),
              ],
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
