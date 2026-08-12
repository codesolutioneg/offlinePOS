import 'package:flutter/material.dart';

import '../../core/db/settings_store.dart';
import '../../core/i18n/l10n.dart';
import '../../core/printing/printer_registry.dart';
import '../../core/theme/app_colors.dart';
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
    this.onTestPrint,
  });

  final PrinterRegistry printers;
  final SettingsStore settings;
  final List<Category> categories;

  /// Sends a test receipt to the named printer. Null hides the test action.
  final Future<void> Function(String printerName)? onTestPrint;

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
          _sectionHeader(context, tr(context, 'Printers'), Icons.print, AppColors.info),
          ..._printerRows(),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            key: const Key('add-printer'),
            onPressed: _addPrinter,
            icon: const Icon(Icons.add),
            label: Text(tr(context, 'Add printer')),
          ),
          const SizedBox(height: 24),
          _sectionHeader(
              context, tr(context, 'Receipt & paper'), Icons.receipt_long, AppColors.primary),
          _receiptOptions(),
          const SizedBox(height: 24),
          _sectionHeader(context, tr(context, 'Kitchen routing'), Icons.restaurant, AppColors.warning),
          ..._routingRows(stations, assignments),
        ],
      ),
    );
  }

  Widget _sectionHeader(BuildContext context, String title, IconData icon, Color color) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 10, top: 4),
        child: Row(children: [
          Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
                color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(8)),
            child: Icon(icon, size: 18, color: color),
          ),
          const SizedBox(width: 8),
          Text(title,
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.bold)),
        ]),
      );

  /// Paper width, copies and the cash-drawer kick, so a manager tunes the receipt
  /// to their actual printer instead of accepting one hard-coded shape.
  Widget _receiptOptions() {
    final cols = widget.settings.receiptColumns;
    final copies = widget.settings.receiptCopies;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Text(tr(context, 'Paper width'), style: const TextStyle(fontWeight: FontWeight.w600)),
            const Spacer(),
            SegmentedButton<int>(
              key: const Key('paper-width'),
              segments: const [
                ButtonSegment(value: 42, label: Text('80 mm')),
                ButtonSegment(value: 32, label: Text('58 mm')),
              ],
              selected: {cols == 32 ? 32 : 42},
              onSelectionChanged: (s) {
                widget.settings.receiptColumns = s.first;
                _notify();
              },
            ),
          ]),
          const Divider(),
          Row(children: [
            Text(tr(context, 'Copies'), style: const TextStyle(fontWeight: FontWeight.w600)),
            const Spacer(),
            IconButton(
                key: const Key('copies-minus'),
                icon: const Icon(Icons.remove_circle_outline),
                onPressed: copies > 1
                    ? () {
                        widget.settings.receiptCopies = copies - 1;
                        _notify();
                      }
                    : null),
            Text('$copies', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            IconButton(
                key: const Key('copies-plus'),
                icon: const Icon(Icons.add_circle_outline),
                onPressed: copies < 3
                    ? () {
                        widget.settings.receiptCopies = copies + 1;
                        _notify();
                      }
                    : null),
          ]),
          const Divider(),
          SwitchListTile(
            key: const Key('open-drawer'),
            contentPadding: EdgeInsets.zero,
            title: Text(tr(context, 'Open cash drawer on cash sale')),
            value: widget.settings.openDrawerOnSale,
            onChanged: (v) {
              widget.settings.openDrawerOnSale = v;
              _notify();
            },
          ),
        ]),
      ),
    );
  }

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
        Builder(builder: (context) {
          final known = printer.host != null;
          final statusColor = known ? AppColors.success : Colors.grey;
          // A "kitchen"/"bar" printer prints tickets; anything else is a receipt
          // printer. Inferred from the name, which is all the registry stores.
          final isKitchen = RegExp('kitchen|bar|grill', caseSensitive: false)
              .hasMatch(printer.name);
          return Card(
            key: Key('printer-${printer.name}'),
            child: ListTile(
              leading: CircleAvatar(
                backgroundColor: statusColor.withValues(alpha: 0.15),
                foregroundColor: statusColor,
                child: Icon(isKitchen ? Icons.soup_kitchen : Icons.receipt_long),
              ),
              title: Row(children: [
                Flexible(child: Text(printer.name, overflow: TextOverflow.ellipsis)),
                const SizedBox(width: 8),
                StatusChip(
                    known ? tr(context, 'Ready') : tr(context, 'Not found'), statusColor),
              ]),
              subtitle: Text(_describe(printer)),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (widget.onTestPrint != null)
                    IconButton(
                      key: Key('test-${printer.name}'),
                      tooltip: tr(context, 'Test print'),
                      icon: const Icon(Icons.print_outlined),
                      onPressed: () => _testPrint(printer.name),
                    ),
                  IconButton(
                    key: Key('rescan-${printer.name}'),
                    tooltip: tr(context, 'Rescan'),
                    icon: const Icon(Icons.refresh),
                    onPressed: () => _rescan(printer.name),
                  ),
                  IconButton(
                    key: Key('remove-${printer.name}'),
                    tooltip: tr(context, 'Remove'),
                    icon: const Icon(Icons.delete_outline, color: AppColors.error),
                    onPressed: () => _remove(printer.name),
                  ),
                ],
              ),
            ),
          );
        }),
    ];
  }

  Future<void> _testPrint(String name) async {
    try {
      await widget.onTestPrint?.call(name);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$name: ${tr(context, 'test receipt sent')}')));
    } catch (_) {
      // The named printer answered nothing: say so rather than claim success.
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          backgroundColor: AppColors.error,
          content: Text('$name: ${tr(context, 'not reachable')}')));
    }
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
