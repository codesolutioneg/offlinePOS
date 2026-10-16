import 'package:flutter/material.dart';

import '../../core/auth/user_store.dart';
import '../../core/db/attendance_store.dart';
import '../../core/i18n/l10n.dart';
import '../../core/theme/app_colors.dart';

/// The first step of sign-in: everyone on the roster as a tile, laid out like the
/// clock-in card so the cashier finds their name the same way in both places.
/// Green is on the clock (with the time they came in), grey is off it.
class LoginStaffGrid extends StatelessWidget {
  const LoginStaffGrid({
    super.key,
    required this.staff,
    required this.onPick,
    this.attendance,
  });

  final List<Cashier> staff;
  final ValueChanged<Cashier> onPick;

  /// Null draws every tile as off the clock.
  final AttendanceStore? attendance;

  static String _time(DateTime utc) {
    final d = utc.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(d.hour)}:${two(d.minute)}';
  }

  @override
  Widget build(BuildContext context) => GridView.builder(
        key: const Key('login-staff-grid'),
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          mainAxisSpacing: 8,
          crossAxisSpacing: 8,
          childAspectRatio: 3.2,
        ),
        itemCount: staff.length,
        itemBuilder: (context, i) => _tile(context, staff[i]),
      );

  Widget _tile(BuildContext context, Cashier c) {
    final open = attendance?.openFor(c.id);
    final isIn = open != null;
    final color = isIn ? AppColors.success : AppColors.textMutedLight;
    return Material(
      color: color.withValues(alpha: 0.12),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: color, width: 1.4),
      ),
      child: InkWell(
        key: Key('user-${c.id}'),
        borderRadius: BorderRadius.circular(10),
        onTap: () => onPick(c),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Row(children: [
            Icon(c.isManager ? Icons.admin_panel_settings : Icons.person,
                color: color),
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
                    maxLines: 1,
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
