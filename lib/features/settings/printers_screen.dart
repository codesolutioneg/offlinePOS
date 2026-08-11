import 'package:flutter/material.dart';

import '../../core/db/settings_store.dart';
import '../../core/i18n/l10n.dart';
import '../../core/printing/printer_registry.dart';
import '../../domain/catalogue.dart';

/// Assumed to exist even before a manager ever opens this screen, so a single
/// printer shop can route every category here without configuring anything.
const _defaultStation = 'kitchen';

/// Configure printers by name and address, and point each product category at
/// the kitchen station (printer name) that should print its tickets.
///
/// A printer is addressed by name everywhere else in the app (see
/// [PrinterRegistry]) because the address it answers on drifts under DHCP;
/// this is the one screen where a manager types that name in, alongside a
/// starting address the registry can try first. Category routing lives in
/// [SettingsStore] rather than the registry because a category can be routed
/// to a station name before any printer with that name has ever answered a
/// scan.
class PrintersScreen extends StatefulWidget {
  const PrintersScreen({
    super.key,
    required this.printers,
    required this.settings,
    required this.categories,
    required this.onChanged,
  });

  final PrinterRegistry printers;
  final SettingsStore settings;
  final List<Category> categories;

  /// Called after every printer or routing change, so the caller can refresh
  /// or persist whatever it holds derived from either store.
  final VoidCallback onChanged;

  @override
  State<PrintersScreen> createState() => _PrintersScreenState();
}

class _PrintersScreenState extends State<PrintersScreen> {
  void _notify() {
    widget.onChanged();
    setState(() {});
  }

  Future<void> _rescan(String name) async {
    final host = await widget.printers.refresh(name);
    if (!mounted) return;
    setState(() {});
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$name: ${host ?? tr(context, 'not found')}')),
    );
  }

  void _remove(String name) {
    widget.printers.forget(name);
    _notify();
  }

  Future<void> _addPrinter() async {
    final added = await showDialog<bool>(
      context: context,
      builder: (context) => _AddPrinterDialog(printers: widget.printers),
    );
    if (added == true) _notify();
  }

  void _setStation(int categoryId, String? station) {
    widget.settings.setCategoryStation(categoryId, station);
    _notify();
  }

  @override
  Widget build(BuildContext context) {
    final assignments = widget.settings.categoryStations;
    // The default station and every configured printer are always offered,
    // plus anything a category already points at, even a name that got
    // renamed or removed since: a stale assignment must stay pickable so the
    // dropdown never has a selected value missing from its own item list.
    final stations = <String>{
      _defaultStation,
      for (final printer in widget.printers.printers) printer.name,
      ...assignments.values,
    }.toList()
      ..sort();

    return Scaffold(
      appBar: AppBar(title: Text(tr(context, 'Printers & routing'))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _sectionHeader(context, tr(context, 'Printers')),
          ..._printerRows(),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            key: const Key('add-printer'),
            onPressed: _addPrinter,
            icon: const Icon(Icons.add),
            label: Text(tr(context, 'Add printer')),
          ),
          const SizedBox(height: 24),
          _sectionHeader(context, tr(context, 'Kitchen routing')),
          ..._routingRows(stations, assignments),
        ],
      ),
    );
  }

  Widget _sectionHeader(BuildContext context, String title) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(title, style: Theme.of(context).textTheme.titleMedium),
      );

  List<Widget> _printerRows() {
    final printers = widget.printers.printers.toList()
      ..sort((a, b) => a.name.compareTo(b.name));
    if (printers.isEmpty) {
      return [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Text(tr(context, 'No printers configured yet.')),
        ),
      ];
    }
    return [
      for (final printer in printers)
        Card(
          key: Key('printer-${printer.name}'),
          child: ListTile(
            title: Text(printer.name),
            subtitle: Text(_describe(printer)),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  key: Key('rescan-${printer.name}'),
                  tooltip: tr(context, 'Rescan'),
                  icon: const Icon(Icons.refresh),
                  onPressed: () => _rescan(printer.name),
                ),
                IconButton(
                  key: Key('remove-${printer.name}'),
                  tooltip: tr(context, 'Remove'),
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => _remove(printer.name),
                ),
              ],
            ),
          ),
        ),
    ];
  }

  String _describe(ConfiguredPrinter printer) {
    final address =
        printer.host == null ? 'no address yet' : '${printer.host}:${printer.port}';
    final identity = printer.identity == null ? '' : ' - identity ${printer.identity}';
    final seen =
        printer.lastSeenAt == null ? '' : ' - last seen ${_formatTime(printer.lastSeenAt!)}';
    return '$address$identity$seen';
  }

  String _formatTime(DateTime at) {
    final local = at.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(local.hour)}:${two(local.minute)}';
  }

  List<Widget> _routingRows(List<String> stations, Map<int, String> assignments) {
    if (widget.categories.isEmpty) {
      return [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Text(tr(context, 'No categories to route yet.')),
        ),
      ];
    }
    return [
      for (final category in widget.categories)
        ListTile(
          key: Key('route-${category.id}'),
          title: Text(category.name),
          trailing: DropdownButton<String?>(
            key: Key('route-station-${category.id}'),
            value: assignments[category.id],
            items: [
              DropdownMenuItem<String?>(
                value: null,
                child: Text(tr(context, 'Auto / kitchen')),
              ),
              for (final station in stations)
                DropdownMenuItem<String?>(value: station, child: Text(station)),
            ],
            onChanged: (value) => _setStation(category.id, value),
          ),
        ),
    ];
  }
}

/// Name, optional starting address, and port for a printer that does not
/// exist in [PrinterRegistry] yet.
///
/// The name is the only thing that has to be right: it is what every ticket
/// routes by, and it survives the printer's address moving under DHCP. The
/// address is just a first guess to save the registry an initial subnet
/// sweep.
class _AddPrinterDialog extends StatefulWidget {
  const _AddPrinterDialog({required this.printers});

  final PrinterRegistry printers;

  @override
  State<_AddPrinterDialog> createState() => _AddPrinterDialogState();
}

class _AddPrinterDialogState extends State<_AddPrinterDialog> {
  static const _nameSuggestions = ['receipt', 'kitchen', 'bar'];

  late final TextEditingController _name;
  late final TextEditingController _host;
  late final TextEditingController _port;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController();
    _host = TextEditingController();
    _port = TextEditingController(text: '9100');
  }

  @override
  void dispose() {
    _name.dispose();
    _host.dispose();
    _port.dispose();
    super.dispose();
  }

  void _save() {
    final name = _name.text.trim();
    if (name.isEmpty) return;
    final host = _host.text.trim();
    final port = int.tryParse(_port.text.trim()) ?? 9100;
    widget.printers.remember(name, host: host.isEmpty ? null : host, port: port);
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(tr(context, 'Add printer')),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              key: const Key('printer-name'),
              controller: _name,
              decoration: InputDecoration(
                labelText: tr(context, 'Name'),
                hintText: tr(context, 'e.g. kitchen'),
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            // A printer is routed to by this name for the rest of its life, so a
            // shop with more than one station needs a name that says what it is
            // rather than where it happens to sit today.
            Wrap(
              spacing: 8,
              children: [
                for (final suggestion in _nameSuggestions)
                  ActionChip(
                    key: Key('suggest-printer-name-$suggestion'),
                    label: Text(suggestion),
                    onPressed: () => setState(() => _name.text = suggestion),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('printer-host'),
              controller: _host,
              decoration: InputDecoration(
                labelText: tr(context, 'Host (optional)'),
                hintText: tr(context, 'e.g. 192.168.1.50'),
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('printer-port'),
              controller: _port,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: tr(context, 'Port'),
                border: const OutlineInputBorder(),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const Key('cancel-add-printer'),
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(tr(context, 'Cancel')),
        ),
        FilledButton(
          key: const Key('save-add-printer'),
          onPressed: _save,
          child: Text(tr(context, 'Add')),
        ),
      ],
    );
  }
}
