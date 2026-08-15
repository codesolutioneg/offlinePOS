import 'package:flutter/material.dart';

import '../../core/db/settings_store.dart';
import '../../core/i18n/l10n.dart';
import '../../core/printing/printer_registry.dart';
import '../../core/theme/app_colors.dart';
import '../../domain/catalogue.dart';

/// Assumed to exist even before a manager ever opens this screen, so a single
/// printer shop can route every category here without configuring anything.
const _defaultStation = 'kitchen';

/// Configure printers by name and address, point each product category at one or
/// more kitchen stations (printer names) that should print its tickets, and
/// optionally override that routing for individual products.
///
/// A printer is addressed by name everywhere else in the app (see
/// [PrinterRegistry]) because the address it answers on drifts under DHCP;
/// this is the one screen where a manager types that name in, alongside a
/// starting address the registry can try first. Category and product routing
/// live in [SettingsStore] rather than the registry because either can be
/// routed to a station name before any printer with that name has ever
/// answered a scan.
class PrintersScreen extends StatefulWidget {
  const PrintersScreen({
    super.key,
    required this.printers,
    required this.settings,
    required this.categories,
    required this.onChanged,
    this.onTestPrint,
    this.products = const [],
  });

  final PrinterRegistry printers;
  final SettingsStore settings;
  final List<Category> categories;

  /// Products offered for per-item routing overrides. Empty hides that section
  /// entirely: a shop that never needs finer-grained routing than "category"
  /// should not be shown an empty checklist.
  final List<Product> products;

  /// Sends a test receipt to the named printer. Null hides the test action.
  final Future<void> Function(String printerName)? onTestPrint;

  /// Called after every printer or routing change, so the caller can refresh
  /// or persist whatever it holds derived from either store.
  final VoidCallback onChanged;

  @override
  State<PrintersScreen> createState() => _PrintersScreenState();
}

class _PrintersScreenState extends State<PrintersScreen> {
  /// The station the per-product checklist is currently ticking boxes for. Reset
  /// to the first available station whenever it points at nothing pickable.
  String? _productStationPick;
  String _productSearch = '';
  int? _productCategoryFilter;

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
    final added = await showDialog<String>(
      context: context,
      builder: (context) => _AddPrinterDialog(printers: widget.printers),
    );
    if (added != null) _notify();
  }

  Future<void> _editPrinter(ConfiguredPrinter printer) async {
    final newName = await showDialog<String>(
      context: context,
      builder: (context) =>
          _AddPrinterDialog(printers: widget.printers, editing: printer),
    );
    if (newName == null) return;
    // A rename must carry the routing across, or every category/product still
    // pointing at the old name would silently fall back to the default kitchen.
    if (newName != printer.name) {
      widget.settings.renameStation(printer.name, newName);
    }
    _notify();
  }

  void _setCategoryStation(int categoryId, String station, bool enabled) {
    widget.settings.setCategoryStation(categoryId, station, enabled);
    _notify();
  }

  void _setProductStation(int productId, String station, bool enabled) {
    widget.settings.setProductStation(productId, station, enabled);
    _notify();
  }

  @override
  Widget build(BuildContext context) {
    final categoryAssignments = widget.settings.categoryStations;
    // The default station and every configured printer are always offered,
    // plus anything a category or product already points at, even a name
    // that got renamed or removed since: a stale assignment must stay
    // pickable so its chip never disappears out from under it.
    final stations = <String>{
      _defaultStation,
      for (final printer in widget.printers.printers) printer.name,
      for (final list in categoryAssignments.values) ...list,
      for (final list in widget.settings.productStations.values) ...list,
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
          ..._routingRows(stations, categoryAssignments),
          if (widget.products.isNotEmpty) ...[
            const SizedBox(height: 24),
            _sectionHeader(
                context, tr(context, 'Item routing'), Icons.checklist, AppColors.success),
            _productRoutingSection(stations),
          ],
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
    final subStation = widget.settings.subReceiptStation;
    // Only printers that actually exist, unlike the routing chips below: a category
    // can be pointed at a station before its printer is bought, but a copy sent to a
    // name nothing answers to just prints a second slip at the till.
    final configured = <String>{
      for (final printer in widget.printers.printers) printer.name,
      // Whatever is already chosen stays pickable, even if that printer was removed
      // since, so the setting never disappears out from under a manager.
      if (subStation.isNotEmpty) subStation,
    }.toList()
      ..sort();
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
          const Divider(),
          // A copy of the sale slip for whoever packs the order. Off until a station
          // is picked, because a shop with one printer does not want two slips.
          Row(children: [
            Expanded(
              child: Text(tr(context, 'Copy for the pass'),
                  style: const TextStyle(fontWeight: FontWeight.w600)),
            ),
            DropdownButton<String>(
              key: const Key('sub-receipt-station'),
              value: configured.contains(subStation) ? subStation : '',
              items: [
                DropdownMenuItem(value: '', child: Text(tr(context, 'Off'))),
                for (final station in configured)
                  DropdownMenuItem(value: station, child: Text(station)),
              ],
              onChanged: (v) {
                widget.settings.subReceiptStation = v ?? '';
                _notify();
              },
            ),
          ]),
          if (subStation.isNotEmpty)
            SwitchListTile(
              key: const Key('sub-receipt-hide-prices'),
              contentPadding: EdgeInsets.zero,
              title: Text(tr(context, 'Hide prices on that copy')),
              subtitle: Text(tr(context, 'A packing list: names and quantities only')),
              value: widget.settings.subReceiptHidePrices,
              onChanged: (v) {
                widget.settings.subReceiptHidePrices = v;
                _notify();
              },
            ),
          const Divider(),
          // Which script the printer itself can spell, and what to do about the
          // lines it cannot. Here rather than in the receipt designer because both
          // answers depend on the hardware, not on what the slip should say.
          Row(children: [
            Text(tr(context, 'Character table'),
                style: const TextStyle(fontWeight: FontWeight.w600)),
            const Spacer(),
            SegmentedButton<String>(
              key: const Key('code-page'),
              segments: [
                ButtonSegment(value: 'wpc1252', label: Text(tr(context, 'Latin'))),
                ButtonSegment(value: 'wpc1256', label: Text(tr(context, 'Arabic'))),
              ],
              selected: {
                widget.settings.receiptCodePage == 'wpc1256' ? 'wpc1256' : 'wpc1252'
              },
              onSelectionChanged: (s) {
                widget.settings.receiptCodePage = s.first;
                _notify();
              },
            ),
          ]),
          Text(tr(context, 'Pick Arabic only if the printer supports it'),
              style: Theme.of(context).textTheme.bodySmall),
          const Divider(),
          SwitchListTile(
            key: const Key('arabic-raster'),
            contentPadding: EdgeInsets.zero,
            title: Text(tr(context, 'Print missing letters as an image')),
            subtitle: Text(tr(
                context, 'Slower, but a name the table cannot spell still prints')),
            value: widget.settings.receiptArabicRaster,
            onChanged: (v) {
              widget.settings.receiptArabicRaster = v;
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
                    key: Key('edit-${printer.name}'),
                    tooltip: tr(context, 'Edit'),
                    icon: const Icon(Icons.edit_outlined),
                    onPressed: () => _editPrinter(printer),
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
    // The spare is part of what this printer is: support reading the screen has to
    // see where a ticket goes when this one is off.
    final backup = printer.backup == null
        ? ''
        : ' - ${tr(context, 'spare')}: ${printer.backup}';
    return '$address$identity$seen$backup';
  }

  String _formatTime(DateTime at) {
    final local = at.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(local.hour)}:${two(local.minute)}';
  }

  /// One card per category with a toggleable chip per known station, so a
  /// category that should fire at both the grill and the expo pass can have
  /// both chips selected at once rather than being forced to pick one.
  List<Widget> _routingRows(List<String> stations, Map<int, List<String>> assignments) {
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
        Card(
          key: Key('route-${category.id}'),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(category.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    for (final station in stations)
                      FilterChip(
                        key: Key('route-station-${category.id}-$station'),
                        label: Text(station),
                        selected: (assignments[category.id] ?? const []).contains(station),
                        onSelected: (enabled) =>
                            _setCategoryStation(category.id, station, enabled),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
    ];
  }

  /// Pick one station, then tick which products override their category and
  /// route to it directly. Filterable by category and searchable by name so a
  /// shop with a long menu can still find one item quickly.
  Widget _productRoutingSection(List<String> stations) {
    final pick = stations.contains(_productStationPick)
        ? _productStationPick!
        : (stations.isEmpty ? _defaultStation : stations.first);
    final assignments = widget.settings.productStations;
    final categoryNames = {for (final c in widget.categories) c.id: c.name};
    final filtered = widget.products.where((p) {
      if (_productCategoryFilter != null && p.categoryId != _productCategoryFilter) {
        return false;
      }
      if (_productSearch.isEmpty) return true;
      return p.name.toLowerCase().contains(_productSearch.toLowerCase());
    }).toList()
      ..sort((a, b) => a.name.compareTo(b.name));

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(tr(context, 'Printer'), style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final station in stations)
                  ChoiceChip(
                    key: Key('product-station-pick-$station'),
                    label: Text(station),
                    selected: pick == station,
                    onSelected: (_) => setState(() => _productStationPick = station),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('product-search'),
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search),
                hintText: tr(context, 'Search products'),
                border: const OutlineInputBorder(),
                isDense: true,
              ),
              onChanged: (v) => setState(() => _productSearch = v),
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 40,
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: [
                  ChoiceChip(
                    key: const Key('product-category-all'),
                    label: Text(tr(context, 'All')),
                    selected: _productCategoryFilter == null,
                    onSelected: (_) => setState(() => _productCategoryFilter = null),
                  ),
                  for (final category in widget.categories) ...[
                    const SizedBox(width: 6),
                    ChoiceChip(
                      key: Key('product-category-${category.id}'),
                      label: Text(category.name),
                      selected: _productCategoryFilter == category.id,
                      onSelected: (_) => setState(() => _productCategoryFilter = category.id),
                    ),
                  ],
                ],
              ),
            ),
            const Divider(),
            if (filtered.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(tr(context, 'No products match.')),
              )
            else
              for (final product in filtered)
                CheckboxListTile(
                  key: Key('product-route-${product.id}'),
                  contentPadding: EdgeInsets.zero,
                  title: Text(product.name),
                  subtitle: product.categoryId == null
                      ? null
                      : Text(categoryNames[product.categoryId] ?? ''),
                  value: (assignments[product.id] ?? const []).contains(pick),
                  onChanged: (v) => _setProductStation(product.id, pick, v ?? false),
                ),
          ],
        ),
      ),
    );
  }
}

/// Name, optional starting address, and port for a printer.
///
/// The name is the only thing that has to be right: it is what every ticket
/// routes by, and it survives the printer's address moving under DHCP. The
/// address is just a first guess to save the registry an initial subnet
/// sweep.
///
/// When [editing] is given the fields start pre-filled from it and saving
/// updates that printer in place: the registry keys printers by name, so a
/// changed name is carried across by forgetting the old one and remembering
/// the new one with the same host and port, while an unchanged name simply
/// re-remembers under it.
class _AddPrinterDialog extends StatefulWidget {
  const _AddPrinterDialog({required this.printers, this.editing});

  final PrinterRegistry printers;
  final ConfiguredPrinter? editing;

  @override
  State<_AddPrinterDialog> createState() => _AddPrinterDialogState();
}

class _AddPrinterDialogState extends State<_AddPrinterDialog> {
  static const _nameSuggestions = ['receipt', 'kitchen', 'bar'];

  late final TextEditingController _name;
  late final TextEditingController _host;
  late final TextEditingController _port;

  /// The printer this one falls back to, or empty for none.
  late String _backup;

  @override
  void initState() {
    super.initState();
    final editing = widget.editing;
    _name = TextEditingController(text: editing?.name ?? '');
    _host = TextEditingController(text: editing?.host ?? '');
    _port = TextEditingController(text: '${editing?.port ?? 9100}');
    _backup = editing?.backup ?? '';
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
    final oldName = widget.editing?.name;
    // A rename has to move the whole configuration across, because the registry
    // (and every ticket routed by name) knows this printer only by its name.
    if (oldName != null && oldName != name) {
      widget.printers.forget(oldName);
    }
    widget.printers.remember(name, host: host.isEmpty ? null : host, port: port);
    // After the remember, so it lands on the printer that now exists under this
    // name, and explicitly, because clearing the spare has to be possible too.
    widget.printers.setBackup(name, _backup.isEmpty ? null : _backup);
    // Return the saved name so the caller can repoint routing on a rename.
    Navigator.of(context).pop(name);
  }

  @override
  Widget build(BuildContext context) {
    final editing = widget.editing != null;
    final others = widget.printers.printers
        .where((p) => p.name != widget.editing?.name)
        .toList()
      ..sort((a, b) => a.name.compareTo(b.name));
    return AlertDialog(
      title: Text(editing ? tr(context, 'Edit printer') : tr(context, 'Add printer')),
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
            const SizedBox(height: 12),
            // Where a job goes when this printer will not take it. Only printers
            // that already exist are offered, and never this one.
            Row(children: [
              Expanded(child: Text(tr(context, 'If it is off, print at'))),
              DropdownButton<String>(
                key: const Key('printer-backup'),
                value: others.map((p) => p.name).contains(_backup) ? _backup : '',
                items: [
                  DropdownMenuItem(value: '', child: Text(tr(context, 'Nowhere'))),
                  for (final other in others)
                    DropdownMenuItem(value: other.name, child: Text(other.name)),
                ],
                onChanged: (v) => setState(() => _backup = v ?? ''),
              ),
            ]),
            Text(tr(context, 'The slip says it was rerouted'),
                style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const Key('cancel-add-printer'),
          onPressed: () => Navigator.of(context).pop(),
          child: Text(tr(context, 'Cancel')),
        ),
        FilledButton(
          key: const Key('save-add-printer'),
          onPressed: _save,
          child: Text(editing ? tr(context, 'Save') : tr(context, 'Add')),
        ),
      ],
    );
  }
}
