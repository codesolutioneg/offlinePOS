import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../sessions.dart';
import '../theme.dart';
import 'owner_ui.dart';

String _two(int n) => n.toString().padLeft(2, '0');

String _when(DateTime utc) {
  final t = utc.toLocal();
  return '${_two(t.day)}/${_two(t.month)} ${_two(t.hour)}:${_two(t.minute)}';
}

/// Compact open/closed counts for the dashboard.
class SessionStatusSummary extends StatelessWidget {
  const SessionStatusSummary({
    super.key,
    required this.sessions,
    required this.arabic,
    this.onTap,
  });

  final List<OwnerSessionInfo> sessions;
  final bool arabic;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final open = sessions.where((s) => s.isOpen).length;
    final closed = sessions.length - open;
    return OwnerCard(
      onTap: onTap,
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          Expanded(
            child: _pill(
              arabic ? 'جلسات مفتوحة' : 'Open sessions',
              '$open',
              AppColors.success,
              Icons.lock_open_rounded,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: _pill(
              arabic ? 'جلسات مقفولة' : 'Closed sessions',
              '$closed',
              AppColors.muted,
              Icons.lock_rounded,
            ),
          ),
        ],
      ),
    );
  }

  Widget _pill(String label, String value, Color color, IconData icon) {
    return Row(
      children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(icon, color: color, size: 20),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.cairo(
                      color: AppColors.muted,
                      fontSize: 11,
                      fontWeight: FontWeight.w600)),
              Text(value,
                  style: GoogleFonts.cairo(
                      fontWeight: FontWeight.w800,
                      fontSize: 20,
                      color: AppColors.navy,
                      height: 1.1)),
            ],
          ),
        ),
      ],
    );
  }
}

class SessionStatusList extends StatelessWidget {
  const SessionStatusList({
    super.key,
    required this.sessions,
    required this.arabic,
  });

  final List<OwnerSessionInfo> sessions;
  final bool arabic;

  @override
  Widget build(BuildContext context) {
    if (sessions.isEmpty) {
      return EmptyHint(
        arabic ? 'لا جلسات في هذه الفترة' : 'No sessions in this period',
        icon: Icons.timelapse_rounded,
      );
    }
    return Column(
      children: [
        for (final s in sessions) ...[
          OwnerCard(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: (s.isOpen ? AppColors.success : AppColors.muted)
                        .withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    s.isOpen ? Icons.lock_open_rounded : Icons.lock_rounded,
                    color: s.isOpen ? AppColors.success : AppColors.muted,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        s.cashierId.isEmpty ? s.deviceId : s.cashierId,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.cairo(
                            fontWeight: FontWeight.w700,
                            color: AppColors.navy),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${arabic ? 'فتح' : 'Opened'} ${_when(s.openedAt)}'
                        '${s.closedAt == null ? '' : ' · ${arabic ? 'قفل' : 'Closed'} ${_when(s.closedAt!)}'}',
                        style: GoogleFonts.cairo(
                            color: AppColors.muted,
                            fontSize: 12,
                            fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: (s.isOpen ? AppColors.success : AppColors.muted)
                        .withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(99),
                  ),
                  child: Text(
                    arabic ? s.statusAr : s.statusEn,
                    style: GoogleFonts.cairo(
                      fontWeight: FontWeight.w800,
                      fontSize: 12,
                      color: s.isOpen ? AppColors.success : AppColors.muted,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
        ],
      ],
    );
  }
}
