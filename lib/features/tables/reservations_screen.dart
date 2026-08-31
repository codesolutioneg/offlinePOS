import 'package:flutter/material.dart';

import '../../core/db/reservation_store.dart';
import '../../core/db/table_store.dart';
import '../../core/i18n/l10n.dart';
import '../../core/theme/app_colors.dart';
import '../../core/widgets/feedback.dart';

/// A wall-clock time on today or tomorrow, as UTC. Null when it is not a time.
///
/// A time that has already gone today is read as the next time the clock shows it,
/// the way an alarm does. A kitchen serving past midnight takes a booking at 23:50
/// for 00:10, and filing that as ten past midnight this morning puts it most of a
/// day in the past: it never appears on the floor, never comes due, and the guests
/// arrive to a table nobody held. Nobody books a table for a time that has been and
/// gone, so there is no other reading to lose. The tomorrow toggle still means
/// tomorrow, for a booking taken in the afternoon for the next evening.
///
/// Top level so the rule can be tested without a clock. The screen it belongs to
/// reads the time through it.
DateTime? reservationTimeFrom(String raw, DateTime now, {required bool tomorrow}) {
  final parts = raw.trim().split(':');
  if (parts.length != 2) return null;
  final h = int.tryParse(parts[0]);
  final m = int.tryParse(parts[1]);
  if (h == null || m == null || h < 0 || h > 23 || m < 0 || m > 59) return null;
  final day = tomorrow ? now.add(const Duration(days: 1)) : now;
  var when = DateTime(day.year, day.month, day.day, h, m);
  if (!tomorrow && when.isBefore(now)) {
    when = when.add(const Duration(days: 1));
  }
  return when.toUtc();
}

/// The book: who is coming, when, and where they are being put.
///
/// A local list and nothing else. Taking a booking over the phone must work with
/// the line down, and the shop LAN carries it to the other devices when there are
/// any, so this screen never waits on anything.
class ReservationsScreen extends StatefulWidget {
  const ReservationsScreen({
    super.key,
    required this.store,
    this.tables,
    this.nowFn = DateTime.now,
  });

  final ReservationStore store;

  /// The floor, so a booking is put on a real table rather than a typed name that
  /// matches nothing. Null leaves the field free text.
  final TableStore? tables;

  final DateTime Function() nowFn;

  @override
  State<ReservationsScreen> createState() => _ReservationsScreenState();
}

class _ReservationsScreenState extends State<ReservationsScreen> {
  /// From two hours back, so a table whose guests are late is still on the list
  /// somebody can act on, out to the end of tomorrow for a booking taken ahead.
  List<Reservation> get _book {
    final now = widget.nowFn().toUtc();
    return widget.store
        .between(now.subtract(const Duration(hours: 2)), now.add(const Duration(days: 2)));
  }

  Future<void> _add() async {
    final made = await _edit(title: tr(context, 'New booking'));
    if (made == null) return;
    widget.store.save(made);
    setState(() {});
  }

  Future<void> _open(Reservation r) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            title: Text('${r.name} (${r.covers})',
                style: const TextStyle(fontWeight: FontWeight.bold)),
            subtitle: Text([
              _clock(r.at),
              if (r.tableLabel != null) r.tableLabel!,
              if (r.phone != null) r.phone!,
            ].join('  ')),
          ),
          if (r.isOpen)
            ListTile(
              key: const Key('reservation-seat'),
              leading: const Icon(Icons.event_seat),
              title: Text(tr(ctx, 'Seated')),
              onTap: () => Navigator.pop(ctx, 'seated'),
            ),
          if (r.isOpen)
            ListTile(
              key: const Key('reservation-noshow'),
              leading: const Icon(Icons.person_off_outlined),
              title: Text(tr(ctx, 'Did not turn up')),
              onTap: () => Navigator.pop(ctx, 'noshow'),
            ),
          ListTile(
            key: const Key('reservation-edit'),
            leading: const Icon(Icons.edit),
            title: Text(tr(ctx, 'Edit')),
            onTap: () => Navigator.pop(ctx, 'edit'),
          ),
          ListTile(
            key: const Key('reservation-cancel'),
            leading: const Icon(Icons.event_busy, color: Colors.red),
            title: Text(tr(ctx, 'Cancel booking')),
            onTap: () => Navigator.pop(ctx, 'cancelled'),
          ),
        ]),
      ),
    );
    if (action == null || !mounted) return;
    switch (action) {
      case 'seated':
        widget.store.setState(r.uuid, ReservationState.seated);
      case 'noshow':
        widget.store.setState(r.uuid, ReservationState.noShow);
      case 'cancelled':
        widget.store.setState(r.uuid, ReservationState.cancelled);
      case 'edit':
        final changed = await _edit(title: tr(context, 'Booking'), initial: r);
        if (changed != null) widget.store.save(changed);
    }
    if (mounted) setState(() {});
  }

  /// The one form, for a new booking and for changing one. Returns null when it is
  /// backed out of.
  Future<Reservation?> _edit({required String title, Reservation? initial}) {
    final now = widget.nowFn();
    final name = TextEditingController(text: initial?.name ?? '');
    final phone = TextEditingController(text: initial?.phone ?? '');
    final covers = TextEditingController(text: '${initial?.covers ?? 2}');
    final at = (initial?.at ?? now.toUtc()).toLocal();
    final time = TextEditingController(text: _hhmm(at));
    var table = initial?.tableLabel;
    var tomorrow = initial != null &&
        at.day != now.day &&
        at.isAfter(now);
    final names = widget.tables?.all().where((t) => !t.isDivider).map((t) => t.name).toList() ??
        const <String>[];
    return showDialog<Reservation>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: Text(title),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(
                key: const Key('reservation-name'),
                controller: name,
                autofocus: true,
                decoration: InputDecoration(
                    labelText: tr(ctx, 'Name'), border: const OutlineInputBorder()),
              ),
              const SizedBox(height: 10),
              TextField(
                key: const Key('reservation-phone'),
                controller: phone,
                keyboardType: TextInputType.phone,
                decoration: InputDecoration(
                    labelText: tr(ctx, 'Phone'), border: const OutlineInputBorder()),
              ),
              const SizedBox(height: 10),
              Row(children: [
                Expanded(
                  child: TextField(
                    key: const Key('reservation-time'),
                    controller: time,
                    decoration: InputDecoration(
                        labelText: tr(ctx, 'Time (HH:MM)'),
                        border: const OutlineInputBorder()),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: TextField(
                    key: const Key('reservation-covers'),
                    controller: covers,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                        labelText: tr(ctx, 'Covers'),
                        border: const OutlineInputBorder()),
                  ),
                ),
              ]),
              const SizedBox(height: 10),
              // A day is enough: a till takes tonight's and tomorrow's bookings, and
              // anything further out belongs in a diary, not on the counter.
              SegmentedButton<bool>(
                key: const Key('reservation-day'),
                segments: [
                  ButtonSegment(value: false, label: Text(tr(ctx, 'Today'))),
                  ButtonSegment(value: true, label: Text(tr(ctx, 'Tomorrow'))),
                ],
                selected: {tomorrow},
                onSelectionChanged: (s) => setLocal(() => tomorrow = s.first),
              ),
              const SizedBox(height: 10),
              if (names.isEmpty)
                const SizedBox.shrink()
              else
                DropdownButtonFormField<String?>(
                  key: const Key('reservation-table'),
                  initialValue: names.contains(table) ? table : null,
                  decoration: InputDecoration(
                      labelText: tr(ctx, 'Table'),
                      border: const OutlineInputBorder()),
                  items: [
                    DropdownMenuItem<String?>(
                        value: null, child: Text(tr(ctx, 'No table yet'))),
                    for (final n in names)
                      DropdownMenuItem<String?>(value: n, child: Text(n)),
                  ],
                  onChanged: (v) => setLocal(() => table = v),
                ),
            ]),
          ),
          actions: [
            if (initial != null)
              TextButton(
                key: const Key('reservation-delete'),
                onPressed: () {
                  widget.store.remove(initial.uuid);
                  Navigator.pop(ctx);
                },
                child: Text(tr(ctx, 'Delete'),
                    style: const TextStyle(color: Colors.red)),
              ),
            TextButton(
                onPressed: () => Navigator.pop(ctx), child: Text(tr(ctx, 'Cancel'))),
            FilledButton(
              key: const Key('reservation-save'),
              onPressed: () {
                final who = name.text.trim();
                final when = _parseTime(time.text, now, tomorrow: tomorrow);
                if (who.isEmpty || when == null) {
                  showToast(ctx, tr(ctx, 'A name and a time like 19:30'),
                      kind: ToastKind.error);
                  return;
                }
                Navigator.pop(
                  ctx,
                  (initial ?? Reservation(name: who, at: when)).copyWith(
                    name: who,
                    phone: phone.text.trim().isEmpty ? null : phone.text.trim(),
                    covers: int.tryParse(covers.text.trim()) ?? 2,
                    at: when,
                    tableLabel: table,
                    clearTable: table == null,
                  ),
                );
              },
              child: Text(tr(ctx, 'Save')),
            ),
          ],
        ),
      ),
    );
  }

  static DateTime? _parseTime(String raw, DateTime now, {required bool tomorrow}) =>
      reservationTimeFrom(raw, now, tomorrow: tomorrow);

  static String _hhmm(DateTime local) =>
      '${local.hour.toString().padLeft(2, '0')}:'
      '${local.minute.toString().padLeft(2, '0')}';

  String _clock(DateTime utc) => _hhmm(utc.toLocal());

  @override
  Widget build(BuildContext context) {
    final book = _book;
    return Scaffold(
      appBar: AppBar(title: Text(tr(context, 'Reservations'))),
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('reservation-add'),
        onPressed: _add,
        icon: const Icon(Icons.add),
        label: Text(tr(context, 'Booking')),
      ),
      body: book.isEmpty
          ? Center(
              key: const Key('reservations-empty'),
              child: Text(tr(context, 'Nothing booked')),
            )
          : ListView.separated(
              itemCount: book.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, i) {
                final r = book[i];
                return ListTile(
                  key: Key('reservation-${r.uuid}'),
                  leading: CircleAvatar(
                    backgroundColor: r.isOpen
                        ? AppColors.primary.withValues(alpha: 0.15)
                        : Colors.black12,
                    child: Text(_clock(r.at), style: const TextStyle(fontSize: 11)),
                  ),
                  title: Text('${r.name}  (${r.covers})'),
                  subtitle: Text([
                    if (r.tableLabel != null) r.tableLabel!,
                    if (r.phone != null) r.phone!,
                    if (!r.isOpen) tr(context, _stateLabel(r.state)),
                  ].join('  ')),
                  onTap: () => _open(r),
                );
              },
            ),
    );
  }

  static String _stateLabel(ReservationState s) => switch (s) {
        ReservationState.booked => 'Booked',
        ReservationState.seated => 'Seated',
        ReservationState.cancelled => 'Cancelled',
        ReservationState.noShow => 'Did not turn up',
      };
}
