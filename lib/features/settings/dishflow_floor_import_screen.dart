import 'package:flutter/material.dart';

import '../../core/auth/user_store.dart';
import '../../core/db/catalogue_store.dart';
import '../../core/db/order_store.dart';
import '../../core/db/settings_store.dart';
import '../../core/db/table_store.dart';
import '../../core/i18n/l10n.dart';
import '../../core/printing/printer_registry.dart';
import '../../core/sync/dishflow_config_client.dart';
import '../../core/sync/dishflow_floor_import.dart';
import '../../domain/table_section_config.dart';

/// Copy a Dishflow branch's floor plan, section rules, printers, kitchen
/// routing and staff onto this till.
///
/// One direction and on demand: Dishflow is only read, and nothing is written
/// here until a manager has seen what would change and confirmed it. The floor
/// and the rules then travel to the other tills the way a hand edit does.
class DishflowFloorImportScreen extends StatefulWidget {
  const DishflowFloorImportScreen({
    super.key,
    required this.settings,
    required this.tables,
    required this.printers,
    required this.orders,
    required this.catalogue,
    required this.onImported,
    this.users,
    this.client,
  });

  final SettingsStore settings;
  final TableStore tables;
  final PrinterRegistry printers;
  final OrderStore orders;
  final CatalogueStore catalogue;
  final VoidCallback onImported;

  /// Where staff are written. Null leaves staff out of the import altogether.
  final UserStore? users;
  final DishflowConfigClient? client;

  @override
  State<DishflowFloorImportScreen> createState() =>
      _DishflowFloorImportScreenState();
}

class _DishflowFloorImportScreenState extends State<DishflowFloorImportScreen> {
  FloorImportPlan? _plan;
  String? _error;
  bool _busy = false;
  bool _done = false;
  late bool _replaceFloor = !widget.tables.isEmpty;
  bool _importStaff = true;

  DishflowFloorImporter get _importer => DishflowFloorImporter(
        tables: widget.tables,
        settings: widget.settings,
        printers: widget.printers,
        users: widget.users,
      );

  bool get _secondary => widget.settings.deviceRole == DeviceRole.secondary;

  bool get _configured =>
      (widget.settings.dishflowProjectId ?? '').isNotEmpty &&
      (widget.settings.dishflowApiKey ?? '').isNotEmpty;

  /// A bill is recalled by its table name, so the floor is not rewritten while
  /// any till in the shop has one open.
  bool get _floorBusy => widget.orders.occupyingAnywhere().isNotEmpty;

  Future<void> _read() async {
    setState(() {
      _busy = true;
      _error = null;
      _plan = null;
      _done = false;
    });
    try {
      final s = widget.settings;
      final snapshot = await DishflowFloorSnapshot.fetch(
        widget.client ?? DishflowConfigClient(),
        projectId: s.dishflowProjectId!,
        apiKey: s.dishflowApiKey!,
        branchId: s.dishflowBranchId ?? '',
      );
      final plan = DishflowFloorMapper.plan(
        snapshot,
        categoryOfProduct: (id) => widget.catalogue.byId(id)?.categoryId,
      );
      if (!mounted) return;
      setState(() => _plan = plan);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _import() {
    final plan = _plan;
    if (plan == null || _floorBusy) return;
    _importer.apply(plan,
        replaceFloor: _replaceFloor, importStaff: _importStaff);
    widget.onImported();
    setState(() => _done = true);
  }

  @override
  Widget build(BuildContext context) {
    final plan = _plan;
    final muted =
        TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant);
    return Scaffold(
      appBar: AppBar(title: Text(tr(context, 'Import floor from Dishflow'))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            tr(context,
                'Copies tables, sections, printers and kitchen routing from the Dishflow branch. Dishflow is only read.'),
            style: muted,
          ),
          const SizedBox(height: 12),
          if (_secondary)
            Text(tr(context,
                'The floor is owned by the primary till. Import from the primary.'))
          else if (!_configured)
            Text(tr(context,
                'Set the Firebase project id and API key under Dishflow owner mirror first.'))
          else
            FilledButton.tonal(
              key: const Key('floor-import-read'),
              onPressed: _busy ? null : _read,
              child: Text(_busy
                  ? tr(context, 'Reading…')
                  : tr(context, 'Read from Dishflow')),
            ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!,
                key: const Key('floor-import-error'),
                style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ],
          if (plan != null) ...[
            const SizedBox(height: 16),
            if (plan.isEmpty)
              Text(tr(context, 'Nothing was found for this branch.'),
                  key: const Key('floor-import-empty'))
            else ...[
              _row(context, 'Tables', '${plan.tables.length}'),
              _row(context, 'Sections', plan.sections.join(', ')),
              _row(context, 'Section rules', '${plan.sectionConfigs.length}'),
              _row(context, 'Printers',
                  [for (final p in plan.printers) p.name].join(', ')),
              _row(context, 'Categories routed',
                  '${plan.categoryStations.length}'),
              _row(context, 'Products routed',
                  '${plan.productStations.length}'),
              if (widget.users != null)
                _row(context, 'Staff', '${plan.staff.length}'),
              for (final note in plan.notes)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text('• $note', style: muted),
                ),
              if (plan.tables.isNotEmpty && !widget.tables.isEmpty)
                SwitchListTile(
                  key: const Key('floor-import-replace'),
                  contentPadding: EdgeInsets.zero,
                  title: Text(tr(context, 'Replace the current floor')),
                  subtitle: Text(tr(context,
                      'Removes tables on this till that are not in Dishflow.')),
                  value: _replaceFloor,
                  onChanged: (v) => setState(() => _replaceFloor = v),
                ),
              if (widget.users != null && plan.staff.isNotEmpty)
                if (_importer.staffLeaveAManager(plan))
                  SwitchListTile(
                    key: const Key('floor-import-staff'),
                    contentPadding: EdgeInsets.zero,
                    title: Text(tr(context, 'Import staff')),
                    subtitle: Text(tr(context,
                        'They sign in with their Dishflow PIN. Roles are kept as they are in Dishflow.')),
                    value: _importStaff,
                    onChanged: (v) => setState(() => _importStaff = v),
                  )
                else
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      tr(context,
                          'Staff are not imported: none of them is an admin with a PIN, and the till would be left with nobody able to manage it.'),
                      key: const Key('floor-import-staff-blocked'),
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.error),
                    ),
                  ),
              const SizedBox(height: 12),
              if (_floorBusy)
                Text(
                  tr(context,
                      'Close or pay every open order before importing the floor.'),
                  key: const Key('floor-import-busy'),
                  style:
                      TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              FilledButton(
                key: const Key('floor-import-apply'),
                onPressed: _floorBusy || _done ? null : _import,
                child: Text(
                    _done ? tr(context, 'Imported') : tr(context, 'Import')),
              ),
            ],
          ],
        ],
      ),
    );
  }

  Widget _row(BuildContext context, String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(width: 160, child: Text(tr(context, label))),
            Expanded(child: Text(value)),
          ],
        ),
      );
}
