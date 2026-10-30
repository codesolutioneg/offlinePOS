import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart' hide TextDirection;

import '../theme.dart';
import 'dishflow_brand.dart';

/// Dishflow-styled from→to calendar sheet.
Future<DateTimeRange?> showOwnerCalendar(
  BuildContext context, {
  required bool arabic,
  DateTimeRange? initial,
}) {
  return showModalBottomSheet<DateTimeRange>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: AppColors.navy.withValues(alpha: 0.45),
    builder: (ctx) => _OwnerCalendarSheet(
      arabic: arabic,
      initial: initial,
    ),
  );
}

class _OwnerCalendarSheet extends StatefulWidget {
  const _OwnerCalendarSheet({required this.arabic, this.initial});

  final bool arabic;
  final DateTimeRange? initial;

  @override
  State<_OwnerCalendarSheet> createState() => _OwnerCalendarSheetState();
}

class _OwnerCalendarSheetState extends State<_OwnerCalendarSheet> {
  late DateTime _visibleMonth;
  DateTime? _start;
  DateTime? _end;
  late final DateTime _today;
  late final DateTime _firstDate;
  late final DateTime _lastDate;

  bool get _arabic => widget.arabic;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _today = DateTime(now.year, now.month, now.day);
    _firstDate = DateTime(now.year - 2);
    _lastDate = _today;
    final init = widget.initial;
    if (init != null) {
      _start = DateTime(init.start.year, init.start.month, init.start.day);
      _end = DateTime(init.end.year, init.end.month, init.end.day);
      _visibleMonth = DateTime(_end!.year, _end!.month);
    } else {
      _start = _today;
      _end = _today;
      _visibleMonth = DateTime(_today.year, _today.month);
    }
  }

  void _shiftMonth(int delta) {
    final next = DateTime(_visibleMonth.year, _visibleMonth.month + delta);
    final minMonth = DateTime(_firstDate.year, _firstDate.month);
    final maxMonth = DateTime(_lastDate.year, _lastDate.month);
    if (next.isBefore(minMonth) || next.isAfter(maxMonth)) return;
    setState(() => _visibleMonth = next);
  }

  void _onDayTap(DateTime day) {
    if (day.isBefore(_firstDate) || day.isAfter(_lastDate)) return;
    setState(() {
      if (_start == null || (_start != null && _end != null)) {
        _start = day;
        _end = null;
      } else if (day.isBefore(_start!)) {
        _end = _start;
        _start = day;
      } else {
        _end = day;
      }
    });
  }

  void _applyPreset(String key) {
    setState(() {
      switch (key) {
        case 'yesterday':
          _start = _today.subtract(const Duration(days: 1));
          _end = _start;
          break;
        case 'last7':
          _start = _today.subtract(const Duration(days: 6));
          _end = _today;
          break;
        default:
          _start = _today;
          _end = _today;
      }
      _visibleMonth = DateTime(_end!.year, _end!.month);
    });
  }

  String _fmt(DateTime? d) {
    if (d == null) return _arabic ? 'اختر' : 'Pick';
    final locale = _arabic ? 'ar' : 'en';
    return DateFormat('d MMM y', locale).format(d);
  }

  String get _monthTitle {
    final locale = _arabic ? 'ar' : 'en';
    return DateFormat('MMMM yyyy', locale).format(_visibleMonth);
  }

  bool get _canSave => _start != null && _end != null;

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.paddingOf(context).bottom;
    final weekdays = _arabic
        ? const ['أحد', 'إثن', 'ثلا', 'أرب', 'خمي', 'جمع', 'سبت']
        : const ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];

    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: Container(
        margin: const EdgeInsets.fromLTRB(10, 0, 10, 10),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(28),
          boxShadow: [
            BoxShadow(
              color: AppColors.navy.withValues(alpha: 0.18),
              blurRadius: 32,
              offset: const Offset(0, 12),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 10),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: const Color(0xFFD8E0EA),
                borderRadius: BorderRadius.circular(99),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 14, 18, 0),
              child: Row(
                children: [
                  const DishflowBrandIcon(size: 28),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _arabic ? 'اختر الفترة' : 'Select range',
                          style: GoogleFonts.cairo(
                            fontWeight: FontWeight.w800,
                            fontSize: 17,
                            color: AppColors.navy,
                            height: 1.1,
                          ),
                        ),
                        Text(
                          _arabic
                              ? 'حسب يوم فتح السيشن'
                              : 'By session opening day',
                          style: GoogleFonts.cairo(
                            fontWeight: FontWeight.w600,
                            fontSize: 11,
                            color: AppColors.muted,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close_rounded),
                    color: AppColors.muted,
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
              child: Row(
                children: [
                  Expanded(
                    child: _RangeEndpoint(
                      label: _arabic ? 'من' : 'From',
                      value: _fmt(_start),
                      active: _start != null && _end == null,
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Icon(Icons.arrow_forward_rounded,
                        size: 18,
                        color: AppColors.skyDark.withValues(alpha: 0.8)),
                  ),
                  Expanded(
                    child: _RangeEndpoint(
                      label: _arabic ? 'إلى' : 'To',
                      value: _fmt(_end),
                      active: _start != null && _end != null,
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
              child: Row(
                children: [
                  for (final (key, label) in [
                    ('today', _arabic ? 'اليوم' : 'Today'),
                    ('yesterday', _arabic ? 'أمس' : 'Yest.'),
                    ('last7', _arabic ? '٧ أيام' : '7 days'),
                  ]) ...[
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsetsDirectional.only(end: 6),
                        child: _QuickChip(
                          label: label,
                          onTap: () => _applyPreset(key),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 12),
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 12),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0xFFF7FAFD), Color(0xFFEEF5FB)],
                ),
                borderRadius: BorderRadius.circular(22),
                border: Border.all(color: const Color(0xFFDCE7F2)),
              ),
              child: Column(
                children: [
                  Directionality(
                    textDirection: TextDirection.ltr,
                    child: Column(
                      children: [
                        Row(
                          children: [
                            _NavBtn(
                              icon: Icons.chevron_left_rounded,
                              onTap: () => _shiftMonth(-1),
                            ),
                            Expanded(
                              child: Text(
                                _monthTitle,
                                textAlign: TextAlign.center,
                                textDirection: _arabic
                                    ? TextDirection.rtl
                                    : TextDirection.ltr,
                                style: GoogleFonts.cairo(
                                  fontWeight: FontWeight.w800,
                                  fontSize: 16,
                                  color: AppColors.navy,
                                ),
                              ),
                            ),
                            _NavBtn(
                              icon: Icons.chevron_right_rounded,
                              onTap: () => _shiftMonth(1),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            for (final w in weekdays)
                              Expanded(
                                child: Text(
                                  w,
                                  textAlign: TextAlign.center,
                                  style: GoogleFonts.cairo(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w700,
                                    color: AppColors.muted,
                                  ),
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        _MonthGrid(
                          month: _visibleMonth,
                          start: _start,
                          end: _end,
                          today: _today,
                          firstDate: _firstDate,
                          lastDate: _lastDate,
                          onDayTap: _onDayTap,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: EdgeInsets.fromLTRB(16, 14, 16, 12 + bottom),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.pop(context),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppColors.navy,
                        side: const BorderSide(color: AppColors.border),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                        textStyle: GoogleFonts.cairo(
                          fontWeight: FontWeight.w800,
                          fontSize: 15,
                        ),
                      ),
                      child: Text(_arabic ? 'إلغاء' : 'Cancel'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    flex: 1,
                    child: FilledButton(
                      onPressed: !_canSave
                          ? null
                          : () => Navigator.pop(
                                context,
                                DateTimeRange(start: _start!, end: _end!),
                              ),
                      style: FilledButton.styleFrom(
                        backgroundColor: AppColors.navy,
                        disabledBackgroundColor:
                            AppColors.navy.withValues(alpha: 0.35),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                        textStyle: GoogleFonts.cairo(
                          fontWeight: FontWeight.w800,
                          fontSize: 15,
                        ),
                      ),
                      child: Text(_arabic ? 'تطبيق' : 'Apply'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RangeEndpoint extends StatelessWidget {
  const _RangeEndpoint({
    required this.label,
    required this.value,
    required this.active,
  });

  final String label;
  final String value;
  final bool active;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: active ? const Color(0xFFE0F2FE) : const Color(0xFFF5F7FA),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: active ? AppColors.skyDark : const Color(0xFFE2E8F0),
          width: active ? 1.4 : 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: GoogleFonts.cairo(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: active ? AppColors.skyDark : AppColors.muted,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: GoogleFonts.cairo(
              fontSize: 13,
              fontWeight: FontWeight.w800,
              color: AppColors.navy,
            ),
          ),
        ],
      ),
    );
  }
}

class _QuickChip extends StatelessWidget {
  const _QuickChip({required this.label, required this.onTap});
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 8),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0xFFE2E8F0)),
          ),
          child: Text(
            label,
            style: GoogleFonts.cairo(
              fontWeight: FontWeight.w700,
              fontSize: 12,
              color: AppColors.navy,
            ),
          ),
        ),
      ),
    );
  }
}

class _NavBtn extends StatelessWidget {
  const _NavBtn({required this.icon, required this.onTap});
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(
          width: 36,
          height: 36,
          child: Icon(icon, color: AppColors.navy, size: 22),
        ),
      ),
    );
  }
}

class _MonthGrid extends StatelessWidget {
  const _MonthGrid({
    required this.month,
    required this.start,
    required this.end,
    required this.today,
    required this.firstDate,
    required this.lastDate,
    required this.onDayTap,
  });

  final DateTime month;
  final DateTime? start;
  final DateTime? end;
  final DateTime today;
  final DateTime firstDate;
  final DateTime lastDate;
  final ValueChanged<DateTime> onDayTap;

  @override
  Widget build(BuildContext context) {
    final firstOfMonth = DateTime(month.year, month.month, 1);
    final daysInMonth = DateTime(month.year, month.month + 1, 0).day;
    final leading = firstOfMonth.weekday % 7; // Sunday = 0
    final totalCells = ((leading + daysInMonth + 6) ~/ 7) * 7;

    return Column(
      children: [
        for (var row = 0; row < totalCells ~/ 7; row++)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              children: [
                for (var col = 0; col < 7; col++)
                  Expanded(
                    child: _buildCell(row * 7 + col, leading, daysInMonth),
                  ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildCell(int index, int leading, int daysInMonth) {
    final dayNum = index - leading + 1;
    if (dayNum < 1 || dayNum > daysInMonth) {
      return const SizedBox(height: 42);
    }
    final day = DateTime(month.year, month.month, dayNum);
    final enabled =
        !day.isBefore(firstDate) && !day.isAfter(lastDate);
    final isStart = start != null && _sameDay(day, start!);
    final isEnd = end != null && _sameDay(day, end!);
    final inRange = start != null &&
        end != null &&
        !day.isBefore(start!) &&
        !day.isAfter(end!);
    final isToday = _sameDay(day, today);
    final isEndpoint = isStart || isEnd;

    Color? bandColor;
    BorderRadiusGeometry? bandRadius;
    if (inRange && start != null && end != null && !_sameDay(start!, end!)) {
      bandColor = AppColors.sky.withValues(alpha: 0.16);
      if (isStart) {
        bandRadius = const BorderRadiusDirectional.horizontal(
          start: Radius.circular(21),
        );
      } else if (isEnd) {
        bandRadius = const BorderRadiusDirectional.horizontal(
          end: Radius.circular(21),
        );
      } else {
        bandRadius = BorderRadius.zero;
      }
    }

    return SizedBox(
      height: 42,
      child: Stack(
        alignment: Alignment.center,
        children: [
          if (bandColor != null)
            Positioned.fill(
              child: Container(
                margin: const EdgeInsets.symmetric(vertical: 4),
                decoration: BoxDecoration(
                  color: bandColor,
                  borderRadius: bandRadius,
                ),
              ),
            ),
          Material(
            color: Colors.transparent,
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: enabled ? () => onDayTap(day) : null,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 140),
                width: 36,
                height: 36,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: isEndpoint
                      ? AppColors.navy
                      : (isToday
                          ? AppColors.sky.withValues(alpha: 0.15)
                          : Colors.transparent),
                  border: isToday && !isEndpoint
                      ? Border.all(color: AppColors.skyDark, width: 1.4)
                      : null,
                  boxShadow: isEndpoint
                      ? [
                          BoxShadow(
                            color: AppColors.navy.withValues(alpha: 0.28),
                            blurRadius: 8,
                            offset: const Offset(0, 3),
                          ),
                        ]
                      : null,
                ),
                child: Text(
                  '$dayNum',
                  style: GoogleFonts.cairo(
                    fontWeight: FontWeight.w800,
                    fontSize: 13,
                    color: !enabled
                        ? AppColors.muted.withValues(alpha: 0.35)
                        : isEndpoint
                            ? Colors.white
                            : inRange
                                ? AppColors.skyDark
                                : AppColors.navy,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  static bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;
}
