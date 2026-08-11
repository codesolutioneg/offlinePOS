import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/db/table_store.dart';
import '../../core/i18n/l10n.dart';

/// The floor plan: tables drawn where the shop placed them, tapped to start or
/// recall a dine-in order. In edit mode a manager lays the floor out by dragging
/// tables around, adding sections, and setting seats.
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
  });

  final TableStore store;

  /// Table names that currently have a held order, so those tiles read as occupied.
  final Set<String> occupiedLabels;

  /// Per occupied table: its running total and when it was opened, so a waiter sees
  /// the bill and how long the table has been sitting straight off the floor.
  final Map<String, ({double total, DateTime since})> occupiedInfo;
  final String Function(double)? formatAmount;

  /// Start a new dine-in order on a free table, or recall the order parked on an
  /// occupied one. The shell decides which; this screen just reports the tap.
  final void Function(PosTable table) onOpenTable;

  @override
  State<TableFloorScreen> createState() => _TableFloorScreenState();
}

class _TableFloorScreenState extends State<TableFloorScreen> {
  static const double _cell = 110;
  final GlobalKey _canvasKey = GlobalKey();
  bool _editing = false;
  String? _section;
  Timer? _tick;

  @override
  void initState() {
    super.initState();
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

  void _reload() => setState(() {
        // Deleting the last table in a section makes that section vanish, so drop
        // back to a section that still exists rather than showing a blank floor.
        if (_section != null && !_sections.contains(_section)) _section = null;
      });

  Future<void> _addTable() async {
    final result = await _tableDialog(title: tr(context, 'Add table'));
    if (result == null) return;
    widget.store.add(
      name: result.name,
      seats: result.seats,
      section: _activeSection,
      // Drop a new table at the top-left; the manager drags it into place.
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
      widget.store.remove(t.id);
    } else {
      // Keep names unique so an order is never recalled onto the wrong table; a
      // rename that would collide is suffixed rather than silently duplicated.
      final name = result.name == t.name ? t.name : widget.store.uniqueName(result.name);
      widget.store.upsert(t.copyWith(name: name, seats: result.seats));
    }
    _reload();
  }

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
    setState(() => _section = name);
  }

  Future<_TableEdit?> _tableDialog({required String title, PosTable? initial}) {
    final nameCtrl = TextEditingController(text: initial?.name ?? '');
    final seatsCtrl = TextEditingController(text: '${initial?.seats ?? 4}');
    return showDialog<_TableEdit>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
            key: const Key('table-name'),
            controller: nameCtrl,
            autofocus: true,
            decoration: InputDecoration(
                labelText: tr(ctx, 'Name / number'), border: const OutlineInputBorder()),
          ),
          const SizedBox(height: 8),
          TextField(
            key: const Key('table-seats'),
            controller: seatsCtrl,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
                labelText: tr(ctx, 'Seats'), border: const OutlineInputBorder()),
          ),
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
              Navigator.pop(ctx,
                  _TableEdit(name: name, seats: int.tryParse(seatsCtrl.text.trim()) ?? 4));
            },
            child: Text(tr(ctx, 'Save')),
          ),
        ],
      ),
    );
  }

  void _dropAt(PosTable t, Offset globalOffset) {
    final box = _canvasKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    final local = box.globalToLocal(globalOffset);
    // Snap to the grid so the floor stays tidy and two tables cannot half-overlap.
    final gx = (local.dx / _cell).clamp(0, 20).roundToDouble();
    final gy = (local.dy / _cell).clamp(0, 20).roundToDouble();
    widget.store.upsert(t.copyWith(x: gx, y: gy));
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    final tables = widget.store.inSection(_activeSection);
    return Scaffold(
      appBar: AppBar(
        title: Text(tr(context, 'Tables')),
        actions: [
          IconButton(
            key: const Key('toggle-edit'),
            tooltip: _editing ? tr(context, 'Done') : tr(context, 'Edit floor'),
            icon: Icon(_editing ? Icons.check : Icons.edit),
            onPressed: () => setState(() => _editing = !_editing),
          ),
        ],
      ),
      floatingActionButton: _editing
          ? FloatingActionButton.extended(
              key: const Key('add-table'),
              onPressed: _addTable,
              icon: const Icon(Icons.add),
              label: Text(tr(context, 'Table')),
            )
          : null,
      body: Column(
        children: [
          _sectionStrip(),
          const Divider(height: 1),
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
        setState(() => _section = name);
      }
    } else if (action == 'delete') {
      widget.store.deleteSection(section);
      _reload();
    }
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
                  onSelected: (_) => setState(() => _section = s),
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

  Widget _canvas(List<PosTable> tables) {
    final maxX = tables.map((t) => t.x).fold(3.0, (a, b) => a > b ? a : b);
    final maxY = tables.map((t) => t.y).fold(3.0, (a, b) => a > b ? a : b);
    final canvas = SizedBox(
      key: _canvasKey,
      width: (maxX + 2) * _cell,
      height: (maxY + 2) * _cell,
      child: Stack(
        children: [
          for (final t in tables)
            Positioned(
              left: t.x * _cell,
              top: t.y * _cell,
              child: _tile(t),
            ),
        ],
      ),
    );
    // In edit mode the whole canvas accepts a dragged table and drops it on the
    // grid cell under the pointer, which is what makes it a drawn layout.
    if (!_editing) return canvas;
    return DragTarget<PosTable>(
      onAcceptWithDetails: (d) => _dropAt(d.data, d.offset),
      builder: (context, candidate, rejected) => canvas,
    );
  }

  Widget _tile(PosTable t) {
    final occupied = widget.occupiedLabels.contains(t.name);
    final info = widget.occupiedInfo[t.name];
    final tile = _TableTile(
      table: t,
      occupied: occupied,
      total: info == null ? null : widget.formatAmount?.call(info.total),
      ageMinutes: info == null ? null : DateTime.now().difference(info.since).inMinutes,
    );
    if (!_editing) {
      return InkWell(
        key: Key('table-tile-${t.id}'),
        onTap: () => widget.onOpenTable(t),
        child: tile,
      );
    }
    return Draggable<PosTable>(
      data: t,
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
            if (!_editing)
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

class _TableTile extends StatelessWidget {
  const _TableTile({
    required this.table,
    required this.occupied,
    this.total,
    this.ageMinutes,
  });
  final PosTable table;
  final bool occupied;
  final String? total;
  final int? ageMinutes;

  @override
  Widget build(BuildContext context) {
    final color = occupied ? Colors.red.shade400 : Colors.green.shade500;
    return Container(
      width: 100,
      height: 100,
      margin: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        border: Border.all(color: color, width: 2),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
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
        ],
      ),
    );
  }
}

class _TableEdit {
  const _TableEdit({required this.name, required this.seats}) : delete = false;
  const _TableEdit.remove()
      : name = '',
        seats = 0,
        delete = true;
  final String name;
  final int seats;
  final bool delete;
}
