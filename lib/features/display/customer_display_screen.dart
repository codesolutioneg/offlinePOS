import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/i18n/l10n.dart';
import '../../core/lan/lan_cart_board.dart';
import '../../core/theme/app_colors.dart';

/// The screen the customer reads while their shopping is rung up.
///
/// It sells nothing, holds nothing and cannot be typed into: every line on it
/// arrived over the shop LAN from the till at the counter, exactly like a kitchen
/// board's tickets. That is what makes it safe to bolt to a stand facing away from
/// the staff.
class CustomerDisplayScreen extends StatefulWidget {
  const CustomerDisplayScreen({
    super.key,
    required this.board,
    required this.formatAmount,
    this.shopName,
    this.nameFor,
    this.tills = const [],
    this.actions = const [],
    this.refresh = const Duration(seconds: 1),
    this.nowFn = DateTime.now,
  });

  /// Where the carts the fabric delivered are kept.
  final LanCartBoard board;

  final String Function(double) formatAmount;

  /// What to show when nothing is being rung. The shop's own name is friendlier
  /// than a blank screen and tells whoever walks past that the device is alive.
  final String? shopName;

  /// A till's name as the shop calls it, for the picker. Falls back to the id.
  final String Function(String deviceId)? nameFor;

  /// The device ids a display may be pointed at, from the LAN peer list.
  final List<String> tills;

  /// Doors on the top bar, the way the kitchen board carries its own: this device
  /// has no drawer and no sign-in, so there is nowhere else to put them.
  final List<Widget> actions;

  final Duration refresh;
  final DateTime Function() nowFn;

  @override
  State<CustomerDisplayScreen> createState() => _CustomerDisplayScreenState();
}

class _CustomerDisplayScreenState extends State<CustomerDisplayScreen> {
  Timer? _tick;

  /// A cart nobody has touched for this long is the last customer's, so the display
  /// goes back to idle rather than showing their shopping to the next person in the
  /// queue. Longer than any pause between taps, shorter than a queue.
  static const Duration staleAfter = Duration(minutes: 5);

  @override
  void initState() {
    super.initState();
    // The board is written by the fabric's own timer, so the screen reads it on a
    // timer of its own rather than being pushed at. A second is well under what a
    // customer notices and nothing here costs more than a settings read.
    _tick = Timer.periodic(widget.refresh, (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  Future<void> _pickTill() async {
    final chosen = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(tr(ctx, 'Show which till')),
        children: [
          SimpleDialogOption(
            key: const Key('display-till-any'),
            onPressed: () => Navigator.pop(ctx, ''),
            child: Text(tr(ctx, 'Whichever is busiest')),
          ),
          for (final id in widget.tills)
            SimpleDialogOption(
              key: Key('display-till-$id'),
              onPressed: () => Navigator.pop(ctx, id),
              child: Text(widget.nameFor?.call(id) ?? id),
            ),
        ],
      ),
    );
    if (chosen == null) return;
    widget.board.source = chosen.isEmpty ? null : chosen;
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final cart = widget.board.showing();
    final fresh = cart != null &&
        !cart.isEmpty &&
        widget.nowFn().toUtc().difference(cart.at) < staleAfter;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white70,
        toolbarHeight: 40,
        title: Text(widget.shopName ?? '',
            style: const TextStyle(fontSize: 14, color: Colors.white54)),
        actions: [
          IconButton(
            key: const Key('display-pick-till'),
            onPressed: _pickTill,
            icon: const Icon(Icons.point_of_sale, size: 18),
            tooltip: tr(context, 'Show which till'),
          ),
          ...widget.actions,
        ],
      ),
      body: fresh ? _cart(cart) : _idle(),
    );
  }

  Widget _idle() => Center(
        key: const Key('display-idle'),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.storefront, size: 72, color: Colors.white24),
            const SizedBox(height: 16),
            Text(
              widget.shopName ?? tr(context, 'Welcome'),
              style: const TextStyle(
                  fontSize: 34, color: Colors.white70, fontWeight: FontWeight.bold),
            ),
          ],
        ),
      );

  Widget _cart(LanCartSnapshot cart) => Column(
        key: const Key('display-cart'),
        children: [
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              itemCount: cart.lines.length,
              itemBuilder: (context, i) {
                final line = cart.lines[i];
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Row(children: [
                    SizedBox(
                      width: 64,
                      child: Text(_qty(line.quantity),
                          style: const TextStyle(
                              fontSize: 26, color: Colors.white54)),
                    ),
                    Expanded(
                      child: Text(line.name,
                          style: const TextStyle(
                              fontSize: 26, color: Colors.white)),
                    ),
                    Text(widget.formatAmount(line.total),
                        style: const TextStyle(
                            fontSize: 26,
                            color: Colors.white,
                            fontWeight: FontWeight.bold)),
                  ]),
                );
              },
            ),
          ),
          Container(
            width: double.infinity,
            color: AppColors.primary,
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 18),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(tr(context, 'TOTAL'),
                    style: const TextStyle(fontSize: 30, color: Colors.white)),
                Text(
                  widget.formatAmount(cart.total),
                  key: const Key('display-total'),
                  style: const TextStyle(
                      fontSize: 44,
                      color: Colors.white,
                      fontWeight: FontWeight.bold),
                ),
              ],
            ),
          ),
        ],
      );

  /// A whole number reads as a count, a weighed line keeps its decimals.
  static String _qty(double q) =>
      q == q.roundToDouble() ? '${q.toInt()}x' : '${q.toStringAsFixed(3)}x';
}
