import 'package:flutter/material.dart';

import '../../core/db/settings_store.dart';
import '../../core/i18n/l10n.dart';
import '../../core/printing/escpos.dart';
import '../../core/printing/printer_logo.dart';

/// Lets a manager pick what shows up on the printed customer receipt: a
/// header line above the shop name, the existing footer, and toggles for the
/// tax id, cashier name, and order type/table.
///
/// This is layout choice, not shop identity ([ShopSettingsScreen] already owns
/// name/tax id text), so it lives as its own screen the receipt builder reads
/// back from at print time via the same [SettingsStore] keys.
class ReceiptDesignerScreen extends StatefulWidget {
  const ReceiptDesignerScreen({
    super.key,
    required this.settings,
    required this.onChanged,
    this.onTestPrint,
    this.onUploadLogo,
  });

  final SettingsStore settings;

  /// Called after Save so anything caching the receipt layout reloads.
  final VoidCallback onChanged;

  /// Prints a sample receipt with the current settings, so a manager can see the
  /// layout on paper. Null hides the test-print button.
  final Future<void> Function()? onTestPrint;

  /// Writes the logo into the receipt printer's flash, so every later receipt costs
  /// four bytes instead of a picture. Throws when the printer is not reachable, and
  /// null hides the upload action entirely.
  final Future<void> Function(PrinterLogo logo)? onUploadLogo;

  @override
  State<ReceiptDesignerScreen> createState() => _ReceiptDesignerScreenState();
}

/// Raw setting keys, kept local to this screen since [SettingsStore] only
/// exposes typed accessors for the shop-identity fields it already owned.
const _headerKey = 'receipt_header';
const _showCashierKey = 'receipt_show_cashier';
const _showOrderTypeKey = 'receipt_show_ordertype';

/// The separator characters the receipt builder knows how to draw.
const _dividerStyles = ['line', 'equals', 'dots', 'stars'];

/// Mirrors [ReceiptBuilder]'s private divider map, so the preview draws the same
/// rule character the printer would without this screen depending on the printer
/// pipeline.
const _dividerChars = {'line': '-', 'equals': '=', 'dots': '.', 'stars': '*'};

class _ReceiptDesignerScreenState extends State<ReceiptDesignerScreen> {
  late final TextEditingController _header;
  late final TextEditingController _footer;
  late bool _showTax;
  late bool _showCashier;
  late bool _showOrderType;
  late bool _showDateTime;
  late bool _showNumber;
  late bool _showTable;
  late bool _showPayment;
  late bool _showItemPrice;
  late String _dividerStyle;
  late int _columns;
  late String _fontProfile;
  late bool _printLogo;
  late bool _logoRaster;
  final TextEditingController _logoPath = TextEditingController();

  /// What happened to the last upload, in words: a manager pressing a button that
  /// talks to hardware has to be told whether the hardware answered.
  String? _logoStatus;

  @override
  void initState() {
    super.initState();
    _header = TextEditingController(text: widget.settings.getString(_headerKey) ?? '');
    _footer = TextEditingController(text: widget.settings.receiptFooter ?? '');
    _showTax = widget.settings.receiptShowTax;
    _showCashier = widget.settings.getBool(_showCashierKey, fallback: true);
    _showOrderType = widget.settings.getBool(_showOrderTypeKey, fallback: true);
    _showDateTime = widget.settings.receiptShowDateTime;
    _showNumber = widget.settings.receiptShowNumber;
    _showTable = widget.settings.receiptShowTable;
    _showPayment = widget.settings.receiptShowPayment;
    _showItemPrice = widget.settings.receiptShowItemPrice;
    // Clamped to the offered choices: the segmented control below asserts on a
    // selection it has no segment for.
    final style = widget.settings.receiptDividerStyle;
    _dividerStyle = _dividerStyles.contains(style) ? style : 'line';
    // The same paper width the printers screen sets, so the two never disagree.
    _columns = widget.settings.receiptColumns == 32 ? 32 : 42;
    _fontProfile = widget.settings.receiptFontProfile;
    _printLogo = widget.settings.receiptPrintLogo;
    _logoRaster = widget.settings.receiptLogoRaster;
    // The preview reads the controllers' text directly; without a listener it
    // would only refresh on the next unrelated setState (e.g. a toggle), so
    // typing in the header or footer would look frozen until something else
    // triggered a rebuild.
    _header.addListener(_refreshPreview);
    _footer.addListener(_refreshPreview);
  }

  void _refreshPreview() => setState(() {});

  @override
  void dispose() {
    _header.removeListener(_refreshPreview);
    _footer.removeListener(_refreshPreview);
    _header.dispose();
    _footer.dispose();
    _logoPath.dispose();
    super.dispose();
  }

  void _save() {
    widget.settings.setString(_headerKey, _header.text.trim());
    widget.settings.receiptFooter = _footer.text.trim();
    widget.settings.receiptShowTax = _showTax;
    widget.settings.setBool(_showCashierKey, _showCashier);
    widget.settings.setBool(_showOrderTypeKey, _showOrderType);
    widget.settings.receiptShowDateTime = _showDateTime;
    widget.settings.receiptShowNumber = _showNumber;
    widget.settings.receiptShowTable = _showTable;
    widget.settings.receiptShowPayment = _showPayment;
    widget.settings.receiptShowItemPrice = _showItemPrice;
    widget.settings.receiptDividerStyle = _dividerStyle;
    widget.settings.receiptColumns = _columns;
    widget.settings.receiptFontProfile = _fontProfile;
    widget.settings.receiptPrintLogo = _printLogo;
    widget.settings.receiptLogoRaster = _logoRaster;
    widget.onChanged();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr(context, 'Saved'))));
  }

  /// Read the file, keep the dots, and put them in the printer.
  ///
  /// The dots are saved on the till whatever the printer does, so a shop that
  /// uploads with the printer off still has its logo and can send it again. The
  /// message says which of the two happened rather than a bare "Saved".
  Future<void> _uploadLogo() async {
    final path = _logoPath.text.trim();
    if (path.isEmpty) {
      setState(() => _logoStatus = tr(context, 'Give the file path of the logo image.'));
      return;
    }
    // The printable width of the roll, so a wide picture is scaled to fit the paper
    // rather than clipped at the edge.
    final logo = await loadPrinterLogo(path, maxWidthDots: _columns == 32 ? 384 : 576);
    if (!mounted) return;
    if (logo == null) {
      setState(() =>
          _logoStatus = tr(context, 'That file could not be read as an image.'));
      return;
    }
    widget.settings.receiptLogo = logo;
    widget.onChanged();
    try {
      await widget.onUploadLogo!(logo);
      if (!mounted) return;
      setState(() => _logoStatus = tr(context, 'Logo stored in the printer.'));
    } catch (_) {
      if (!mounted) return;
      // Not a failure of the logo, a failure of the printer, and the difference is
      // what tells a manager whether to pick another file or switch the printer on.
      setState(() => _logoStatus =
          tr(context, 'Kept on the till. The printer did not answer, so send it again.'));
    }
  }

  /// The logo controls: whether to print one, how it gets to the paper, and the
  /// one-time upload into the printer's flash.
  List<Widget> _logoItems(BuildContext context) {
    final loaded = widget.settings.receiptLogo;
    return [
      const SizedBox(height: 12),
      _sectionHeader(tr(context, 'Logo')),
      SwitchListTile(
        key: const Key('t-logo'),
        title: Text(tr(context, 'Print the shop logo')),
        subtitle: Text(tr(context, 'Above the shop name, from the printer\'s own memory')),
        value: _printLogo,
        onChanged: (v) => setState(() => _printLogo = v),
      ),
      if (_printLogo) ...[
        if (widget.onUploadLogo != null) ...[
          TextField(
            key: const Key('logo-path'),
            controller: _logoPath,
            decoration: InputDecoration(
              labelText: tr(context, 'Logo image file'),
              hintText: '/home/shop/logo.png',
              border: const OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            key: const Key('upload-logo'),
            icon: const Icon(Icons.upload),
            onPressed: _uploadLogo,
            label: Text(tr(context, 'Send the logo to the printer')),
          ),
        ],
        if (loaded != null)
          Text(
            '${tr(context, 'Loaded')}: ${loaded.widthDots} x ${loaded.heightDots}',
            key: const Key('logo-loaded'),
            style: Theme.of(context).textTheme.bodySmall,
          ),
        if (_logoStatus != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(_logoStatus!, key: const Key('logo-status')),
          ),
        SwitchListTile(
          key: const Key('t-logo-raster'),
          title: Text(tr(context, 'Send the picture with every receipt')),
          subtitle: Text(tr(context,
              'Only for a printer that cannot store a logo. Slower on every sale.')),
          value: _logoRaster,
          onChanged: (v) => setState(() => _logoRaster = v),
        ),
      ],
    ];
  }

  Widget _sectionHeader(String title) => Padding(
        padding: const EdgeInsets.only(top: 4, bottom: 4),
        child: Text(title,
            style: Theme.of(context)
                .textTheme
                .titleMedium
                ?.copyWith(fontWeight: FontWeight.bold)),
      );

  /// A label left, amount right, padded to [columns] — the same layout
  /// [EscPos.row] prints, kept as a pure string function here since this
  /// screen builds a mock from setting values rather than driving the printer
  /// pipeline.
  String _rowText(String label, String amount, int columns) {
    final space = columns - amount.length;
    if (space <= 0) return amount;
    final left = (label.length > space - 1 ? label.substring(0, space - 1) : label)
        .padRight(space);
    return '$left$amount';
  }

  /// A fixed, made-up two-line sale used only to give the preview something to
  /// lay out; it does not read real orders.
  String _sampleBody(int columns) {
    final divider = _dividerChars[_dividerStyle] ?? '-';
    final rule = divider * columns;
    final now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    final stamp = '${now.year}-${two(now.month)}-${two(now.day)} ${two(now.hour)}:${two(now.minute)}';

    final lines = <String>[rule];
    if (_showOrderType) lines.add('Dine-in');
    if (_showTable) lines.add('Table 4 - 2 guests');
    final stamped = [
      if (_showDateTime) stamp,
      if (_showNumber) '#A1B2C3',
    ].join('  ');
    if (stamped.isNotEmpty) lines.add(stamped);
    if (_showCashier) lines.add('Cashier: Sara');
    lines.add(rule);
    lines.add(_rowText('2 x Coffee', _showItemPrice ? '5.00' : '', columns));
    lines.add(_rowText('1 x Sandwich', _showItemPrice ? '6.50' : '', columns));
    lines.add(rule);
    lines.add(_rowText('TOTAL', '11.50', columns));
    if (_showPayment) {
      lines.add('');
      lines.add(_rowText('Cash', '11.50', columns));
    }
    return lines.join('\n');
  }

  /// A live, on-screen mock of the printed receipt built straight from this
  /// screen's own state, not the printer pipeline: a manager sees the effect of
  /// every toggle immediately instead of only after a test print.
  Widget _previewPanel(BuildContext context) {
    // The mock is set at the size the paper would be: a wider character fits fewer
    // of them on the roll, and a taller one just reads bigger.
    final scale = EscPosTextScale.byKey[_fontProfile] ?? EscPosTextScale.normal;
    final mono = TextStyle(
        fontFamily: 'monospace',
        fontSize: 12.0 * scale.height,
        height: 1.5,
        color: Colors.black87);
    final columns = _columns ~/ scale.width;
    final shopName = widget.settings.shopName?.trim();
    final header = _header.text.trim();
    final footer = _footer.text.trim();
    // Roughly the width of the roll in monospace characters, so the 58 mm choice
    // visibly narrows the mock the way it narrows the real roll. The character
    // count already shrank with the size, so the paper itself must not.
    final width = columns * scale.width * 7.3 + 32;

    return Container(
      key: const Key('receipt-preview'),
      width: width,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: Colors.grey.shade300),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.10), blurRadius: 10, offset: const Offset(0, 3)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // The mark itself lives in the printer, so the preview says where it lands
          // rather than pretending to know what it looks like.
          if (_printLogo)
            Container(
              key: const Key('receipt-preview-logo'),
              margin: const EdgeInsets.only(bottom: 6),
              padding: const EdgeInsets.symmetric(vertical: 10),
              decoration: BoxDecoration(
                border: Border.all(color: Colors.grey.shade400),
                borderRadius: BorderRadius.circular(3),
              ),
              child: Text(tr(context, 'LOGO'),
                  textAlign: TextAlign.center, style: mono),
            ),
          Text(
            shopName?.isNotEmpty == true ? shopName! : tr(context, 'Your shop'),
            textAlign: TextAlign.center,
            style: mono.copyWith(fontWeight: FontWeight.bold, fontSize: 14),
          ),
          if (header.isNotEmpty)
            Text(header, textAlign: TextAlign.center, style: mono),
          // The tax id prints under the shop name when Show tax id is on, so the
          // preview must react to that toggle to be trustworthy.
          if (_showTax && (widget.settings.taxId?.trim().isNotEmpty ?? false))
            Text(widget.settings.taxId!.trim(),
                key: const Key('receipt-preview-taxid'),
                textAlign: TextAlign.center,
                style: mono),
          const SizedBox(height: 4),
          Text(_sampleBody(columns), key: const Key('receipt-preview-body'), style: mono),
          if (footer.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(footer, textAlign: TextAlign.center, style: mono),
          ],
        ],
      ),
    );
  }

  /// The editable controls: header/footer text, the "what prints" toggles, and
  /// the paper/divider choices, as a list rather than a built widget so [build]
  /// can either lay them out alone (narrow) or beside [_previewPanel] (wide)
  /// without duplicating the widget tree or nesting a second scrollable inside
  /// a fixed-height region, which is what made controls tap-unreachable on a
  /// short window.
  List<Widget> _controlItems(BuildContext context) => [
          TextField(
            key: const Key('receipt-header'),
            controller: _header,
            decoration: InputDecoration(
              labelText: tr(context, 'Header line'),
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('receipt-footer'),
            controller: _footer,
            minLines: 2,
            maxLines: 5,
            decoration: InputDecoration(
              labelText: tr(context, 'Footer'),
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          _sectionHeader(tr(context, 'What prints')),
          SwitchListTile(
            key: const Key('t-tax'),
            title: Text(tr(context, 'Show tax id')),
            value: _showTax,
            onChanged: (v) => setState(() => _showTax = v),
          ),
          SwitchListTile(
            key: const Key('t-cashier'),
            title: Text(tr(context, 'Show cashier')),
            value: _showCashier,
            onChanged: (v) => setState(() => _showCashier = v),
          ),
          SwitchListTile(
            key: const Key('t-ordertype'),
            title: Text(tr(context, 'Show order type & table')),
            value: _showOrderType,
            onChanged: (v) => setState(() => _showOrderType = v),
          ),
          SwitchListTile(
            key: const Key('t-datetime'),
            title: Text(tr(context, 'Show date & time')),
            subtitle: Text(tr(context, 'Time of sale, near the top')),
            value: _showDateTime,
            onChanged: (v) => setState(() => _showDateTime = v),
          ),
          SwitchListTile(
            key: const Key('t-number'),
            title: Text(tr(context, 'Show order number')),
            subtitle: Text(tr(context, 'The order reference, e.g. #A1B2C3')),
            value: _showNumber,
            onChanged: (v) => setState(() => _showNumber = v),
          ),
          SwitchListTile(
            key: const Key('t-table'),
            title: Text(tr(context, 'Show table & guests')),
            subtitle: Text(tr(context, 'Dine-in orders only')),
            value: _showTable,
            onChanged: (v) => setState(() => _showTable = v),
          ),
          SwitchListTile(
            key: const Key('t-payment'),
            title: Text(tr(context, 'Show payment method')),
            subtitle: Text(tr(context, 'One line per tender')),
            value: _showPayment,
            onChanged: (v) => setState(() => _showPayment = v),
          ),
          SwitchListTile(
            key: const Key('t-itemprice'),
            title: Text(tr(context, 'Show item price')),
            subtitle: Text(tr(context, 'Off leaves names and quantities only')),
            value: _showItemPrice,
            onChanged: (v) => setState(() => _showItemPrice = v),
          ),
          ..._logoItems(context),
          const SizedBox(height: 12),
          _sectionHeader(tr(context, 'Paper & dividers')),
          Row(children: [
            Text(tr(context, 'Paper width'), style: const TextStyle(fontWeight: FontWeight.w600)),
            const Spacer(),
            SegmentedButton<int>(
              segments: [
                ButtonSegment(value: 42, label: Text('80 mm', key: const Key('t-papersize-80'))),
                ButtonSegment(value: 32, label: Text('58 mm', key: const Key('t-papersize-58'))),
              ],
              selected: {_columns},
              onSelectionChanged: (s) => setState(() => _columns = s.first),
            ),
          ]),
          const SizedBox(height: 12),
          Row(children: [
            Text(tr(context, 'Text size'), style: const TextStyle(fontWeight: FontWeight.w600)),
            const Spacer(),
            SegmentedButton<String>(
              segments: [
                ButtonSegment(
                    value: 'normal',
                    label: Text(tr(context, 'Normal'), key: const Key('t-font-normal'))),
                ButtonSegment(
                    value: 'tall',
                    label: Text(tr(context, 'Tall'), key: const Key('t-font-tall'))),
                ButtonSegment(
                    value: 'large',
                    label: Text(tr(context, 'Large'), key: const Key('t-font-large'))),
              ],
              selected: {_fontProfile},
              onSelectionChanged: (s) => setState(() => _fontProfile = s.first),
            ),
          ]),
          if (_fontProfile == 'large')
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                tr(context,
                    'Bigger text prints fewer characters on a line, so the layout follows the choice.'),
                key: const Key('font-large-note'),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          const SizedBox(height: 12),
          Row(children: [
            Text(tr(context, 'Divider style'), style: const TextStyle(fontWeight: FontWeight.w600)),
            const Spacer(),
            SegmentedButton<String>(
              segments: [
                ButtonSegment(value: 'line', label: Text('-----', key: const Key('t-divider-line'))),
                ButtonSegment(value: 'equals', label: Text('=====', key: const Key('t-divider-equals'))),
                ButtonSegment(value: 'dots', label: Text('.....', key: const Key('t-divider-dots'))),
                ButtonSegment(value: 'stars', label: Text('*****', key: const Key('t-divider-stars'))),
              ],
              selected: {_dividerStyle},
              onSelectionChanged: (s) => setState(() => _dividerStyle = s.first),
            ),
          ]),
        ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(tr(context, 'Receipt designer'))),
      body: Column(children: [
        Expanded(
          // A two-column layout on a wide screen puts the preview beside the
          // controls that drive it, so a manager sees the effect while still
          // flipping toggles rather than switching between two screens; a
          // narrow (phone-width) screen has no room for that, so it stacks.
          child: LayoutBuilder(builder: (context, constraints) {
            // High enough that a phone or a tablet in portrait always stacks;
            // only a genuinely wide (desktop-class) window has room for the
            // controls list and the preview side by side without either one
            // getting squeezed too narrow for its own rows to lay out.
            final wide = constraints.maxWidth >= 1100;
            final items = _controlItems(context);
            if (wide) {
              return Row(children: [
                Expanded(
                  flex: 3,
                  child: ListView(padding: const EdgeInsets.all(16), children: items),
                ),
                const VerticalDivider(width: 1),
                Expanded(
                  flex: 2,
                  child: SingleChildScrollView(
                    key: const Key('receipt-preview-scroll'),
                    padding: const EdgeInsets.all(16),
                    child: Center(child: _previewPanel(context)),
                  ),
                ),
              ]);
            }
            // Narrow: one scrollable column, controls first and the preview
            // appended after — the same single ListView shape this screen has
            // always used, just with more to scroll to, rather than a second
            // scrollable squeezed into a fixed-height half of the screen.
            return ListView(
              padding: const EdgeInsets.all(16),
              children: [
                ...items,
                const SizedBox(height: 20),
                _sectionHeader(tr(context, 'Preview')),
                Center(
                  child: KeyedSubtree(
                    key: const Key('receipt-preview-scroll'),
                    child: _previewPanel(context),
                  ),
                ),
              ],
            );
          }),
        ),
        // Save sits outside the scrolling list so it stays reachable however many
        // options the list grows to.
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            FilledButton(
              key: const Key('save-receipt'),
              onPressed: _save,
              child: Text(tr(context, 'Save')),
            ),
            if (widget.onTestPrint != null) ...[
              const SizedBox(height: 8),
              OutlinedButton.icon(
                key: const Key('test-print'),
                icon: const Icon(Icons.print),
                // Save first so the printed sample reflects the current settings.
                onPressed: () async {
                  _save();
                  await widget.onTestPrint!();
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text(tr(context, 'Test receipt sent to printer'))));
                  }
                },
                label: Text(tr(context, 'Print test receipt')),
              ),
            ],
          ]),
        ),
      ]),
    );
  }
}
