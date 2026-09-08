import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/auth/auth_service.dart';
import '../../core/auth/user_store.dart';
import '../../core/db/attendance_store.dart';
import '../../core/i18n/l10n.dart';
import '../../core/widgets/feedback.dart';
import '../../core/widgets/numeric_keypad.dart';

/// Staff clock in / clock out for the till. Several cashiers can be on the clock at
/// once, which is why this is separate from the single cash-drawer shift.
///
/// Both clock-in and clock-out ask for that person's PIN (touch pad), so a manager
/// standing at the till cannot stamp attendance for someone who is not there.
class AttendanceScreen extends StatefulWidget {
  const AttendanceScreen({
    super.key,
    required this.users,
    required this.attendance,
    required this.auth,
  });

  final UserStore users;
  final AttendanceStore attendance;
  final AuthService auth;

  @override
  State<AttendanceScreen> createState() => _AttendanceScreenState();
}

class _AttendanceScreenState extends State<AttendanceScreen> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    // Keep the on-the-clock durations live without a manual refresh.
    _tick = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  static String _time(DateTime utc) {
    final d = utc.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(d.hour)}:${two(d.minute)}';
  }

  static String _dur(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes % 60;
    return h > 0 ? '${h}h ${m}m' : '${m}m';
  }

  Future<void> _confirmAndToggle(Cashier c, {required bool clockIn}) async {
    final pin = await promptTouchPin(
      context,
      title: tr(context, 'Confirm with PIN'),
      message: clockIn
          ? tr(context, 'Enter PIN to clock in')
          : tr(context, 'Enter PIN to clock out'),
      confirmLabel: clockIn ? tr(context, 'Clock in') : tr(context, 'Clock out'),
      displayKey: const Key('attend-pin'),
      confirmKey: const Key('attend-pin-ok'),
    );
    if (pin == null || pin.isEmpty || !mounted) return;
    final ok = await widget.auth.authorizeCashier(c.id, pin);
    if (!ok) {
      if (mounted) {
        showToast(context, tr(context, 'Incorrect PIN'), kind: ToastKind.error);
      }
      return;
    }
    setState(() {
      if (clockIn) {
        widget.attendance.clockIn(c.id);
      } else {
        widget.attendance.clockOut(c.id);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final staff = widget.users.active();
    final now = DateTime.now().toUtc();
    final onNow = widget.attendance.onNow().length;
    return Scaffold(
      appBar: AppBar(title: Text(tr(context, 'Attendance'))),
      body: staff.isEmpty
          ? Center(child: Text(tr(context, 'No staff yet')))
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(children: [
                    const Icon(Icons.groups),
                    const SizedBox(width: 8),
                    Text('$onNow ${tr(context, 'on the clock')}',
                        style: const TextStyle(fontWeight: FontWeight.bold)),
                  ]),
                ),
                const Divider(height: 1),
                Expanded(
                  child: ListView.separated(
                    itemCount: staff.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, i) {
                      final c = staff[i];
                      final open = widget.attendance.openFor(c.id);
                      final isIn = open != null;
                      return ListTile(
                        key: Key('attend-${c.id}'),
                        leading: CircleAvatar(
                          backgroundColor:
                              isIn ? Colors.green.shade100 : Colors.grey.shade200,
                          child: Icon(isIn ? Icons.login : Icons.logout,
                              color: isIn ? Colors.green.shade800 : Colors.grey),
                        ),
                        title: Text(c.name),
                        subtitle: Text(isIn
                            ? '${tr(context, 'Since')} ${_time(open.clockIn)}  ·  ${_dur(open.worked(now))}'
                            : tr(context, 'Off the clock')),
                        trailing: isIn
                            ? OutlinedButton(
                                key: Key('clock-out-${c.id}'),
                                onPressed: () =>
                                    unawaited(_confirmAndToggle(c, clockIn: false)),
                                child: Text(tr(context, 'Clock out')),
                              )
                            : FilledButton(
                                key: Key('clock-in-${c.id}'),
                                onPressed: () =>
                                    unawaited(_confirmAndToggle(c, clockIn: true)),
                                child: Text(tr(context, 'Clock in')),
                              ),
                      );
                    },
                  ),
                ),
              ],
            ),
    );
  }
}
