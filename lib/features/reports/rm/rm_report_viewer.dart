import 'package:flutter/material.dart';

import '../../../core/export/data_export.dart';
import '../../../core/i18n/l10n.dart';
import 'rm_layout.dart';
import 'rm_pdf.dart';

/// A laid-out report on screen the way the back office shows one: the page in
/// the middle, its thumbnails down the side, and a bar to zoom, turn the pages,
/// save and close.
class RmReportViewer extends StatefulWidget {
  const RmReportViewer({
    super.key,
    required this.title,
    required this.document,
    this.export,
  });

  final String title;
  final RmDocument document;

  /// What stands where the PDF button would: a report with a workbook and a CSV
  /// of its own puts its download menu here.
  final Widget? export;

  @override
  State<RmReportViewer> createState() => _RmReportViewerState();
}

class _RmReportViewerState extends State<RmReportViewer> {
  static const _face = Color(0xFFF0F0F0);
  static const _edge = Color(0xFFA0A0A0);
  static const _blue = Color(0xFF0078D7);
  static const _text = TextStyle(fontSize: 13, color: Colors.black, height: 1.2);

  int _page = 0;

  /// Fit the page to the width of the screen, or show it at its own size.
  bool _fit = true;

  RmDocument get _doc => widget.document;

  void _go(int page) =>
      setState(() => _page = page.clamp(0, _doc.pages - 1).toInt());

  Future<void> _save() async {
    final messenger = ScaffoldMessenger.of(context);
    final saved = tr(context, 'Saved to');
    final failed = tr(context, 'Could not save file');
    final stem = widget.title
        .toLowerCase()
        .replaceAll(RegExp('[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    try {
      final path = await writeBytesExport(
        exportFileName('report-${stem.isEmpty ? 'layout' : stem}',
            DateTime.now(), 'pdf'),
        await buildRmPdf(_doc),
      );
      messenger.showSnackBar(SnackBar(content: Text('$saved: $path')));
    } catch (_) {
      messenger.showSnackBar(SnackBar(content: Text(failed)));
    }
  }

  Widget _button(Key key, VoidCallback? onTap,
          {String? label, IconData? icon, Color? iconColor, double? width}) =>
      Padding(
        padding: const EdgeInsets.only(right: 4),
        child: Material(
          color: const Color(0xFFE1E1E1),
          shape: Border.all(color: const Color(0xFFADADAD)),
          child: InkWell(
            key: key,
            onTap: onTap,
            child: Container(
              width: width,
              height: 44,
              alignment: Alignment.center,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                if (icon != null)
                  Icon(icon,
                      size: 18,
                      color: onTap == null
                          ? Colors.black26
                          : (iconColor ?? Colors.black87)),
                if (icon != null && label != null) const SizedBox(width: 6),
                if (label != null)
                  Flexible(
                    child: Text(label,
                        style: _text,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis),
                  ),
              ]),
            ),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    const red = Color(0xFFC00000);
    final unwired = _doc.items.any((i) => i.placeholder);
    final wide = MediaQuery.sizeOf(context).width >= 1100;
    return Scaffold(
      backgroundColor: _face,
      body: SafeArea(
        // The same way round as the screen it opens from, whatever the language.
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: Column(children: [
            Container(
              color: Colors.white,
              padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
              child: Row(children: [
                const Icon(Icons.description_outlined, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(widget.title,
                      style: _text,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                ),
                InkWell(
                  key: const Key('rm-close-x'),
                  onTap: () => Navigator.pop(context),
                  child: const Padding(
                    padding: EdgeInsets.all(6),
                    child: Icon(Icons.close, size: 18),
                  ),
                ),
              ]),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 6, 4, 6),
              child: Row(children: [
                _button(
                  const Key('rm-zoom'),
                  () => setState(() => _fit = !_fit),
                  label: _fit
                      ? tr(context, 'Zoom: Fit report to screen width')
                      : tr(context, 'Zoom: 100%'),
                  // A narrow window gives the room to the page arrows.
                  width: wide ? 250 : 130,
                ),
                Expanded(
                  child: Row(children: [
                    for (final (key, icon, to) in [
                      ('rm-first', Icons.first_page, 0),
                      ('rm-prev', Icons.chevron_left, _page - 1),
                      ('rm-next', Icons.chevron_right, _page + 1),
                      ('rm-last', Icons.last_page, _doc.pages - 1),
                    ])
                      Expanded(
                        child: _button(
                          Key(key),
                          to == _page || to < 0 || to >= _doc.pages
                              ? null
                              : () => _go(to),
                          icon: icon,
                          iconColor: red,
                        ),
                      ),
                  ]),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  child: Text(
                      '${_page + 1}  ${tr(context, 'of')}  ${_doc.pages}',
                      key: const Key('rm-page-count'),
                      style: _text),
                ),
                if (widget.export case final export?)
                  Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: Material(
                      color: const Color(0xFFE1E1E1),
                      shape: Border.all(color: const Color(0xFFADADAD)),
                      child: SizedBox(height: 44, width: 52, child: export),
                    ),
                  )
                else
                  _button(const Key('rm-save'), _save,
                      label: tr(context, 'PDF'), icon: Icons.save),
                _button(const Key('rm-close'), () => Navigator.pop(context),
                    label: wide ? tr(context, 'Close') : null,
                    icon: Icons.door_back_door_outlined),
              ]),
            ),
            if (unwired)
              Container(
                key: const Key('rm-unwired'),
                width: double.infinity,
                color: const Color(0xFFFFF4CE),
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                child: Text(
                  tr(context,
                      'Layout only: the fields shown in grey are not connected to your data yet.'),
                  style: _text,
                ),
              ),
            Expanded(
              child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                SizedBox(width: 170, child: _thumbnails(context)),
                Expanded(child: _pageArea()),
              ]),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _thumbnails(BuildContext context) => Container(
        margin: const EdgeInsets.fromLTRB(8, 0, 4, 8),
        decoration:
            BoxDecoration(color: _face, border: Border.all(color: _edge)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(
            padding: const EdgeInsets.all(6),
            child: Text(tr(context, 'Thumbnails'), style: _text),
          ),
          Expanded(
            child: ListView(children: [
              for (var p = 0; p < _doc.pages; p++)
                InkWell(
                  key: Key('rm-thumb-$p'),
                  onTap: () => _go(p),
                  child: Container(
                    color: p == _page ? _blue : null,
                    padding: const EdgeInsets.all(8),
                    child: RmPageView(
                        document: _doc, page: p, width: 140, greeked: true),
                  ),
                ),
            ]),
          ),
        ]),
      );

  Widget _pageArea() => LayoutBuilder(
        builder: (context, box) {
          final width = _fit
              ? (box.maxWidth - 40).clamp(200.0, 1400.0).toDouble()
              : _doc.pageWidth * 1.4;
          return Container(
            margin: const EdgeInsets.fromLTRB(4, 0, 8, 8),
            color: const Color(0xFFE6E6E6),
            child: SingleChildScrollView(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: RmPageView(
                    key: const Key('rm-page'),
                    document: _doc,
                    page: _page,
                    width: width,
                  ),
                ),
              ),
            ),
          );
        },
      );
}

/// One page of a laid-out report, drawn [width] wide.
class RmPageView extends StatelessWidget {
  const RmPageView({
    super.key,
    required this.document,
    required this.page,
    required this.width,
    this.greeked = false,
  });

  final RmDocument document;
  final int page;
  final double width;

  /// Draw each piece of text as a grey bar its size: what a page looks like
  /// from across the room, which is all a thumbnail has to show.
  final bool greeked;

  @override
  Widget build(BuildContext context) {
    final height = width * document.pageHeight / document.pageWidth;
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: Colors.black, width: 1.5),
      ),
      child: FittedBox(
        fit: BoxFit.fill,
        child: SizedBox(
          width: document.pageWidth,
          height: document.pageHeight,
          child: Stack(children: [
            for (final item in document.on(page)) _placed(item),
          ]),
        ),
      ),
    );
  }

  Widget _placed(RmPlaced item) {
    final c = item.cell;
    if (c.kind == RmKind.rule) {
      return Positioned(
        left: item.x,
        top: item.y + 6,
        child: Container(width: item.width, height: 0.8, color: Colors.black),
      );
    }
    if (greeked) {
      final length = (item.text.length * c.fontSize * 0.5)
          .clamp(0.0, item.width)
          .toDouble();
      return Positioned(
        left: switch (c.justify) {
          1 => item.x + (item.width - length) / 2,
          2 => item.x + item.width - length,
          _ => item.x,
        },
        top: item.y + c.fontSize * 0.3,
        child: Container(
            width: length,
            height: c.fontSize * 0.55,
            color: const Color(0xFF8A8A8A)),
      );
    }
    return Positioned(
      left: item.x,
      top: item.y,
      width: item.width,
      child: Text(
        item.text,
        maxLines: 1,
        softWrap: false,
        overflow: TextOverflow.visible,
        textAlign: switch (c.justify) {
          1 => TextAlign.center,
          2 => TextAlign.right,
          _ => TextAlign.left,
        },
        style: TextStyle(
          fontFamily: 'Arial',
          fontSize: c.fontSize,
          height: 1.15,
          fontWeight: c.bold ? FontWeight.bold : FontWeight.normal,
          fontStyle: c.italic ? FontStyle.italic : FontStyle.normal,
          decoration:
              c.underline ? TextDecoration.underline : TextDecoration.none,
          color: item.placeholder ? const Color(0xFF9A9A9A) : Colors.black,
        ),
      ),
    );
  }
}
