import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'theme.dart';
import 'widgets/owner_calendar.dart';

/// Calendar window for owner reports — [to] is exclusive local midnight.
class OwnerPeriodChoice {
  const OwnerPeriodChoice({
    required this.from,
    required this.to,
    required this.label,
    this.preset = 'custom',
  });

  final DateTime from;
  final DateTime to;
  final String label;

  /// `today` | `yesterday` | `last7` | `custom`
  final String preset;

  static OwnerPeriodChoice ofPreset(String key, {required bool arabic}) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final tomorrow = today.add(const Duration(days: 1));
    return switch (key) {
      'yesterday' => OwnerPeriodChoice(
          from: today.subtract(const Duration(days: 1)),
          to: today,
          label: arabic ? 'أمس' : 'Yesterday',
          preset: 'yesterday',
        ),
      'last7' => OwnerPeriodChoice(
          from: today.subtract(const Duration(days: 6)),
          to: tomorrow,
          label: arabic ? 'آخر 7 أيام' : 'Last 7 days',
          preset: 'last7',
        ),
      _ => OwnerPeriodChoice(
          from: today,
          to: tomorrow,
          label: arabic ? 'اليوم' : 'Today',
          preset: 'today',
        ),
    };
  }

  static OwnerPeriodChoice custom(DateTimeRange range, {required bool arabic}) {
    final from =
        DateTime(range.start.year, range.start.month, range.start.day);
    final endDay = DateTime(range.end.year, range.end.month, range.end.day);
    String fmt(DateTime d) {
      String two(int n) => n.toString().padLeft(2, '0');
      return '${d.year}-${two(d.month)}-${two(d.day)}';
    }

    return OwnerPeriodChoice(
      from: from,
      to: endDay.add(const Duration(days: 1)),
      label: '${fmt(from)} → ${fmt(endDay)}',
      preset: 'custom',
    );
  }
}

/// Today / yesterday / last 7 / full custom date range.
Future<OwnerPeriodChoice?> showOwnerPeriodDialog(
  BuildContext context, {
  required bool arabic,
  String? title,
}) {
  return showDialog<OwnerPeriodChoice>(
    context: context,
    builder: (ctx) => _OwnerPeriodDialog(
      arabic: arabic,
      title: title ?? (arabic ? 'اختر الفترة' : 'Select period'),
    ),
  );
}

Future<OwnerPeriodChoice?> pickOwnerCustomDates(
  BuildContext context, {
  required bool arabic,
  DateTimeRange? initial,
}) async {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final picked = await showOwnerCalendar(
    context,
    arabic: arabic,
    initial: initial ?? DateTimeRange(start: today, end: today),
  );
  if (picked == null) return null;
  return OwnerPeriodChoice.custom(picked, arabic: arabic);
}

class _OwnerPeriodDialog extends StatelessWidget {
  const _OwnerPeriodDialog({required this.arabic, required this.title});
  final bool arabic;
  final String title;

  @override
  Widget build(BuildContext context) {
    final options = <(String, IconData, String)>[
      ('today', Icons.today, arabic ? 'اليوم' : 'Today'),
      ('yesterday', Icons.history, arabic ? 'أمس' : 'Yesterday'),
      ('last7', Icons.date_range, arabic ? 'آخر 7 أيام' : 'Last 7 days'),
    ];

    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      title: Text(title, style: GoogleFonts.cairo(fontWeight: FontWeight.w800)),
      contentPadding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final (key, icon, label) in options)
              ListTile(
                leading: Icon(icon, color: AppColors.skyDark),
                title: Text(label,
                    style: GoogleFonts.cairo(fontWeight: FontWeight.w700)),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
                onTap: () => Navigator.pop(
                    context, OwnerPeriodChoice.ofPreset(key, arabic: arabic)),
              ),
            ListTile(
              leading:
                  const Icon(Icons.calendar_month, color: AppColors.skyDark),
              title: Text(arabic ? 'تواريخ مخصصة' : 'Custom dates',
                  style: GoogleFonts.cairo(fontWeight: FontWeight.w700)),
              subtitle: Text(
                arabic
                    ? 'من يوم إلى يوم — حسب فتح السيشن'
                    : 'From–to days · by session open day',
                style:
                    GoogleFonts.cairo(fontSize: 12, color: AppColors.muted),
              ),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
              onTap: () async {
                final choice =
                    await pickOwnerCustomDates(context, arabic: arabic);
                if (!context.mounted || choice == null) return;
                Navigator.pop(context, choice);
              },
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child:
              Text(arabic ? 'إلغاء' : 'Cancel', style: GoogleFonts.cairo()),
        ),
      ],
    );
  }
}
