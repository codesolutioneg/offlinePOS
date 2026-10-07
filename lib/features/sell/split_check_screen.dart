import 'package:flutter/material.dart';

import '../../core/i18n/l10n.dart';
import '../../domain/order.dart';

/// One slice of a bill line on one check: the whole line, some of its units, or a
/// share of a single item split between guests.
typedef SplitShare = ({String line, double quantity});

class _Piece {
  _Piece(this.id, this.line, this.quantity, [List<String>? absorbed])
      : absorbed = absorbed ?? [];
  final int id;
  final String line;
  double quantity;

  /// Other bill lines folded into this row (the quarters of a burger that were
  /// separate lines once the split was applied). They are handed back with no
  /// quantity so the host takes them off their checks instead of leaving them.
  final List<String> absorbed;
}

/// What a guest's column asks the host to do with that guest's check.
enum SplitAction { print, pay }

/// Split Check the Dinerware way: a column per guest. Tap items to select them,
/// then tap another guest to move them there.
///
/// Opens on the table's open [checks], one column each; a table not split yet
/// opens with every item on the first guest and a column per cover. [onAction]
/// lays the table out as the columns stand, prints or takes payment for one
/// guest's check, and hands back the table's checks as they are afterwards (empty
/// once the table is settled, which closes the screen). [Navigator.pop] returns
/// the non-empty columns in order, or null when cancelled.
class SplitCheckScreen extends StatefulWidget {
  const SplitCheckScreen({
    super.key,
    required this.checks,
    required this.formatAmount,
    this.guests,
    this.onAction,
  });

  final List<Order> checks;
  final String Function(double) formatAmount;

  /// How many guest columns to open with (the table's cover count).
  final int? guests;

  final Future<List<Order>> Function(
          List<List<SplitShare>> layout, int check, SplitAction action)?
      onAction;

  @override
  State<SplitCheckScreen> createState() => _SplitCheckScreenState();
}

class _SplitCheckScreenState extends State<SplitCheckScreen> {
  final List<List<_Piece>> _cols = [];
  final List<ScrollController> _scrolls = [];
  final List<Order?> _orders = [];
  final Set<int> _selected = {};
  final ScrollController _across = ScrollController();
  final Map<String, OrderLine> _lines = {};
  int _active = 0;
  int _nextId = 0;
  int _openChecks = 1;
  bool _busy = false;
  late final bool _startedWhole;

  @override
  void initState() {
    super.initState();
    _load(widget.checks, guests: widget.guests);
    _startedWhole = _openChecks < 2;
  }

  void _load(List<Order> checks, {int? guests}) {
    for (final c in _scrolls) {
      c.dispose();
    }
    _cols.clear();
    _scrolls.clear();
    _orders.clear();
    _lines.clear();
    _selected.clear();
    _active = 0;
    final open = [
      for (final o in checks)
        if (o.lines.isNotEmpty) o,
    ];
    _openChecks = open.length;
    for (final o in open) {
      for (final l in o.lines) {
        _lines[l.uuid] = l;
      }
    }
    if (open.length > 1) {
      for (final o in open) {
        _addColumn(o);
        _cols.last.addAll(
            [for (final l in o.lines) _Piece(_nextId++, l.uuid, l.quantity)]);
        _tidy(_cols.length - 1);
      }
      return;
    }
    final lines = open.isEmpty ? const <OrderLine>[] : open.first.lines;
    var start = (guests ?? 1).clamp(1, 12);
    for (final l in lines) {
      if (l.seat != null && l.seat! > start) start = l.seat!.clamp(1, 12);
    }
    for (var i = 0; i < start; i++) {
      _addColumn(i == 0 && open.isNotEmpty ? open.first : null);
    }
    for (final l in lines) {
      final at = ((l.seat ?? 1) - 1).clamp(0, _cols.length - 1);
      _cols[at].add(_Piece(_nextId++, l.uuid, l.quantity));
    }
    for (var i = 0; i < _cols.length; i++) {
      _tidy(i);
    }
  }

  @override
  void dispose() {
    for (final c in _scrolls) {
      c.dispose();
    }
    _across.dispose();
    super.dispose();
  }

  void _addColumn([Order? check]) {
    _cols.add([]);
    _scrolls.add(ScrollController());
    _orders.add(check);
  }

  void _removeColumn(int i) {
    _cols.removeAt(i);
    _scrolls.removeAt(i).dispose();
    _orders.removeAt(i);
  }

  /// Take a guest off: their items go back to the first guest (or the second, when
  /// it is the first guest being taken off).
  void _removeGuest(int i) {
    if (_cols.length < 2) return;
    setState(() {
      final into = i == 0 ? 1 : 0;
      _cols[into].addAll(_cols[i]);
      _tidy(into);
      _selected.clear();
      _removeColumn(i);
      _active = (into > i ? into - 1 : into).clamp(0, _cols.length - 1);
    });
  }

  List<List<SplitShare>> _layout() => [
        for (final c in _cols)
          if (c.isNotEmpty) _shares(c),
      ];

  static List<SplitShare> _shares(List<_Piece> col) => [
        for (final p in col) ...[
          (line: p.line, quantity: p.quantity),
          for (final a in p.absorbed) (line: a, quantity: 0.0),
        ],
      ];

  Future<void> _act(int i, SplitAction action) async {
    final host = widget.onAction;
    if (host == null || _busy) return;
    if (_cols[i].isEmpty) {
      _toast('This guest has no items.');
      return;
    }
    final check = _cols.take(i).where((c) => c.isNotEmpty).length;
    setState(() => _busy = true);
    final fresh = await host(_layout(), check, action);
    if (!mounted) return;
    if (fresh.every((o) => o.lines.isEmpty)) {
      Navigator.pop(context);
      return;
    }
    setState(() {
      _busy = false;
      _load(fresh);
    });
    if (action == SplitAction.print) _toast('Bill sent to the printer');
  }

  int? _columnOf(int pieceId) {
    for (var i = 0; i < _cols.length; i++) {
      if (_cols[i].any((p) => p.id == pieceId)) return i;
    }
    return null;
  }

  double _amountOf(_Piece p) {
    final l = _lines[p.line]!;
    if (l.quantity == 0) return 0;
    return l.total * p.quantity / l.quantity;
  }

  double _columnTotal(int i) => _cols[i].fold(0.0, (s, p) => s + _amountOf(p));

  void _moveSelectedTo(int target) {
    final moving = <_Piece>[];
    for (final c in _cols) {
      moving.addAll(c.where((p) => _selected.contains(p.id)));
      c.removeWhere((p) => _selected.contains(p.id));
    }
    _cols[target].addAll(moving);
    _tidy(target);
    _selected.clear();
    _active = target;
  }

  /// Slices of the same item on one guest read as one row ("3× Burger"): the
  /// same bill line, or shares of one item that became separate lines when the
  /// split was applied (four quarters make the burger again).
  void _tidy(int col) => _tidyPieces(_cols[col]);

  void _tidyPieces(List<_Piece> c) {
    for (var i = 0; i < c.length; i++) {
      for (var j = c.length - 1; j > i; j--) {
        if (!_joinable(c[i], c[j])) continue;
        _fold(c[i], c[j]);
        c.removeAt(j);
      }
    }
  }

  void _fold(_Piece into, _Piece other) {
    into.quantity += other.quantity;
    if ((into.quantity - into.quantity.roundToDouble()).abs() < 1e-9) {
      into.quantity = into.quantity.roundToDouble();
    }
    if (other.line != into.line && !into.absorbed.contains(other.line)) {
      into.absorbed.add(other.line);
    }
    for (final a in other.absorbed) {
      if (a != into.line && !into.absorbed.contains(a)) into.absorbed.add(a);
    }
  }

  /// Whole lines of the same dish keep their own rows, as on the bill; only a
  /// share (a fractional quantity) joins another line of the same item.
  bool _joinable(_Piece a, _Piece b) {
    if (a.line == b.line) return true;
    if (_whole(a.quantity) && _whole(b.quantity)) return false;
    final x = _lines[a.line];
    final y = _lines[b.line];
    if (x == null || y == null) return false;
    return x.productId == y.productId &&
        x.name == y.name &&
        x.unitPrice == y.unitPrice &&
        x.taxRate == y.taxRate &&
        x.note == y.note &&
        x.discountPercent == y.discountPercent &&
        x.printedToKitchen == y.printedToKitchen &&
        _sameModifiers(x.modifiers, y.modifiers);
  }

  static bool _sameModifiers(List<OrderModifier> a, List<OrderModifier> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].productId != b[i].productId ||
          a[i].name != b[i].name ||
          a[i].quantity != b[i].quantity ||
          a[i].unitPrice != b[i].unitPrice) {
        return false;
      }
    }
    return true;
  }

  /// Move what is selected onto [target]. One item of several units asks how
  /// many of them go; the rest stay where they were.
  Future<void> _moveTo(int target) async {
    final picked = [
      for (final c in _cols) ...c.where((p) => _selected.contains(p.id)),
    ];
    if (picked.length == 1 &&
        _whole(picked.first.quantity) &&
        picked.first.quantity > 1) {
      final p = picked.first;
      final n = await _askCount(p.quantity.toInt(), target);
      if (n == null || !mounted) return;
      if (n < p.quantity) {
        setState(() {
          p.quantity -= n;
          _cols[target].add(_Piece(_nextId++, p.line, n.toDouble()));
          _tidy(target);
          _selected.clear();
          _active = target;
        });
        return;
      }
    }
    setState(() => _moveSelectedTo(target));
  }

  Future<int?> _askCount(int max, int target) => showDialog<int>(
        context: context,
        builder: (ctx) => AlertDialog(
          key: const Key('split-count'),
          title: Text(
              '${tr(ctx, 'How many to move to')} ${tr(ctx, 'Guest')} ${target + 1}?'),
          content: SizedBox(
            width: 420,
            child: SingleChildScrollView(
              child: Wrap(
                spacing: 10,
                runSpacing: 10,
                alignment: WrapAlignment.center,
                children: [
                  for (var n = 1; n <= max; n++)
                    SizedBox(
                      width: 72,
                      height: 64,
                      child: FilledButton(
                        key: Key('split-count-$n'),
                        style: n == max
                            ? FilledButton.styleFrom(
                                backgroundColor: const Color(0xFF3E9B4F))
                            : null,
                        onPressed: () => Navigator.pop(ctx, n),
                        child: Text('$n',
                            style: const TextStyle(
                                fontSize: 22, fontWeight: FontWeight.bold)),
                      ),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text(tr(ctx, 'Cancel'))),
          ],
        ),
      );

  void _tapPiece(int col, _Piece p) {
    final from = _selected.isEmpty ? null : _columnOf(_selected.first);
    if (from != null && from != col) {
      _moveTo(col);
      return;
    }
    setState(() {
      _active = col;
      if (!_selected.remove(p.id)) _selected.add(p.id);
    });
  }

  void _tapColumn(int col) {
    if (_selected.isNotEmpty && _columnOf(_selected.first) != col) {
      _moveTo(col);
    } else {
      setState(() => _active = col);
    }
  }

  void _add() {
    setState(_addColumn);
    final col = _cols.length - 1;
    if (_selected.isNotEmpty) {
      _moveTo(col);
    } else {
      setState(() => _active = col);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_across.hasClients) {
        _across.animateTo(_across.position.maxScrollExtent,
            duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
      }
    });
  }

  void _selectAll() {
    setState(() {
      final ids = _cols[_active].map((p) => p.id).toSet();
      if (ids.isNotEmpty && _selected.containsAll(ids)) {
        _selected.clear();
      } else {
        _selected
          ..clear()
          ..addAll(ids);
      }
    });
  }

  bool _whole(double q) => q == q.roundToDouble();

  Future<void> _splitItem() async {
    if (_selected.isEmpty) {
      _toast('Select an item first.');
      return;
    }
    final picked = [
      for (final c in _cols) ...c.where((p) => _selected.contains(p.id)),
    ];
    final from = _columnOf(picked.first.id)!;
    final guests = await _askGuests(from);
    if (guests == null || !mounted) return;
    setState(() {
      while (_cols.length <= guests.reduce((a, b) => a > b ? a : b)) {
        _addColumn();
      }
      for (final p in picked) {
        final col = _columnOf(p.id);
        if (col == null) continue;
        _cols[col].remove(p);
        final share = p.quantity / guests.length;
        var given = 0.0;
        for (var k = 0; k < guests.length; k++) {
          final q = k == guests.length - 1 ? p.quantity - given : share;
          given += q;
          _cols[guests[k]].add(
              _Piece(_nextId++, p.line, q, k == 0 ? p.absorbed : null));
        }
      }
      for (final g in guests) {
        _tidy(g);
      }
      _selected.clear();
      _active = from;
    });
  }

  /// Which guests share the selected item: every guest starts ticked, and more
  /// can be added right here. Returns the column indexes, at least two.
  Future<List<int>?> _askGuests(int from) {
    final ticked = <int>{for (var i = 0; i < _cols.length; i++) i};
    var count = _cols.length;
    if (count < 2) {
      count = 2;
      ticked.add(1);
    }
    return showDialog<List<int>>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          key: const Key('split-guests'),
          title: Text(tr(ctx, 'Split this item between')),
          content: SizedBox(
            width: 440,
            child: Wrap(
              spacing: 10,
              runSpacing: 10,
              alignment: WrapAlignment.center,
              children: [
                for (var i = 0; i < count; i++)
                  SizedBox(
                    width: 130,
                    height: 60,
                    child: FilledButton(
                      key: Key('split-guest-$i'),
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        backgroundColor: ticked.contains(i)
                            ? const Color(0xFF3E9B4F)
                            : const Color(0xFFBDBDBD),
                      ),
                      onPressed: () => setLocal(() {
                        if (!ticked.remove(i)) ticked.add(i);
                      }),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                              ticked.contains(i)
                                  ? Icons.check_box
                                  : Icons.check_box_outline_blank,
                              size: 20),
                          const SizedBox(width: 6),
                          Flexible(
                            child: Text('${tr(ctx, 'Guest')} ${i + 1}',
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    fontWeight: FontWeight.bold)),
                          ),
                        ],
                      ),
                    ),
                  ),
                SizedBox(
                  width: 120,
                  height: 60,
                  child: OutlinedButton.icon(
                    key: const Key('split-guest-add'),
                    onPressed: () => setLocal(() {
                      ticked.add(count);
                      count++;
                    }),
                    icon: const Icon(Icons.person_add_alt_1),
                    label: Text(tr(ctx, 'Add')),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text(tr(ctx, 'Cancel'))),
            FilledButton(
              key: const Key('split-guests-ok'),
              onPressed: ticked.length < 2
                  ? null
                  : () => Navigator.pop(ctx, ticked.toList()..sort()),
              child: Text(
                  '${tr(ctx, 'Split Item')} (${ticked.length})'),
            ),
          ],
        ),
      ),
    );
  }

  /// Put every guest back on one check and leave: the table goes back to a single
  /// bill with nothing selected needed.
  void _unsplitAll() {
    if (_openChecks < 2) {
      Navigator.pop(context);
      return;
    }
    // Gathered on copies: the columns are still drawn while the screen closes,
    // and must stay in step with their checks until it has.
    final all = [
      for (final c in _cols)
        for (final p in c) _Piece(p.id, p.line, p.quantity, [...p.absorbed]),
    ];
    _tidyPieces(all);
    Navigator.pop<List<List<SplitShare>>>(context, [_shares(all)]);
  }

  /// Leave without splitting. Printing or paying a guest lays the table out as
  /// checks on the spot, so a table that was one bill when the screen opened is
  /// put back to one bill with whatever is still unpaid.
  void _cancel() {
    if (_startedWhole && _openChecks > 1) {
      _unsplitAll();
    } else {
      Navigator.pop(context);
    }
  }

  /// Gather every share of the selected item back onto the guest it was
  /// picked on, whole again.
  void _unsplitItem() {
    if (_selected.isEmpty) {
      _unsplitAll();
      return;
    }
    setState(() {
      for (final id in _selected.toList()) {
        final col = _columnOf(id);
        if (col == null) continue;
        final keep = _cols[col].firstWhere((p) => p.id == id);
        for (final c in _cols) {
          final same = c.where((p) => p != keep && _joinable(keep, p)).toList();
          for (final p in same) {
            _fold(keep, p);
            c.remove(p);
          }
        }
      }
      _selected.clear();
    });
  }

  Future<void> _combine() async {
    if (_cols.length < 2) return;
    final from = _active;
    final into = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
            '${tr(ctx, 'Combine')} ${tr(ctx, 'Guest')} ${from + 1} ${tr(ctx, 'into')} …'),
        content: SizedBox(
          width: 360,
          child: Wrap(
            spacing: 10,
            runSpacing: 10,
            alignment: WrapAlignment.center,
            children: [
              for (var i = 0; i < _cols.length; i++)
                if (i != from)
                  SizedBox(
                    width: 150,
                    height: 72,
                    child: FilledButton(
                      key: Key('combine-into-$i'),
                      style: FilledButton.styleFrom(
                          backgroundColor: const Color(0xFF3E9B4F)),
                      onPressed: () => Navigator.pop(ctx, i),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text('${tr(ctx, 'Guest')} ${i + 1}',
                              style:
                                  const TextStyle(fontWeight: FontWeight.bold)),
                          Text(widget.formatAmount(_columnTotal(i))),
                        ],
                      ),
                    ),
                  ),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(tr(ctx, 'Cancel'))),
        ],
      ),
    );
    if (into == null || !mounted) return;
    setState(() {
      _cols[into].addAll(_cols[from]);
      _cols[from].clear();
      _tidy(into);
      _selected.clear();
      _active = into;
      _reassign();
    });
  }

  /// Drop the empty guests and number the rest from 1 again.
  void _reassign() {
    final activePieces = _cols[_active].map((p) => p.id).toSet();
    for (var i = _cols.length - 1; i >= 0 && _cols.length > 1; i--) {
      if (_cols[i].isEmpty) _removeColumn(i);
    }
    _active = 0;
    for (var i = 0; i < _cols.length; i++) {
      if (_cols[i].any((p) => activePieces.contains(p.id))) _active = i;
    }
  }

  void _done() {
    final checks = _layout();
    if (checks.length < 2 && _openChecks < 2) {
      _toast('Move items to at least one other guest first.');
      return;
    }
    Navigator.pop<List<List<SplitShare>>>(context, checks);
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(tr(context, msg))));
  }

  String _qty(double q) {
    if (_whole(q)) return q == 1 ? '' : '${q.toInt()}× ';
    final whole = q.floor();
    final part = q - whole;
    for (var d = 2; d <= 12; d++) {
      final n = part * d;
      if ((n - n.roundToDouble()).abs() < 1e-6) {
        return whole > 0 ? '$whole ${n.round()}/$d× ' : '${n.round()}/$d ';
      }
    }
    return '${q.toStringAsFixed(2)}× ';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: const Key('split-check-screen'),
      backgroundColor: const Color(0xFFE3E3E3),
      body: SafeArea(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: LayoutBuilder(builder: (context, box) {
                final width = _cols.length <= 4
                    ? box.maxWidth / _cols.length
                    : (box.maxWidth / 4).clamp(200.0, 320.0);
                return ListView.builder(
                  controller: _across,
                  scrollDirection: Axis.horizontal,
                  itemCount: _cols.length,
                  itemBuilder: (context, i) =>
                      SizedBox(width: width, child: _column(i)),
                );
              }),
            ),
            SizedBox(width: 130, child: _sideBar()),
          ],
        ),
      ),
    );
  }

  Widget _column(int i) {
    final active = i == _active;
    return Container(
      key: Key('split-col-$i'),
      margin: const EdgeInsets.all(1),
      decoration: BoxDecoration(
        border: Border.all(color: const Color(0xFF555555)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Material(
            color: const Color(0xFF3E9B4F),
            child: InkWell(
              key: Key('split-head-$i'),
              onTap: () => _tapColumn(i),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
                child: Row(children: [
                  if (_orders[i]?.billPrintedAt != null)
                    Tooltip(
                      message: tr(context, 'Bill printed'),
                      child: const Icon(Icons.print,
                          key: Key('split-printed'),
                          color: Colors.white,
                          size: 18),
                    )
                  else
                    const SizedBox(width: 18),
                  Expanded(
                    child: Text('${tr(context, 'Guest')} ${i + 1}',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.bold)),
                  ),
                  if (_cols.length > 1)
                    InkWell(
                      key: Key('split-remove-$i'),
                      onTap: () => _removeGuest(i),
                      child: const Icon(Icons.close,
                          color: Colors.white, size: 20),
                    )
                  else
                    const SizedBox(width: 20),
                ]),
              ),
            ),
          ),
          Expanded(
            child: Material(
              color: active ? const Color(0xFFC8C8C8) : const Color(0xFFFFFAF0),
              child: InkWell(
                key: Key('split-body-$i'),
                onTap: () => _tapColumn(i),
                child: ListView(
                  controller: _scrolls[i],
                  children: [
                    for (final p in _cols[i]) _pieceRow(i, p),
                  ],
                ),
              ),
            ),
          ),
          Container(
            color: const Color(0xFF3E9B4F).withValues(alpha: 0.12),
            padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
            child: Row(children: [
              Text(tr(context, 'Total'),
                  style: const TextStyle(fontWeight: FontWeight.w600)),
              const Spacer(),
              Text(widget.formatAmount(_columnTotal(i)),
                  key: Key('split-total-$i'),
                  style: const TextStyle(fontWeight: FontWeight.bold)),
            ]),
          ),
          if (widget.onAction != null)
            SizedBox(
              height: 46,
              child: Row(children: [
                Expanded(
                  child: _columnButton('split-print-$i', Icons.print, 'Print',
                      const Color(0xFF1E6B52), () => _act(i, SplitAction.print)),
                ),
                Expanded(
                  child: _columnButton('split-pay-$i', Icons.payments, 'Pay',
                      const Color(0xFF27AE60), () => _act(i, SplitAction.pay)),
                ),
              ]),
            ),
          SizedBox(
            height: 50,
            child: Row(children: [
              Expanded(child: _scrollButton(i, up: true)),
              Expanded(
                child: Center(
                  child: Text('S:${i + 1}',
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                ),
              ),
              Expanded(child: _scrollButton(i, up: false)),
            ]),
          ),
        ],
      ),
    );
  }

  Widget _columnButton(String key, IconData icon, String label, Color color,
          VoidCallback onTap) =>
      Padding(
        padding: const EdgeInsets.all(2),
        child: Material(
          color: _busy ? color.withValues(alpha: 0.5) : color,
          borderRadius: BorderRadius.circular(4),
          child: InkWell(
            key: Key(key),
            onTap: _busy ? null : onTap,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, color: Colors.white, size: 20),
                const SizedBox(width: 6),
                Text(tr(context, label),
                    style: const TextStyle(
                        color: Colors.white, fontWeight: FontWeight.bold)),
              ],
            ),
          ),
        ),
      );

  Widget _scrollButton(int i, {required bool up}) => Material(
        color: const Color(0xFFBDBDBD),
        child: InkWell(
          onTap: () {
            final c = _scrolls[i];
            if (!c.hasClients) return;
            final to = (c.offset + (up ? -160 : 160))
                .clamp(0.0, c.position.maxScrollExtent);
            c.animateTo(to,
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeOut);
          },
          child: Icon(up ? Icons.arrow_drop_up : Icons.arrow_drop_down,
              color: Colors.white, size: 40),
        ),
      );

  Widget _pieceRow(int col, _Piece p) {
    final l = _lines[p.line]!;
    final sel = _selected.contains(p.id);
    final style = TextStyle(
        fontSize: 15,
        color: sel ? Colors.white : Colors.black87,
        fontWeight: FontWeight.w500);
    final sub = TextStyle(fontSize: 13, color: sel ? Colors.white70 : Colors.black54);
    return Material(
      color: sel ? const Color(0xFF1E6FD9) : Colors.transparent,
      child: InkWell(
        key: Key('split-piece-${p.id}'),
        onTap: () => _tapPiece(col, p),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(children: [
                Expanded(
                  child: Text('${_qty(p.quantity)}${l.name}',
                      style: style, overflow: TextOverflow.ellipsis),
                ),
                Text(widget.formatAmount(_amountOf(p)), style: style),
              ]),
              for (final m in l.modifiers)
                Padding(
                  padding: const EdgeInsetsDirectional.only(start: 10),
                  child: Text(m.name, style: sub),
                ),
              if (l.note != null)
                Padding(
                  padding: const EdgeInsetsDirectional.only(start: 10),
                  child: Text(l.note!,
                      style: sub.copyWith(fontStyle: FontStyle.italic)),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _sideBar() {
    Widget button(String key, String label, VoidCallback onTap,
            {IconData? icon, Color? iconColor}) =>
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(2),
            child: Material(
              color: const Color(0xFFD0D0D0),
              elevation: 1,
              borderRadius: BorderRadius.circular(3),
              child: InkWell(
                key: Key(key),
                onTap: onTap,
                child: Center(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Padding(
                      padding: const EdgeInsets.all(4),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (icon != null)
                            Icon(icon, color: iconColor, size: 36),
                          Text(tr(context, label),
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                  fontSize: 13, fontWeight: FontWeight.w600)),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
    return Column(children: [
      button('split-add', 'Add', _add,
          icon: Icons.person_add_alt_1, iconColor: const Color(0xFF3E9B4F)),
      button('split-select', 'Select', _selectAll,
          icon: Icons.select_all, iconColor: const Color(0xFF1E6FD9)),
      button('split-item', 'Split Item', _splitItem,
          icon: Icons.call_split, iconColor: const Color(0xFF8E44AD)),
      button('split-unsplit', 'Unsplit Item', _unsplitItem,
          icon: Icons.call_merge, iconColor: const Color(0xFF8E44AD)),
      button('split-unsplit-all', 'Unsplit Check', _unsplitAll,
          icon: Icons.undo, iconColor: const Color(0xFFC0392B)),
      button('split-combine', 'Combine', _combine,
          icon: Icons.merge_type, iconColor: const Color(0xFFD35400)),
      button('split-reassign', 'Reassign Seats',
          () => setState(_reassign),
          icon: Icons.format_list_numbered, iconColor: const Color(0xFF5D6D7E)),
      button('split-done', 'Split Check', _done,
          icon: Icons.check, iconColor: const Color(0xFF1E6FD9)),
      button('split-cancel', 'Cancel', _cancel,
          icon: Icons.close, iconColor: const Color(0xFF1E6FD9)),
    ]);
  }
}
