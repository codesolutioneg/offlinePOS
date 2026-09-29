import 'package:flutter/material.dart';

import '../../core/auth/auth_service.dart';
import '../../core/auth/user_store.dart';
import '../../core/db/attendance_store.dart';
import '../../core/i18n/l10n.dart';
import '../../core/widgets/feedback.dart';
import 'attendance_screen.dart';

/// The floor's Empl button: every employee on one card, and tapping a name clocks
/// that person in or out after their own PIN. Stays open so a whole shift can
/// clock in one after another.
Future<void> showClockDialog(
  BuildContext context, {
  required UserStore users,
  required AttendanceStore attendance,
  required AuthService auth,
}) =>
    showDialog<void>(
      context: context,
      builder: (_) =>
          _ClockDialog(users: users, attendance: attendance, auth: auth),
    );

class _ClockDialog extends StatefulWidget {
  const _ClockDialog({
    required this.users,
    required this.attendance,
    required this.auth,
  });

  final UserStore users;
  final AttendanceStore attendance;
  final AuthService auth;

  @override
  State<_ClockDialog> createState() => _ClockDialogState();
}

class _ClockDialogState extends State<_ClockDialog> {
  static String _time(DateTime utc) {
    final d = utc.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(d.hour)}:${two(d.minute)}';
  }

  Future<void> _toggle(Cashier c) async {
    final nowIn = await toggleClockWithPin(context,
        cashier: c, attendance: widget.attendance, auth: widget.auth);
    if (!mounted || nowIn == null) return;
    setState(() {});
    showToast(
      context,
      '${c.name}: ${tr(context, nowIn ? 'Clocked in' : 'Clocked out')}',
      kind: ToastKind.success,
    );
  }

  @override
  Widget build(BuildContext context) {
    final staff = widget.users.active();
    return AlertDialog(
      key: const Key('clock-dialog'),
      title: Row(children: [
        const Icon(Icons.badge_outlined),
        const SizedBox(width: 8),
        Expanded(child: Text(tr(context, 'Staff clock in / out'))),
        Text('${widget.attendance.onNow().length} ${tr(context, 'on the clock')}',
            style: Theme.of(context).textTheme.bodyMedium),
      ]),
      contentPadding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      content: SizedBox(
        width: 520,
        child: staff.isEmpty
            ? Padding(
                padding: const EdgeInsets.all(24),
                child: Text(tr(context, 'No staff yet'),
                    textAlign: TextAlign.center),
              )
            : GridView.count(
                shrinkWrap: true,
                crossAxisCount: 2,
                mainAxisSpacing: 8,
                crossAxisSpacing: 8,
                childAspectRatio: 3.2,
                children: [for (final c in staff) _tile(c)],
              ),
      ),
      actions: [
        TextButton(
          key: const Key('clock-dialog-close'),
          onPressed: () => Navigator.pop(context),
          child: Text(tr(context, 'Close')),
        ),
      ],
    );
  }

  Widget _tile(Cashier c) {
    final open = widget.attendance.openFor(c.id);
    final isIn = open != null;
    final color = isIn ? const Color(0xFF27AE60) : const Color(0xFF7F8C8D);
    return Material(
      color: color.withValues(alpha: 0.12),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: color, width: 1.4),
      ),
      child: InkWell(
        key: Key('clock-staff-${c.id}'),
        borderRadius: BorderRadius.circular(10),
        onTap: () => _toggle(c),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Row(children: [
            Icon(isIn ? Icons.login : Icons.logout, color: color),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(c.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w700)),
                  Text(
                    isIn
                        ? '${tr(context, 'Since')} ${_time(open.clockIn)}'
                        : tr(context, 'Off the clock'),
                    style: TextStyle(fontSize: 12, color: color),
                  ),
                ],
              ),
            ),
          ]),
        ),
      ),
    );
  }
}
