import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/db/reservation_store.dart';
import '../../core/db/settings_store.dart';
import '../../core/db/table_store.dart';
import '../../core/i18n/l10n.dart';
import '../../core/theme/app_colors.dart';
import '../../core/widgets/feedback.dart';
import '../../domain/order.dart' show OrderType, OrderTypeLabel;
import 'reservations_screen.dart';
import '../../core/theme/table_palette.dart';

/// The floor plan: tables drawn where the shop placed them, tapped to start or
/// recall a dine-in order. In edit mode a manager lays the floor out by dragging
/// tables around a visible grid, picking a shape per table, adding sections, and
/// dropping wall/divider bars to mark off an aisle or a section.
///
/// This is the restaurant view the app was missing. It reads the local table store
/// so it works with no network, and it colours a table by whether it currently has
/// an order parked on it, which is what tells a waiter at a glance what is free.
class TableFloorScreen extends StatefulWidget {
  const TableFloorScreen({
    super.key,
    required this.store,
    required this.occupiedLabels,
    required this.onOpenTable,
    this.occupiedInfo = const {},
    this.formatAmount,
    this.pickMode = false,
    this.exclude,
    this.onTakeaway,
    this.onDelivery,
    this.onToGo,
    this.seatTypes = const [OrderType.dineIn],
    this.sectionsAtSide = true,
    this.settings,
    this.onTransferTables,
    this.authorize,
    this.reservations,
    this.nowFn = DateTime.now,
    this.dayNotice,
    this.parkedNotice,
    this.blockNewOrders = false,
    this.drawer,
    this.shiftOpen,
    this.onOpenShift,
    this.onSignOut,
    this.section,
    this.onSectionChanged,
    this.seatAs,
    this.onSeatAsChanged,
  });

  /// The room to open on, and the way back up to whoever remembers it.
  ///
  /// The floor is home, and home swaps this whole screen out for the counter on
  /// every order, so anything held here alone is gone by the time the waiter is
  /// back. A waiter working the Terrace was being dropped onto the first section
  /// after every single order because of it. Null (the picker, and the suites that
  /// only draw the plan) keeps the old behaviour: first section, remembered by
  /// nobody.
  final String? section;
  final void Function(String? section)? onSectionChanged;

  /// What the next free-table tap seats, and the way back up to whoever remembers
  /// it. Lifted for the same reason [section] is: the chip a waiter set before
  /// walking to the counter has to still be set when they come back.
  final OrderType? seatAs;
  final void Function(OrderType seatAs)? onSeatAsChanged;

  /// The app shell's navigation drawer. The floor is the till's home screen, so it
  /// carries the same drawer the counter does: support, reprints, reports and the
  /// shift screen are all one tap away from the room. Null on the picker and in the
  /// suites that only draw the plan, which have nowhere to navigate to.
  final Widget? drawer;

  /// Whether a cash-drawer shift is open, read on every build so opening one and
  /// coming straight back lifts the block with no restart. Null (the picker) gates
  /// nothing.
  final bool Function()? shiftOpen;

  /// Opens the shift screen from the floor's own refusal strip. Null hides the
  /// button rather than showing one that goes nowhere.
  final VoidCallback? onOpenShift;

  /// Hands the till back. Unconditional because the counter is always parked
  /// before the floor is shown, so there is never a half-rung sale to lose; the
  /// floor is home, so without this a cashier who cannot sell could not leave.
  final VoidCallback? onSignOut;

  /// What another till has said about the trading day, shown as a strip above the
  /// plan. Null on a one-till shop and whenever nothing has been said, which is the
  /// ordinary case.
  final String? dayNotice;

  /// The confirmation for a bill that was just parked, shown as a strip above the
  /// plan. Above and not a toast: a toast sits at the bottom of the screen, which
  /// here is the To go / Takeaway / Delivery row, so it covered the button a cashier
  /// taps next. Null the rest of the time, and the shell takes it away on its own.
  final String? parkedNotice;

  /// Whether starting NEW work is held while [dayNotice] stands. Never stops a tab
  /// that is already open from being opened and settled: food that has been ordered
  /// has to be payable whatever any policy says.
  final bool blockNewOrders;

  /// The book, so a table with guests due shortly says so on the plan rather than
  /// only in a list nobody has open. Null leaves the floor exactly as it was.
  final ReservationStore? reservations;

  final DateTime Function() nowFn;

  /// The on-device settings the floor itself owns (whether a tab asks before
  /// another cashier picks it up). Null hides the menu that edits them, which is
  /// what the table picker wants.
  final SettingsStore? settings;

  /// Move every tab one cashier is holding to another one, for the manager whose
  /// waiter went home mid-service. Null hides the action.
  final VoidCallback? onTransferTables;

  /// Clears the shell's permission gate before a floor rule is changed. Null (the
  /// picker, and the suites that only draw the plan) asks nobody, because nothing
  /// there can change a rule.
  final Future<bool> Function()? authorize;

  /// Start a takeaway, to-go or delivery order straight from the floor home, the
  /// ways an order begins without a table. Null hides the button (e.g. in pick
  /// mode). A to-go may also be seated, through [seatTypes]; this is the button for
  /// the one that is packed at the counter and carried straight out.
  final VoidCallback? onTakeaway;
  final VoidCallback? onDelivery;
  final VoidCallback? onToGo;

  /// The kinds of order a table tap may open, in offer order. One entry (the usual
  /// dine-in-only shop) draws no selector and every tap opens that type; two draw
  /// the seating selector above the plan, because a to-go that sits at a table is
  /// still a to-go and the waiter has to be able to say so before seating it.
  final List<OrderType> seatTypes;

  /// Draw the sections as a rail down the side rather than a strip along the top.
  final bool sectionsAtSide;

  final TableStore store;

  /// When true the screen is a table chooser, not the manager floor: the edit
  /// tools are hidden and a tap just reports the picked table. It is the same
  /// drawn plan, with the same section tabs and occupancy colours, so choosing a
  /// table to seat looks exactly like the floor the manager laid out.
  final bool pickMode;

  /// One table name to hide while picking (the source table when moving items to
  /// another one, so you cannot move a bill onto the table it is already on).
  final String? exclude;

  /// Table names that currently have a held order, so those tiles read as occupied.
  final Set<String> occupiedLabels;

  /// Per occupied table: its running total and when it was opened, so a waiter sees
  /// the bill and how long the table has been sitting straight off the floor.
  final Map<String, ({double total, DateTime since})> occupiedInfo;
  final String Function(double)? formatAmount;

  /// Start a new order on a free table, or recall the order parked on an occupied
  /// one. The shell decides which; this screen reports the tap and, with it, the
  /// kind of order the waiter chose to seat (the first of [seatTypes] until they
  /// pick another). Recalling ignores it: a parked bill keeps the type it was rung
  /// under whatever the selector says.
  final void Function(PosTable table, OrderType seatAs) onOpenTable;

  @override
  State<TableFloorScreen> createState() => _TableFloorScreenState();
}

class _TableFloorScreenState extends State<TableFloorScreen> {
  // A table occupies one whole slot on the grid; the drag snaps to this so two
  // tables can never end up half-overlapping.
  static const double _cell = 110;

  // The fine grid painted in edit mode, purely visual: it is what tells the
  // manager the floor is laid out on a grid rather than free-floating.
  static const double _gridStep = 20;

  final GlobalKey _canvasKey = GlobalKey();
  bool _editing = false;
  String? _section;
  Timer? _tick;

  /// The kind of order the next free-table tap opens. Held here rather than in the
  /// shell because the selector redraws with the plan, and the shell cannot repaint
  /// a pushed route.
  OrderType? _seatAs;

  /// A shop that seats nobody still reports dine-in on a tap; the shell refuses the
  /// seating either way, and an occupied table is recalled without reading this.
  OrderType get _seatType => widget.seatTypes.contains(_seatAs)
      ? _seatAs!
      : (widget.seatTypes.firstOrNull ?? OrderType.dineIn);

  /// No shift, no orders. Read per build, exactly as the counter reads it.
  bool get _noShift => widget.shiftOpen != null && !widget.shiftOpen!();

  // The grid cell the dragged table is currently hovering over, so the drop
  // target is visible before the manager lets go.
  ({int x, int y})? _hoverCell;

  @override
  void initState() {
    super.initState();
    // Seeded from the shell, which is what carried them across the trip to the
    // counter. Edit mode is deliberately NOT among them: it is a manager laying the
    // room out, and resuming it silently after a sale would put drag handles under
    // a waiter's fingers.
    _section = widget.section;
    _seatAs = widget.seatAs;
    // Re-render every 30s so the "sitting for N minutes" ages on occupied tables
    // keep counting up while the floor is open instead of freezing.
    if (widget.occupiedInfo.isNotEmpty) {
      _tick = Timer.periodic(const Duration(seconds: 30), (_) {
        if (mounted) setState(() {});
      });
    }
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  List<String> get _sections {
    final s = widget.store.sections();
    return s.isEmpty ? const ['Main'] : s;
  }

  String get _activeSection => _section ?? _sections.first;

  void _reload() {
    // Deleting the last table in a section makes that section vanish, so drop
    // back to a section that still exists rather than showing a blank floor.
    if (_section != null && !_sections.contains(_section)) {
      _setSection(null);
      return;
    }
    setState(() {});
  }

  /// Open [name] and tell the shell, which is what remembers it while the counter
  /// is up. Null means "whichever section is first", the resting state.
  void _setSection(String? name) {
    setState(() => _section = name);
    widget.onSectionChanged?.call(name);
  }

  /// Set what the next table tap seats, and tell the shell for the same reason.
  void _setSeatAs(OrderType type) {
    setState(() => _seatAs = type);
    widget.onSeatAsChanged?.call(type);
  }

  Future<void> _addTable() async {
    final result = await _tableDialog(title: tr(context, 'Add table'));
    if (result == null) return;
    widget.store.add(
      name: result.name,
      seats: result.seats,
      section: _activeSection,
      shape: result.shape,
      // Drop a new table at the top-left; the manager drags it into place.
      x: 0,
      y: 0,
    );
    _reload();
  }

  /// Drop a wall/divider bar on the floor. It is a `pos_tables` row like any
  /// other so it lives in the same section, drags on the same grid, and is
  /// deleted the same way, but it seats nobody and is never opened for an order.
  void _addDivider() {
    widget.store.add(
      name: widget.store.uniqueName('Wall'),
      seats: 0,
      section: _activeSection,
      shape: TableShape.divider,
      x: 0,
      y: 0,
    );
    _reload();
  }

  Future<void> _editTable(PosTable t) async {
    final result =
        await _tableDialog(title: '${tr(context, 'Table')} ${t.name}', initial: t);
    if (result == null) return;
    if (result.delete) {
      if (!mounted) return;
      final confirmed = await _confirmDeleteTable(t.name);
      if (confirmed != true || !mounted) return;
      widget.store.remove(t.id);
    } else {
      // Keep names unique so an order is never recalled onto the wrong table; a
      // rename that would collide is suffixed rather than silently duplicated.
      final name = result.name == t.name ? t.name : widget.store.uniqueName(result.name);
      widget.store.upsert(t.copyWith(
        name: name,
        seats: result.seats,
        shape: result.shape,
        vertical: result.vertical,
        span: result.span,
      ));
    }
    _reload();
  }

  /// A table removed here is gone with no trace, so a manager confirms before
  /// [TableStore.remove] rather than losing the tile on a mistap of the delete
  /// button next to the dialog's own save action.
  Future<bool?> _confirmDeleteTable(String name) => showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text('${tr(ctx, 'Delete table')} $name?'),
          content: Text(tr(ctx, 'This removes the table from the floor.')),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr(ctx, 'Cancel'))),
            FilledButton(
              key: const Key('confirm-delete-table'),
              style: FilledButton.styleFrom(backgroundColor: AppColors.error),
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(tr(ctx, 'Delete')),
            ),
          ],
        ),
      );

  Future<void> _addSection() async {
    final ctrl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr(ctx, 'New section')),
        content: TextField(
          key: const Key('section-name'),
          controller: ctrl,
          autofocus: true,
          decoration: InputDecoration(
              labelText: tr(ctx, 'Section name (e.g. Terrace)'),
              border: const OutlineInputBorder()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr(ctx, 'Cancel'))),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
              child: Text(tr(ctx, 'Add'))),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    // A section exists once it has a table, so seed it with one.
    widget.store.add(name: 'T1', section: name, seats: 4);
    _setSection(name);
  }

  String _shapeLabel(BuildContext context, TableShape s) {
    switch (s) {
      case TableShape.round:
        return tr(context, 'Round');
      case TableShape.rectangle:
        return tr(context, 'Rectangle');
      case TableShape.square:
      case TableShape.divider:
        return tr(context, 'Square');
    }
  }

  Future<_TableEdit?> _tableDialog({required String title, PosTable? initial}) {
    final nameCtrl = TextEditingController(text: initial?.name ?? '');
    final seatsCtrl = TextEditingController(text: '${initial?.seats ?? 4}');
    final isDivider = initial?.isDivider ?? false;
    var shape = initial?.shape ?? TableShape.square;
    // Divider geometry: kept in dialog state so the +/- stepper and the
    // orientation chips update the same values the Save action writes back.
    var vertical = initial?.vertical ?? false;
    var span = initial?.span ?? 140;
    return showDialog<_TableEdit>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text(title),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(
              key: const Key('table-name'),
              controller: nameCtrl,
              autofocus: true,
              decoration: InputDecoration(
                  labelText: tr(ctx, 'Name / number'), border: const OutlineInputBorder()),
            ),
            // A divider seats nobody and has a fixed shape, so neither field
            // applies to one; keep the dialog to just its name.
            if (!isDivider) ...[
              const SizedBox(height: 8),
              TextField(
                key: const Key('table-seats'),
                controller: seatsCtrl,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                    labelText: tr(ctx, 'Seats'), border: const OutlineInputBorder()),
              ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(tr(ctx, 'Shape'), style: Theme.of(ctx).textTheme.labelMedium),
              ),
              const SizedBox(height: 4),
              Wrap(
                spacing: 8,
                children: [
                  for (final s in const [
                    TableShape.square,
                    TableShape.round,
                    TableShape.rectangle,
                  ])
                    ChoiceChip(
                      key: Key('shape-${s.name}'),
                      label: Text(_shapeLabel(ctx, s)),
                      selected: shape == s,
                      onSelected: (_) => setDialogState(() => shape = s),
                    ),
                ],
              ),
            ],
            // A divider carries no seats or shape, but it does have an
            // orientation and a length the manager sets here.
            if (isDivider) ...[
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(tr(ctx, 'Orientation'),
                    style: Theme.of(ctx).textTheme.labelMedium),
              ),
              const SizedBox(height: 4),
              Wrap(spacing: 8, children: [
                ChoiceChip(
                  key: const Key('orient-horizontal'),
                  label: Text(tr(ctx, 'Horizontal')),
                  selected: !vertical,
                  onSelected: (_) => setDialogState(() => vertical = false),
                ),
                ChoiceChip(
                  key: const Key('orient-vertical'),
                  label: Text(tr(ctx, 'Vertical')),
                  selected: vertical,
                  onSelected: (_) => setDialogState(() => vertical = true),
                ),
              ]),
              const SizedBox(height: 8),
              Row(children: [
                Text(tr(ctx, 'Length'), style: Theme.of(ctx).textTheme.labelMedium),
                const Spacer(),
                IconButton(
                  key: const Key('divider-shorter'),
                  icon: const Icon(Icons.remove_circle_outline),
                  // Clamp to a floor so a wall can never shrink to an untappable
                  // sliver, and step in whole grid-ish increments.
                  onPressed: () => setDialogState(() => span = (span - 40).clamp(60, 400)),
                ),
                Text('$span'),
                IconButton(
                  key: const Key('divider-longer'),
                  icon: const Icon(Icons.add_circle_outline),
                  onPressed: () => setDialogState(() => span = (span + 40).clamp(60, 400)),
                ),
              ]),
            ],
          ]),
          actions: [
            if (initial != null)
              TextButton(
                key: const Key('table-delete'),
                onPressed: () => Navigator.pop(ctx, const _TableEdit.remove()),
                child: Text(tr(ctx, 'Delete'), style: const TextStyle(color: Colors.red)),
              ),
            TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr(ctx, 'Cancel'))),
            FilledButton(
              key: const Key('table-save'),
              onPressed: () {
                final name = nameCtrl.text.trim();
                if (name.isEmpty) return;
                Navigator.pop(
                  ctx,
                  _TableEdit(
                    name: name,
                    seats: isDivider ? 0 : (int.tryParse(seatsCtrl.text.trim()) ?? 4),
                    shape: isDivider ? TableShape.divider : shape,
                    vertical: vertical,
                    span: span,
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

  /// The grid cell under a global drag position, clamped to the floor bounds.
  ({int x, int y})? _cellAt(Offset globalOffset) {
    final box = _canvasKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return null;
    final local = box.globalToLocal(globalOffset);
    // Snap to the grid so the floor stays tidy and two tables cannot half-overlap.
    final gx = (local.dx / _cell).clamp(0, 20).round();
    final gy = (local.dy / _cell).clamp(0, 20).round();
    return (x: gx, y: gy);
  }

  void _hover(Offset globalOffset) {
    final cell = _cellAt(globalOffset);
    if (cell != _hoverCell) setState(() => _hoverCell = cell);
  }

  void _dropAt(PosTable t, Offset globalOffset) {
    final cell = _cellAt(globalOffset);
    _hoverCell = null;
    if (cell == null) return;
    widget.store.upsert(t.copyWith(x: cell.x.toDouble(), y: cell.y.toDouble()));
    _reload();
  }

  /// Prompt for a table not drawn on the floor and pop the picker with it, so a
  /// one-off table (a pushed-together pair, an outdoor extra) is still reachable.
  Future<void> _pickOther() async {
    final ctrl = TextEditingController();
    final label = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr(ctx, 'Other table')),
        content: TextField(
          key: const Key('other-table-field'),
          controller: ctrl,
          autofocus: true,
          decoration: InputDecoration(
              labelText: tr(ctx, 'Table name / number'), border: const OutlineInputBorder()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr(ctx, 'Cancel'))),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
              child: Text(tr(ctx, 'Set'))),
        ],
      ),
    );
    // Cancel (null) does nothing; an empty value is reported so the set-table flow
    // can clear a table assigned by mistake (setTable('')). A tile tap and this
    // share the one callback; the shell pops the picker with the name.
    if (!mounted || label == null) return;
    widget.onOpenTable(PosTable(id: 'custom', name: label), _seatType);
  }

  @override
  Widget build(BuildContext context) {
    final tables = widget.store
        .inSection(_activeSection)
        .where((t) => widget.exclude == null || t.name != widget.exclude)
        .toList();
    return Scaffold(
      drawer: widget.drawer,
      appBar: AppBar(
        title: Text(tr(context, widget.pickMode ? 'Choose a table' : 'Tables')),
        actions: [
          if (widget.pickMode)
            TextButton.icon(
              key: const Key('pick-other'),
              onPressed: _pickOther,
              icon: const Icon(Icons.edit_note),
              label: Text(tr(context, 'Other')),
            )
          else ...[
            IconButton(
              key: const Key('toggle-edit'),
              tooltip: _editing ? tr(context, 'Done') : tr(context, 'Edit floor'),
              icon: Icon(_editing ? Icons.check : Icons.edit),
              onPressed: () => setState(() => _editing = !_editing),
            ),
            if (widget.settings != null ||
                widget.onTransferTables != null ||
                widget.reservations != null)
              _floorMenu(),
            if (widget.onSignOut != null)
              TextButton.icon(
                key: const Key('sign-out'),
                onPressed: widget.onSignOut,
                icon: const Icon(Icons.logout),
                label: Text(tr(context, 'End shift')),
              ),
          ],
        ],
      ),
      floatingActionButton: _editing && !widget.pickMode
          ? Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                FloatingActionButton.extended(
                  key: const Key('add-divider'),
                  heroTag: null,
                  onPressed: _addDivider,
                  icon: const Icon(Icons.horizontal_rule),
                  label: Text(tr(context, 'Divider')),
                ),
                const SizedBox(height: 8),
                FloatingActionButton.extended(
                  key: const Key('add-table'),
                  heroTag: null,
                  onPressed: _addTable,
                  icon: const Icon(Icons.add),
                  label: Text(tr(context, 'Table')),
                ),
              ],
            )
          : null,
      body: Column(
        children: [
          // Above the day notice: with no drawer open nothing can be rung at all,
          // which outranks anything another till has to say about the day.
          if (_noShift) _noShiftStrip(),
          if (widget.dayNotice case final notice?) _dayNoticeStrip(notice),
          if (widget.parkedNotice case final parked?) _parkedStrip(parked),
          // The sections moved to the side, so the room above the plan is where the
          // waiter now says what they are seating.
          if (widget.seatTypes.length > 1) _seatTypeStrip(),
          if (!widget.sectionsAtSide) _sectionStrip(),
          if (widget.pickMode) _legend(),
          const Divider(height: 1),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (widget.sectionsAtSide) ...[
                  _sectionRail(),
                  const VerticalDivider(width: 1),
                ],
                Expanded(
                  child: tables.isEmpty
                      ? _emptyFloor()
                      : InteractiveViewer(
                          constrained: false,
                          minScale: 0.5,
                          maxScale: 2.5,
                          child: _canvas(tables),
                        ),
                ),
              ],
            ),
          ),
          if (!widget.pickMode && !_editing) _tablelessRow(),
        ],
      ),
    );
  }

  /// The bill that was just parked, said at the top of the plan where the tile it
  /// landed on is about to read as occupied, and clear of the button row.
  Widget _parkedStrip(String notice) => Material(
        key: const Key('floor-parked-notice'),
        color: AppColors.success,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(children: [
            const Icon(Icons.check_circle, size: 18, color: Colors.white),
            const SizedBox(width: 8),
            Expanded(
                child: Text(notice, style: const TextStyle(color: Colors.white))),
          ]),
        ),
      );

  /// The day closed somewhere else in the shop, said on the screen where new work
  /// starts rather than in a dialog that gets dismissed unread.
  Widget _dayNoticeStrip(String notice) => Material(
        key: const Key('floor-day-notice'),
        color: widget.blockNewOrders ? AppColors.error : AppColors.warning,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(children: [
            const Icon(Icons.nightlight_round, size: 18, color: Colors.white),
            const SizedBox(width: 8),
            Expanded(
                child: Text(notice, style: const TextStyle(color: Colors.white))),
          ]),
        ),
      );

  /// What the floor says when no shift has been opened yet.
  ///
  /// A strip and not a dialog, and not a screen that replaces the plan: the room
  /// still has to be readable while somebody goes and opens the drawer. Nothing on
  /// this screen is locked away by it except starting or picking up an order, which
  /// is the one thing a till with no shift must not do.
  Widget _noShiftStrip() => Material(
        key: const Key('floor-no-shift'),
        color: AppColors.error,
        child: SafeArea(
          bottom: false,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Row(children: [
              const Icon(Icons.point_of_sale, size: 18, color: Colors.white),
              const SizedBox(width: 8),
              Expanded(
                child: Text(_noShiftMessage,
                    style: const TextStyle(color: Colors.white)),
              ),
              if (widget.onOpenShift != null)
                FilledButton(
                  key: const Key('floor-open-shift'),
                  style: FilledButton.styleFrom(
                      backgroundColor: Colors.white,
                      foregroundColor: AppColors.error),
                  onPressed: widget.onOpenShift,
                  child: Text(tr(context, 'Open shift')),
                ),
            ]),
          ),
        ),
      );

  String get _noShiftMessage => tr(context,
      'No shift is open. Open one before you start an order.');

  /// Whether opening an order is refused right now, saying why when it is.
  ///
  /// The shift comes first and covers every tile, free or occupied: with no drawer
  /// open the counter refuses to ring OR settle anything, so letting a tab through
  /// here would only land the waiter on a screen that says no. The day-close hold is
  /// narrower and only stops new work, which is why it is asked second.
  bool _orderingHeld({required bool newWork}) {
    if (_noShift) {
      showToast(context, _noShiftMessage, kind: ToastKind.error);
      return true;
    }
    return newWork && _newWorkHeld();
  }

  /// The ways an order starts with no table: packed at the counter and carried out.
  /// A shop that offers none of them (a pure dine-in room) gets no row at all.
  Widget _tablelessRow() {
    final buttons = <Widget>[
      if (widget.onToGo != null)
        _tablelessButton(
            key: 'floor-to-go',
            icon: Icons.shopping_bag_outlined,
            label: tr(context, 'To go'),
            onPressed: widget.onToGo!),
      if (widget.onTakeaway != null)
        _tablelessButton(
            key: 'floor-takeaway',
            icon: Icons.takeout_dining,
            label: tr(context, 'Takeaway'),
            onPressed: widget.onTakeaway!),
      if (widget.onDelivery != null)
        _tablelessButton(
            key: 'floor-delivery',
            icon: Icons.delivery_dining,
            label: tr(context, 'Delivery'),
            onPressed: widget.onDelivery!),
    ];
    if (buttons.isEmpty) return const SizedBox.shrink();
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
        child: Row(children: [
          for (var i = 0; i < buttons.length; i++) ...[
            if (i > 0) const SizedBox(width: 10),
            Expanded(child: buttons[i]),
          ],
        ]),
      ),
    );
  }

  Widget _tablelessButton({
    required String key,
    required IconData icon,
    required String label,
    required VoidCallback onPressed,
  }) =>
      FilledButton.icon(
        key: Key(key),
        onPressed: () {
          if (!_orderingHeld(newWork: true)) onPressed();
        },
        icon: Icon(icon),
        // Three buttons on a narrow till is a tight row, so the label shrinks
        // rather than wrapping into an ellipsis nobody can read.
        label: FittedBox(fit: BoxFit.scaleDown, child: Text(label)),
      );

  /// What the next free table opens. Only drawn when the shop seats more than one
  /// kind of order: a to-go that sits down while it is packed occupies the floor
  /// exactly like a dine-in, and the only thing that says which it is is this.
  Widget _seatTypeStrip() => Material(
        color: Colors.grey.shade100,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
          child: Row(children: [
            Text(tr(context, 'Seat as'),
                style: Theme.of(context).textTheme.labelMedium),
            const SizedBox(width: 10),
            Expanded(
              child: Wrap(spacing: 8, children: [
                for (final t in widget.seatTypes)
                  ChoiceChip(
                    key: Key('seat-as-${t.name.toLowerCase()}'),
                    label: Text(tr(context, t.label)),
                    selected: _seatType == t,
                    onSelected: (_) => _setSeatAs(t),
                  ),
              ]),
            ),
          ]),
        ),
      );

  /// Whether starting something new is held right now, telling the cashier why when
  /// it is. A tab already open is never held: it is settled through the tile, which
  /// does not come through here.
  bool _newWorkHeld() {
    if (!widget.blockNewOrders) return false;
    showToast(context, widget.dayNotice ?? tr(context, 'The day is closed'),
        kind: ToastKind.error);
    return true;
  }

  /// The floor's own settings and the actions that go with them, on the screen a
  /// manager already opens to lay the room out rather than three menus away.
  Widget _floorMenu() {
    final settings = widget.settings;
    final book = widget.reservations;
    return PopupMenuButton<String>(
      key: const Key('floor-menu'),
      icon: const Icon(Icons.more_vert),
      onSelected: (value) async {
        if (value == 'security' && settings != null) {
          // Behind the same gate as any other setting: a cashier who could switch
          // this off could then open anybody's tab, which is the one thing it
          // exists to stop.
          if (!(await widget.authorize?.call() ?? true)) return;
          if (!mounted) return;
          setState(() => settings.tableSecurity = !settings.tableSecurity);
        } else if (value == 'transfer') {
          widget.onTransferTables?.call();
        } else if (value == 'reservations' && book != null) {
          await Navigator.of(context).push(MaterialPageRoute<void>(
            builder: (_) => ReservationsScreen(
                store: book, tables: widget.store, nowFn: widget.nowFn),
          ));
          // The badges on the plan are read from the book, so coming back from it
          // has to repaint them.
          if (mounted) setState(() {});
        }
      },
      itemBuilder: (ctx) => [
        if (book != null)
          PopupMenuItem(
            key: const Key('floor-reservations'),
            value: 'reservations',
            child: Text(tr(ctx, 'Reservations')),
          ),
        if (settings != null)
          CheckedPopupMenuItem(
            key: const Key('floor-table-security'),
            value: 'security',
            checked: settings.tableSecurity,
            child: Text(tr(ctx, 'Ask before opening someone else\'s tab')),
          ),
        if (widget.onTransferTables != null)
          PopupMenuItem(
            key: const Key('floor-transfer-tables'),
            value: 'transfer',
            child: Text(tr(ctx, 'Transfer tables')),
          ),
      ],
    );
  }

  Future<void> _sectionMenu(String section) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            key: const Key('section-rename'),
            leading: const Icon(Icons.edit),
            title: Text(tr(ctx, 'Rename section')),
            onTap: () => Navigator.pop(ctx, 'rename'),
          ),
          ListTile(
            key: const Key('section-delete'),
            leading: const Icon(Icons.delete_outline, color: Colors.red),
            title: Text(tr(ctx, 'Delete section and its tables')),
            onTap: () => Navigator.pop(ctx, 'delete'),
          ),
        ]),
      ),
    );
    if (!mounted) return;
    if (action == 'rename') {
      final ctrl = TextEditingController(text: section);
      final name = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(tr(ctx, 'Rename section')),
          content: TextField(
              key: const Key('section-rename-field'),
              controller: ctrl,
              autofocus: true,
              decoration: const InputDecoration(border: OutlineInputBorder())),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr(ctx, 'Cancel'))),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
                child: Text(tr(ctx, 'Save'))),
          ],
        ),
      );
      if (!mounted) return;
      if (name != null && name.isNotEmpty && name != section) {
        widget.store.renameSection(section, name);
        _setSection(name);
      }
    } else if (action == 'delete') {
      final confirmed = await _confirmDeleteSection(section);
      if (confirmed != true || !mounted) return;
      widget.store.deleteSection(section);
      _reload();
    }
  }

  /// Deleting a section takes every table in it with it, so the confirmation
  /// states the count up front rather than leaving the manager to discover the
  /// loss table by table.
  Future<bool?> _confirmDeleteSection(String section) {
    final count = widget.store.inSection(section).length;
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('${tr(ctx, 'Delete section')} \'$section\' ${tr(ctx, 'and its')} $count '
            '${tr(ctx, 'tables?')}'),
        content: Text(tr(ctx, 'This cannot be undone.')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr(ctx, 'Cancel'))),
          FilledButton(
            key: const Key('confirm-delete-section'),
            style: FilledButton.styleFrom(backgroundColor: AppColors.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr(ctx, 'Delete')),
          ),
        ],
      ),
    );
  }

  /// A Free/Occupied colour key, shown only while picking so a waiter reads the
  /// tile colours without guessing.
  Widget _legend() => Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
        child: Row(children: [
          _legendDot(TablePalette.shared.free, tr(context, 'Free')),
          const SizedBox(width: 14),
          _legendDot(TablePalette.shared.occupied, tr(context, 'Occupied')),
        ]),
      );

  Widget _legendDot(Color c, String label) => Row(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 12, height: 12, decoration: BoxDecoration(color: c, shape: BoxShape.circle)),
        const SizedBox(width: 5),
        Text(label, style: const TextStyle(fontSize: 12)),
      ]);

  /// The sections down the side of the plan, which is where the shop asked for
  /// them: a room list reads as a list, and a strip along the top pushed the far
  /// sections off the edge on a till that is wider than it is tall.
  ///
  /// Each room says how many tables it holds and how many of those are busy, so a
  /// waiter picks the room they are needed in without opening it first.
  Widget _sectionRail() => SizedBox(
        width: 108,
        child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          children: [
            for (final s in _sections) ...[
              _sectionRailTile(s),
              const SizedBox(height: 8),
            ],
            if (_editing)
              ActionChip(
                key: const Key('add-section'),
                avatar: const Icon(Icons.add, size: 16),
                label: Text(tr(context, 'Section')),
                onPressed: _addSection,
              ),
          ],
        ),
      );

  Widget _sectionRailTile(String s) {
    final selected = _activeSection == s;
    final inSection = widget.store.inSection(s).where((t) => !t.isDivider);
    final busy = inSection.where((t) => widget.occupiedLabels.contains(t.name)).length;
    final color = selected ? AppColors.primary : Colors.black26;
    return InkWell(
      // The same key the top strip uses, so a shop that moves the sections back to
      // the top does not change how the floor is driven.
      key: Key('section-${s.toLowerCase()}'),
      borderRadius: BorderRadius.circular(12),
      onTap: () => _setSection(s),
      // In edit mode a long-press renames or deletes the whole section, exactly as
      // it does on the top strip.
      onLongPress: _editing ? () => _sectionMenu(s) : null,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 10),
        decoration: BoxDecoration(
          color: selected ? AppColors.primary.withValues(alpha: 0.12) : null,
          border: Border.all(color: color, width: selected ? 2 : 1),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(children: [
          Text(
            s,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontWeight: selected ? FontWeight.bold : FontWeight.normal,
              color: selected ? AppColors.primary : null,
            ),
          ),
          const SizedBox(height: 2),
          Text('$busy/${inSection.length}',
              style: const TextStyle(fontSize: 11, color: Colors.black54)),
        ]),
      ),
    );
  }

  Widget _sectionStrip() => SizedBox(
        height: 48,
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          children: [
            for (final s in _sections) ...[
              GestureDetector(
                // In edit mode a long-press renames or deletes the whole section.
                onLongPress: _editing ? () => _sectionMenu(s) : null,
                child: ChoiceChip(
                  key: Key('section-${s.toLowerCase()}'),
                  label: Text(s),
                  selected: _activeSection == s,
                  onSelected: (_) => _setSection(s),
                ),
              ),
              const SizedBox(width: 6),
            ],
            if (_editing)
              ActionChip(
                key: const Key('add-section'),
                avatar: const Icon(Icons.add, size: 16),
                label: Text(tr(context, 'Section')),
                onPressed: _addSection,
              ),
          ],
        ),
      );

  /// The bookings due on each table right now, read on every build so the badge
  /// ages with the ticker rather than freezing when the floor opened.
  Map<String, Reservation> get _due =>
      widget.reservations?.dueByTable(widget.nowFn().toUtc()) ?? const {};

  Widget _canvas(List<PosTable> tables) {
    final maxX = tables.map((t) => t.x).fold(3.0, (a, b) => a > b ? a : b);
    final maxY = tables.map((t) => t.y).fold(3.0, (a, b) => a > b ? a : b);
    // A lengthened or vertical divider can reach past the grid cell it sits in, so
    // grow the canvas to cover its rendered span or it would be clipped at the edge.
    var width = (maxX + 2) * _cell;
    var height = (maxY + 2) * _cell;
    for (final t in tables.where((t) => t.isDivider)) {
      final w = t.vertical ? 40.0 : t.span.toDouble();
      final h = t.vertical ? t.span.toDouble() : 40.0;
      final right = t.x * _cell + w + 12;
      final bottom = t.y * _cell + h + 12;
      if (right > width) width = right;
      if (bottom > height) height = bottom;
    }
    final canvas = SizedBox(
      key: _canvasKey,
      width: width,
      height: height,
      child: Stack(
        children: [
          // A light grid so the manager can see the floor is laid out on a grid,
          // not just told so; it is what makes the drag-to-place feel exact.
          if (_editing) Positioned.fill(child: CustomPaint(painter: _GridPainter())),
          for (final t in tables)
            Positioned(
              left: t.x * _cell,
              top: t.y * _cell,
              child: _tile(t),
            ),
          if (_editing && _hoverCell != null)
            Positioned(
              key: const Key('drop-hover'),
              left: _hoverCell!.x * _cell,
              top: _hoverCell!.y * _cell,
              child: IgnorePointer(
                child: Container(
                  width: _cell,
                  height: _cell,
                  margin: const EdgeInsets.all(3),
                  decoration: BoxDecoration(
                    border: Border.all(color: AppColors.primary, width: 2),
                    borderRadius: BorderRadius.circular(12),
                    color: AppColors.primary.withValues(alpha: 0.08),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
    // In edit mode the whole canvas accepts a dragged table and drops it on the
    // grid cell under the pointer, which is what makes it a drawn layout.
    if (!_editing) return canvas;
    return DragTarget<PosTable>(
      onWillAcceptWithDetails: (d) {
        _hover(d.offset);
        return true;
      },
      onLeave: (_) => setState(() => _hoverCell = null),
      onAcceptWithDetails: (d) => _dropAt(d.data, d.offset),
      builder: (context, candidate, rejected) => canvas,
    );
  }

  Widget _tile(PosTable t) {
    final isDivider = t.isDivider;
    final occupied = !isDivider && widget.occupiedLabels.contains(t.name);
    final info = isDivider ? null : widget.occupiedInfo[t.name];
    final booking = isDivider ? null : _due[t.name];
    final tile = _TableTile(
      table: t,
      occupied: occupied,
      total: info == null ? null : widget.formatAmount?.call(info.total),
      ageMinutes: info == null ? null : DateTime.now().difference(info.since).inMinutes,
      // A free table with guests due in twenty minutes is not free, and a waiter
      // seating a walk-in on it is the mistake this badge exists to stop.
      booking: booking == null
          ? null
          : (
              at: booking.at.toLocal(),
              name: booking.name,
              covers: booking.covers,
            ),
    );
    if (!_editing) {
      // A wall/divider is never tapped to open an order; it is just drawn.
      if (isDivider) return tile;
      return InkWell(
        key: Key('table-tile-${t.id}'),
        // A free table is new work and can be held by the day-close policy; an
        // occupied one is a bill somebody is waiting to pay and never is. The
        // shift gate is above both and stops either.
        onTap: () {
          if (_orderingHeld(newWork: !occupied)) return;
          widget.onOpenTable(t, _seatType);
        },
        child: tile,
      );
    }
    // A long-press start (rather than an immediate drag) keeps the tile drag
    // from fighting the canvas's own pan/zoom gesture, which is what made moving
    // a table feel hard before: the two gestures were competing for the touch.
    return LongPressDraggable<PosTable>(
      key: Key('table-drag-${t.id}'),
      data: t,
      delay: const Duration(milliseconds: 150),
      feedback: Material(color: Colors.transparent, child: tile),
      childWhenDragging: Opacity(opacity: 0.3, child: tile),
      child: InkWell(
        key: Key('table-edit-${t.id}'),
        onTap: () => _editTable(t),
        child: tile,
      ),
    );
  }

  Widget _emptyFloor() => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.table_restaurant, size: 48, color: Colors.black26),
            const SizedBox(height: 8),
            Text(tr(context, 'No tables yet')),
            const SizedBox(height: 8),
            // While picking, laying out the floor is the wrong door: point to the
            // Other action instead so the chooser never traps the user in edit mode.
            if (widget.pickMode)
              Text(tr(context, 'Use Other to name a table.'),
                  style: const TextStyle(color: Colors.black54))
            else if (!_editing)
              FilledButton.icon(
                key: const Key('empty-edit'),
                onPressed: () => setState(() => _editing = true),
                icon: const Icon(Icons.edit),
                label: Text(tr(context, 'Set up the floor')),
              ),
          ],
        ),
      );
}

/// Paints the edit-mode floor grid: fine lines every [_TableFloorScreenState._gridStep]
/// so the surface reads as graph paper, and a darker line every table-slot cell
/// so a placed table's alignment is obvious at a glance.
class _GridPainter extends CustomPainter {
  const _GridPainter();

  static const double _minor = _TableFloorScreenState._gridStep;
  static const double _major = _TableFloorScreenState._cell;

  @override
  void paint(Canvas canvas, Size size) {
    final minorPaint = Paint()
      ..color = Colors.black.withValues(alpha: 0.04)
      ..strokeWidth = 1;
    final majorPaint = Paint()
      ..color = Colors.black.withValues(alpha: 0.10)
      ..strokeWidth = 1;

    for (double x = 0; x <= size.width; x += _minor) {
      final isMajor = (x % _major).abs() < 0.5;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), isMajor ? majorPaint : minorPaint);
    }
    for (double y = 0; y <= size.height; y += _minor) {
      final isMajor = (y % _major).abs() < 0.5;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), isMajor ? majorPaint : minorPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _GridPainter oldDelegate) => false;
}

class _TableTile extends StatelessWidget {
  const _TableTile({
    required this.table,
    required this.occupied,
    this.total,
    this.ageMinutes,
    this.booking,
  });
  final PosTable table;
  final bool occupied;
  final String? total;
  final int? ageMinutes;

  /// The guests due on this table shortly, in local wall-clock time. Null when
  /// nobody is expected, which is every table in a shop that takes no bookings.
  final ({DateTime at, String name, int covers})? booking;

  @override
  Widget build(BuildContext context) {
    if (table.isDivider) return _divider();

    // The shop's own two colours, which default to the green/red every floor has
    // been drawn in until a manager says otherwise.
    final palette = TablePalette.shared;
    final color = occupied ? palette.occupied : palette.free;
    final wide = table.shape == TableShape.rectangle;
    final round = table.shape == TableShape.round;
    return Container(
      // A rectangle is short rather than extra-wide so it still fits one grid slot
      // and cannot overlap the table snapped into the next cell.
      width: 100,
      height: wide ? 60 : 100,
      margin: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        border: Border.all(color: color, width: 2),
        borderRadius: round ? BorderRadius.circular(999) : BorderRadius.circular(12),
      ),
      // A short rectangle tile cannot fit the full name+seats+status stack at full
      // size, so scale the content down to fit rather than overflow the fixed
      // height. A square/round tile is roomy enough that nothing scales.
      child: Center(
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(table.name,
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
              const SizedBox(height: 2),
              Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                const Icon(Icons.event_seat, size: 13),
                const SizedBox(width: 2),
                Text('${table.seats}', style: const TextStyle(fontSize: 12)),
              ]),
              if (occupied && total != null)
                Text(total!,
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: color)),
              if (occupied && ageMinutes != null)
                Text('${ageMinutes}m',
                    style: const TextStyle(fontSize: 11, color: Colors.black54))
              else
                Text(occupied ? tr(context, 'Occupied') : tr(context, 'Free'),
                    style: TextStyle(fontSize: 11, color: color)),
              if (booking case final due?)
                Padding(
                  key: Key('table-booked-${table.id}'),
                  padding: const EdgeInsets.only(top: 2),
                  child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                    const Icon(Icons.schedule, size: 12, color: AppColors.warning),
                    const SizedBox(width: 2),
                    Text(
                      '${due.at.hour.toString().padLeft(2, '0')}:'
                      '${due.at.minute.toString().padLeft(2, '0')} ${due.name}',
                      style: const TextStyle(
                          fontSize: 11,
                          color: AppColors.warning,
                          fontWeight: FontWeight.bold),
                    ),
                  ]),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// A wall/divider draws as a plain bar with the table's name as a small label,
  /// never a colour that could be mistaken for an occupancy state. Its long side
  /// is [PosTable.span]; a vertical wall is the same bar rotated, so the label
  /// reads along it rather than spilling out of a thin column.
  Widget _divider() {
    const thickness = 18.0;
    final length = table.span.toDouble();
    final label = Text(table.name,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 10, color: Colors.white));
    return Container(
      width: table.vertical ? thickness : length,
      height: table.vertical ? length : thickness,
      margin: const EdgeInsets.symmetric(vertical: 6, horizontal: 6),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: Colors.grey.shade500,
        borderRadius: BorderRadius.circular(4),
      ),
      child: table.vertical ? RotatedBox(quarterTurns: 1, child: label) : label,
    );
  }
}

class _TableEdit {
  const _TableEdit({
    required this.name,
    required this.seats,
    this.shape = TableShape.square,
    this.vertical = false,
    this.span = 140,
  }) : delete = false;
  const _TableEdit.remove()
      : name = '',
        seats = 0,
        shape = TableShape.square,
        vertical = false,
        span = 140,
        delete = true;
  final String name;
  final int seats;
  final TableShape shape;
  // Divider-only geometry; ignored for a seatable table.
  final bool vertical;
  final int span;
  final bool delete;
}
